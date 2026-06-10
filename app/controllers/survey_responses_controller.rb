# Presents individual survey responses for viewing, printing, or exporting,
# enforcing authorization rules for admins, advisors, and students.
class SurveyResponsesController < ApplicationController
  before_action :set_survey_response
  before_action :authorize_view!, only: %i[show download]
  before_action :authorize_composite!, only: :composite_report
  before_action :authorize_admin!, only: %i[edit update destroy]

  # Shows a survey response within the standard layout.
  #
  # @return [void]
  def show
    @return_to = safe_return_to_param
    load_versions!
    @survey_assignment = SurveyAssignment.find_by(student_id: @survey_response.student_id, survey_id: @survey_response.survey_id)
    @question_responses = preload_question_responses
    load_self_target_summary!
    load_confidential_advisor_note!
  end

  # Admin-only: edit a student's survey answers.
  def edit
    @survey = @survey_response.survey
    @student = @survey_response.student
    @return_to = safe_return_to_param

    flash.now[:notice] ||= "You’re currently editing a student response."

    @existing_answers = {}
    @other_answers = {}

    responses = StudentQuestion
                  .where(student_id: @student.student_id, question_id: @survey.questions.select(:id))
                  .includes(:question)

    responses.each do |response|
      ans = response.answer
      if ans.is_a?(Hash) && response.question&.choice_question?
        @existing_answers[response.question_id.to_s] = ans["answer"] || ans[:answer]
        @other_answers[response.question_id.to_s] = ans["text"].to_s if ans["text"].present?
      elsif ans.is_a?(Hash)
        @existing_answers[response.question_id.to_s] = ans["text"] || ans["answer"] || ans[:text] || ans[:answer]
      else
        @existing_answers[response.question_id.to_s] = ans
      end
    end
  end

  # Admin-only: persist edits as the new "latest" state while preserving
  # previous versions.
  def update
    @survey = @survey_response.survey
    @student = @survey_response.student
    @return_to = safe_return_to_param

    raw_answers = params[:answers]
    answers = case raw_answers
    when ActionController::Parameters
                raw_answers.to_unsafe_h
    when Hash
                raw_answers
    else
                {}
    end
    answers = answers.stringify_keys

    raw_other_answers = params[:other_answers]
    other_answers = case raw_other_answers
    when ActionController::Parameters
              raw_other_answers.to_unsafe_h
    when Hash
              raw_other_answers
    else
              {}
    end
    other_answers = other_answers.stringify_keys

    questions_map = @survey.questions.includes(category: :section).index_by(&:id)
    allowed_question_ids = questions_map.keys

    ActiveRecord::Base.transaction do
      assignment = SurveyAssignment.find_by(student_id: @student.student_id, survey_id: @survey.id)

      # If the student has existing persisted answers but no snapshot for the
      # current state, capture a baseline so the admin edit doesn't erase
      # the only visible history.
      before_answers = SurveyResponseVersion.current_answers_for(student: @student, survey: @survey)
      existing_versions = SurveyResponseVersion
                            .for_pair(student_id: @student.student_id, survey_id: @survey.id)
                            .chronological

      if before_answers.present?
        latest_answers = existing_versions.last&.answers
        if latest_answers != before_answers
          SurveyResponseVersion.capture_current!(
            student: @student,
            survey: @survey,
            assignment: assignment,
            actor_user: current_user,
            event: :admin_snapshot
          )
        end
      end

      allowed_question_ids.each do |question_id|
        submitted_value = answers[question_id.to_s]
        question = questions_map[question_id]

        if question&.choice_question?
          selected_value = submitted_value.to_s
          if question.answer_option_requires_text?(selected_value) || selected_value.casecmp?("Other")
            submitted_value = { "answer" => selected_value, "text" => other_answers[question_id.to_s].to_s }
          end
        end

        record = StudentQuestion.find_or_initialize_by(student_id: @student.student_id, question_id: question_id)
        record.advisor_id ||= @student.advisor_id

        if submitted_value.present?
          record.answer = submitted_value
          record.save!(validate: false)
        elsif record.persisted?
          record.destroy!
        end
      end

      after_answers = SurveyResponseVersion.current_answers_for(student: @student, survey: @survey)
      if after_answers != before_answers
        SurveyResponseVersion.capture_current!(
          student: @student,
          survey: @survey,
          assignment: assignment,
          actor_user: current_user,
          event: :admin_edited
        )
      end
    end

    redirect_to survey_response_path(@survey_response.id, return_to: @return_to), notice: "Survey responses updated."
  end

  # Admin-only: delete a student's survey responses. This clears the student's
  # saved answers for the survey and resets completion.
  def destroy
    survey = @survey_response.survey
    student = @survey_response.student
    assignment = SurveyAssignment.find_by(student_id: student.student_id, survey_id: survey.id)
    removed_assignment = false

    ActiveRecord::Base.transaction do
      # Capture what existed before deletion.
      SurveyResponseVersion.capture_current!(
        student: student,
        survey: survey,
        assignment: assignment,
        actor_user: current_user,
        event: :admin_deleted
      )

      StudentQuestion.where(student_id: student.student_id, question_id: survey.questions.select(:id)).delete_all
      Feedback.where(student_id: student.student_id, survey_id: survey.id).delete_all
      AdvisorFeedbackSubmission.where(student_id: student.student_id, survey_id: survey.id).delete_all

      if assignment.present?
        if survey.is_active?
          assignment.update!(completed_at: nil)
        else
          SurveyResponseVersion.where(survey_assignment_id: assignment.id).update_all(survey_assignment_id: nil)
          assignment.destroy!
          removed_assignment = true
        end
      end
    end

    recipient = student.user
    notification_target = removed_assignment ? survey : (assignment || survey)
    if recipient
      Notification.deliver!(
        user: recipient,
        title: "Survey response deleted",
        message: "An admin deleted your responses for '#{survey.title}'. If the survey has not closed yet, you may submit again.",
        notifiable: notification_target,
        event_key: "survey.response.deleted",
        dedupe_key: "survey.response.deleted:survey:#{survey.id}:student:#{student.student_id}",
        metadata: {
          survey_id: survey.id,
          student_id: student.student_id,
          survey_assignment_id: assignment&.id,
          removed_assignment: removed_assignment
        }
      )
    end

    redirect_to survey_records_path, notice: "Survey responses deleted."
  end

  # Streams a PDF version of the survey response that matches the composite report payload.
  #
  # @return [void]
  def download
    unavailable_message = "Server-side PDF generation unavailable. Please use the 'Download as PDF' button which uses your browser's Print/Save-as-PDF feature."
    unless defined?(WickedPdf)
      logger.warn "Server-side PDF generation requested but WickedPdf is not available"
      render plain: unavailable_message, status: :service_unavailable and return
    end

    result = nil

    begin
      pdf_source_response = latest_valid_pdf_survey_response
      generator = CompositeReportGenerator.new(
        survey_response: pdf_source_response,
        cache: false,
        viewer_mode: composite_pdf_viewer_mode
      )
      result = generator.render
      filename = survey_pdf_filename(pdf_source_response)
      record_survey_response_export_audit!(
        export_type: "survey_response_pdf",
        description: "Exported survey response PDF.",
        survey_response: pdf_source_response
      )
      stream_pdf_result(result, filename, unavailable_message: unavailable_message)
    rescue CompositeReportGenerator::MissingDependency
      render plain: "Server-side PDF generation unavailable. WickedPdf not configured.", status: :service_unavailable
    rescue CompositeReportGenerator::GenerationError => e
      logger.error "Download PDF failed for SurveyResponse #{@survey_response.id}: #{e.message}"
      head :internal_server_error
    rescue => e
      message = <<~MSG
        Download PDF failed for SurveyResponse #{@survey_response.id}: #{e.class} - #{e.message}
        #{e.backtrace&.join("\n")}
      MSG
      logger.error(message.strip)
      head :internal_server_error
    ensure
      result&.cleanup!
    end
  end

  def latest_valid_pdf_survey_response
    versions = SurveyResponseVersion
                 .for_pair(student_id: @survey_response.student_id, survey_id: @survey_response.survey_id)
                 .chronological

    return @survey_response if versions.blank?

    preferred_version = versions
      .where(event: %w[submitted revised admin_edited])
      .order(created_at: :desc, id: :desc)
      .first

    selected_version = preferred_version || versions.last
    return @survey_response unless selected_version

    SurveyResponse.new(
      student: @survey_response.student,
      survey: @survey_response.survey,
      answers_override: selected_version.answers,
      as_of: selected_version.created_at
    )
  end

  # Streams a composite PDF aggregating student responses and advisor feedback.
  #
  # @return [void]
  def composite_report
    unavailable_message = "Composite PDF generation unavailable. Please try again later."
    unless defined?(WickedPdf)
      logger.warn "Composite PDF generation requested but WickedPdf is not available"
      render plain: unavailable_message, status: :service_unavailable and return
    end

    result = nil

    begin
      generator = CompositeReportGenerator.new(survey_response: @survey_response)
      result = generator.render
      filename = "composite_assessment_#{@survey_response.id}.pdf"
      record_survey_response_export_audit!(
        export_type: "survey_response_composite_pdf",
        description: "Exported composite survey response PDF.",
        survey_response: @survey_response
      )
      stream_pdf_result(result, filename, unavailable_message: unavailable_message)
    rescue CompositeReportGenerator::MissingDependency
      render plain: "Composite PDF generation unavailable. WickedPdf not configured.", status: :service_unavailable
    rescue CompositeReportGenerator::GenerationError => e
      logger.error "Composite report generation failed for SurveyResponse #{@survey_response.id}: #{e.message}"
      head :internal_server_error
    rescue => e
      message = <<~MSG
        Download composite PDF failed for SurveyResponse #{@survey_response.id}: #{e.class} - #{e.message}
        #{e.backtrace&.join("\n")}
      MSG
      logger.error(message.strip)
      head :internal_server_error
    ensure
      result&.cleanup!
    end
  end

  private

  def safe_return_to_param
    value = params[:return_to].to_s
    return nil if value.blank?
    return nil unless value.start_with?("/") && !value.start_with?("//")

    value
  end

  def composite_pdf_viewer_mode
    user = current_user
    if user&.respond_to?(:role_student?) && user.role_student?
      return :student
    end

    if user&.respond_to?(:role_admin?) && user.role_admin?
      return :staff
    end

    if user&.respond_to?(:role_advisor?) && user.role_advisor?
      return :staff
    end

    params[:token].present? ? :student : :staff
  end

  # Finds the survey response by signed token or ID parameter.
  #
  # @return [void]
  def set_survey_response
    token = params[:token].presence

    @survey_response = if token
      SurveyResponse.find_by_signed_download_token(token)
    elsif params[:id].present?
      SurveyResponse.find_from_param(params[:id])
    end

    return if @survey_response

    logger.warn "SurveyResponse lookup failed for id=#{params[:id]} token_present=#{token.present?}"
    head :not_found
  end

  # Ensures the current user is permitted to view the response.
  #
  # @return [void]
  def authorize_view!
    return if params[:token].present? # signed token grants access without session

    current = current_user
    if current&.role_admin?
      return
    end

    if current&.role_advisor?
      advisor_profile = current_advisor_profile
      assigned_advisor_id = @survey_response&.advisor_id

      if advisor_profile && assigned_advisor_id.present? && advisor_profile.advisor_id == assigned_advisor_id
        return
      end
    end

    student_profile = current_student
    if student_profile && student_profile.student_id == @survey_response.student_id
      return
    end

    logger.warn "Authorization failed for SurveyResponse #{@survey_response.id} user=#{current&.id}"
    head :unauthorized
  end

  def authorize_admin!
    return if current_user&.role_admin?

    head :unauthorized
  end

  # Ensures only admins or the student's assigned advisor can generate composite reports.
  #
  # @return [void]
  def authorize_composite!
    unless @survey_response
      head :not_found and return
    end

    if params[:token].present?
      logger.warn "Composite report access via token rejected for SurveyResponse #{@survey_response&.id}"
      head :unauthorized and return
    end

    current = current_user
    unless current
      logger.warn "Composite report access without authenticated user for SurveyResponse #{@survey_response&.id}"
      head :unauthorized and return
    end

    if current.role_admin?
      return
    end

    advisor_profile = current_advisor_profile
    assigned_advisor_id = @survey_response.advisor_id

    if advisor_profile && assigned_advisor_id.present? && advisor_profile.advisor_id == assigned_advisor_id
      return
    end

    logger.warn "Composite report authorization failed for SurveyResponse #{@survey_response&.id} user=#{current.id}"
    head :unauthorized
  end

  # Preloads related question responses for rendering.
  #
  # @return [ActiveRecord::Associations::CollectionProxy<QuestionResponse>]
  def preload_question_responses
    @survey_response.question_responses
  end

  def load_confidential_advisor_note!
    @confidential_advisor_note_enabled = false
    @confidential_advisor_note = nil

    current = current_user
    return unless current&.role_advisor?

    advisor_profile = current_advisor_profile
    return unless advisor_profile
    return unless @survey_response&.advisor_id.present? && advisor_profile.advisor_id == @survey_response.advisor_id

    @confidential_advisor_note_enabled = true
    @confidential_advisor_note = ConfidentialAdvisorNote.find_by(
      student_id: @survey_response.student_id,
      survey_id: @survey_response.survey_id,
      advisor_id: advisor_profile.advisor_id
    )
  end

  def load_self_target_summary!
    @self_target_summary = nil
    return unless completed_survey_response?

    @self_target_summary = SurveyResponses::SelfTargetSummary.build(survey_response: @survey_response)
  end

  def completed_survey_response?
    return true if @survey_assignment&.completed_at.present?
    return true if SurveyResponses::SelfTargetSummary.completed_version_event?(@selected_version&.event)
    return true if legacy_completed_survey_response?

    false
  end

  def legacy_completed_survey_response?
    return false unless @survey_response&.status == :submitted
    return true if @survey_assignment.blank?
    return true unless @survey_response.survey&.is_active?

    deadline = @survey_assignment.effective_available_until
    deadline.present? && deadline < Time.current
  end

  def load_versions!
    @versions = SurveyResponseVersion
                  .for_pair(student_id: @survey_response.student_id, survey_id: @survey_response.survey_id)
                  .chronological

    raw_version_id = params[:version_id].presence
    @selected_version = raw_version_id ? @versions.find_by(id: raw_version_id) : nil
    @selected_version ||= @versions.last if @versions.present?

    if @selected_version
      @survey_response = SurveyResponse.new(
        student: @survey_response.student,
        survey: @survey_response.survey,
        answers_override: @selected_version.answers,
        as_of: @selected_version.created_at
      )
    end

    # Determine previous/next for navigation.
    @previous_version = nil
    @next_version = nil

    if @versions.size > 1
      idx = @versions.index(@selected_version)
      if idx
        @previous_version = idx.positive? ? @versions[idx - 1] : nil
        @next_version = (idx < @versions.size - 1) ? @versions[idx + 1] : nil
      end
    end
  end

  # Sends the generated PDF with validation to guard against corrupt files.
  #
  # @param result [CompositeReportGenerator::Result]
  # @param filename [String]
  # @return [void]
  def stream_pdf_result(result, filename, unavailable_message: nil)
    path = result&.path

    unless path && File.exist?(path)
      logger.error "Composite PDF generation returned an invalid file for SurveyResponse=#{@survey_response.id}"
      return render_unavailable(unavailable_message)
    end

    pdf_data = read_pdf_bytes(path)
    return render_unavailable(unavailable_message) unless pdf_data

    unless pdf_data.start_with?("%PDF")
      logger.error "Composite PDF generation returned non-PDF payload for SurveyResponse=#{@survey_response.id}: first bytes=#{pdf_data.byteslice(0, 4).inspect}"
      return render_unavailable(unavailable_message)
    end

    send_data pdf_data, filename: filename, disposition: "attachment", type: "application/pdf"
  end

  def record_survey_response_export_audit!(export_type:, description:, survey_response:)
    record_export_audit!(
      export_type: export_type,
      description: description,
      subject: survey_response&.student,
      metadata: {
        student_id: survey_response&.student_id,
        survey_id: survey_response&.survey_id,
        advisor_id: survey_response&.advisor_id
      }
    )
  end

  def read_pdf_bytes(path)
    File.binread(path)
  rescue Errno::ENOENT => e
    logger.error "Composite PDF generation file missing for SurveyResponse=#{@survey_response.id}: #{e.message}"
    nil
  end

  def render_unavailable(message)
    if message.present?
      render plain: message, status: :service_unavailable
    else
      head :internal_server_error
    end
  end

  def survey_pdf_filename(survey_response)
    student_part = safe_filename_part(
      survey_response&.student&.user&.display_name,
      fallback: "student_#{survey_response&.student_id}"
    )

    survey_part = safe_filename_part(
      survey_response&.survey&.title,
      fallback: "survey_#{survey_response&.survey_id}"
    )

    "#{student_part}_#{survey_part}.pdf"
  end

  def safe_filename_part(value, fallback: "file")
    raw = value.to_s.strip
    raw = fallback.to_s.strip if raw.blank?

    sanitized = raw.parameterize(separator: "_")
    sanitized = fallback.to_s.parameterize(separator: "_") if sanitized.blank?
    sanitized
  end
end
