# Handles student-facing survey listing, completion, and submission flows.
class SurveysController < ApplicationController
  protect_from_forgery except: :save_progress
  before_action :set_survey, only: %i[show submit save_progress]
  before_action :redirect_completed_assignment!, only: %i[show submit save_progress]
  before_action :redirect_unavailable_assignment!, only: %i[show submit save_progress]

  # Lists active surveys ordered by display priority.
  #
  # @return [void]
  def index
    @student = current_student
    now = Time.current
    assignments = if @student
                    SurveyAssignment
                      .where(student_id: @student.student_id)
                      .effective_available_at(now)
                      .select(:id, :survey_id, :assigned_at, :available_from, :available_until, :completed_at)
    else
                    SurveyAssignment.none
    end

    assigned_survey_ids = assignments.map(&:survey_id)

    @surveys = if assigned_survey_ids.any?
                 Survey.active
                       .includes(:questions, :track_assignments)
                       .where(id: assigned_survey_ids)
                       .ordered
    else
                 Survey.none
    end

    @assignment_lookup = assignments.index_by(&:survey_id)

    @offerings_by_survey_id = {}
    if SurveyOffering.data_source_ready? && @student&.program_year.present? && @student&.track.present? && @surveys.any?
      offerings = SurveyOffering
                    .for_student(track_key: @student.track, class_of: @student.program_year)
                    .where(survey_id: @surveys.map(&:id))

      grouped = offerings.group_by(&:survey_id)
      grouped.each do |survey_id, rows|
        exact = rows.find { |row| row.class_of.present? && row.class_of.to_i == @student.program_year.to_i }
        @offerings_by_survey_id[survey_id] = exact || rows.first
      end
    end

    @current_semester_label = ProgramSemester.current_name.presence || fallback_semester_label
  end

  # Presents the survey form, pre-populating answers and required flags.
  #
  # @return [void]
  def show
    @return_to = safe_return_to_param
      # Avoid relying on a potentially partially-loaded association proxy.
      # This ensures newly-added categories/questions show up immediately.
      scope = Category.where(survey_id: @survey.id).includes(:section, :questions)
      @category_groups = if Category.column_names.include?("position")
                           scope.order(:position, :id)
      else
                           scope.order(:id)
      end
    @existing_answers = {}
    @other_answers = {}
    @computed_required = {}
    student = current_student

    if student
      @survey_assignment = SurveyAssignment.find_by(student_id: student.student_id, survey_id: @survey.id)

      if @survey_assignment&.completed_at?
        can_revise = @survey_assignment.can_edit_now?
        if can_revise
          flash.now[:notice] ||= "You’re editing a submitted survey. Previous submissions are still visible in your submission history."
        end
      end
    end

    if student
      responses = StudentQuestion
                    .where(student_id: student.student_id, question_id: @survey.questions.select(:id))
                    .includes(:question)

      responses.each do |response|
        ans = response.answer
        # Normalize stored shapes so views get a text answer and a separate rating when present
        if ans.is_a?(Hash)
          if response.question.question_type == "evidence" && ans["link"].present?
            @existing_answers[response.question_id.to_s] = ans["link"]
          elsif %w[multiple_choice dropdown].include?(response.question.question_type) && ans["answer"].present?
            @existing_answers[response.question_id.to_s] = ans["answer"]
            if ans["text"].present? || response.question.answer_option_requires_text?(ans["answer"].to_s)
              @other_answers[response.question_id.to_s] = ans["text"].to_s
            end
          else
            # For competency/non-evidence questions we previously stored {"text"=>..., "rating"=>n}
            text_value = ans["text"] || ans["answer"]
            text_value = ans["rating"].to_s if text_value.blank? && ans["rating"].present?
            @existing_answers[response.question_id.to_s] = text_value
          end
        else
          # Use string key to match view's expectation
          @existing_answers[response.question_id.to_s] = ans
        end
      end
    end

    @category_groups.each do |category|
      category_branch_parent_ids = SurveyQuestionRules.branch_parent_ids(category.questions)
      category.questions.each do |question|
        @computed_required[question.id] = SurveyQuestionRules.required_for_submission?(
          question,
          answers: @existing_answers,
          branch_parent_ids: category_branch_parent_ids
        )
      end
    end


    @invalid_evidence ||= nil
  end

  # Processes survey submissions, validating required answers and evidence
  # links before persisting student responses.
  #
  # @return [void]
  def submit
    student = current_student

    unless student
      redirect_to student_dashboard_path, alert: "We could not find a student record for your account."
      return
    end

    Rails.logger.info(
      "[SUBMIT] Received submit request request_id=#{request.request_id} survey_id=#{@survey.id} student_id=#{student.student_id} user_id=#{current_user&.id}"
    )

    assignment = SurveyAssignment.find_by(student_id: student.student_id, survey_id: @survey.id)
    if assignment&.completed_at? && !assignment.can_edit_now?
      survey_response = SurveyResponse.build(student: student, survey: @survey)
      redirect_to survey_response_path(survey_response), alert: "This survey has already been submitted and is now closed. It can only be viewed."
      return
    end

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
    @first_error_question_id = nil
    @first_error_section_dom_id = nil
    answers_present = answers.values.any? do |value|
      case value
      when Hash
        value.values.any?(&:present?)
      when Array
        value.any?(&:present?)
      else
        value.present?
      end
    end
    @scroll_to_form_top = !answers_present

    # Build a questions map for efficient lookups
    questions_map = @survey.questions.includes(category: :section).index_by(&:id)
    allowed_question_ids = questions_map.keys

    missing_required = []
    invalid_links = []
    invalid_integer_responses = []
    branch_parent_ids = SurveyQuestionRules.branch_parent_ids(questions_map.values)

    questions_map.each_value do |question|
      submitted_value = answers[question.id.to_s]

      if question.choice_question?
        selected_value = submitted_value.to_s
        if question.answer_option_requires_text?(selected_value) || selected_value.casecmp?("Other")
          submitted_value = {
            "answer" => selected_value,
            "text" => other_answers[question.id.to_s].to_s
          }
        end
      end

      required = SurveyQuestionRules.required_for_submission?(question, answers:, branch_parent_ids:)

      if required && SurveyQuestionRules.blank_required_response?(question, submitted_value)
        missing_required << question
      end

      # Only validate evidence questions for Google-hosted links
      if question.question_type == "evidence" && submitted_value.present?
        value_str = submitted_value.is_a?(String) ? submitted_value : submitted_value.to_s
        # 1) basic format check
        if value_str !~ StudentQuestion::GOOGLE_URL_REGEX
          invalid_links << question
        else
          # 2) accessibility check (HEAD with redirects, GET fallback)
          accessible, reason = evidence_accessible?(value_str)
          invalid_links << question unless accessible
        end
      end

      if question.question_type == "integer" && submitted_value.present? && !valid_integer_response_for_question?(question, submitted_value)
        invalid_integer_responses << question
      end
    end

    if missing_required.any? || invalid_links.any? || invalid_integer_responses.any?
      Rails.logger.warn(
        "[SUBMIT VALIDATION] request_id=#{request.request_id} survey_id=#{@survey.id} student_id=#{student.student_id} " \
        "missing_required_question_ids=#{missing_required.map(&:id)} invalid_evidence_question_ids=#{invalid_links.map(&:id)} " \
        "invalid_integer_question_ids=#{invalid_integer_responses.map(&:id)}"
      )

      # Avoid relying on a potentially partially-loaded association proxy.
      # This ensures newly-added categories/questions show up immediately.
      scope = Category.where(survey_id: @survey.id).includes(:section, :questions)
      @category_groups = if Category.column_names.include?("position")
                           scope.order(:position, :id)
      else
                           scope.order(:id)
      end
      @existing_answers = answers
      @other_answers = other_answers
      @computed_required = {}
      @invalid_evidence = invalid_links.map(&:id)
      @invalid_integer = invalid_integer_responses.map(&:id)
      @missing_required = missing_required.map(&:id)
      ordered_ids = question_ids_in_display_order(@category_groups)
      ordered_ids = @survey.questions.order(:question_order).pluck(:id) if ordered_ids.blank?

      # Keep jump behavior predictable: first errored question in display order.
      error_candidates = (missing_required + invalid_links + invalid_integer_responses).map(&:id).uniq
      @first_error_question_id = (ordered_ids & error_candidates).first || error_candidates.first
      if @first_error_question_id
        first_error_question = questions_map[@first_error_question_id]
        first_error_category = first_error_question&.category
        first_error_section = first_error_category&.section
        @first_error_section_dom_id = if first_error_section.present?
                                        "survey-section-#{first_error_section.id}"
        elsif first_error_category.present?
                                        "survey-category-#{first_error_category.id}"
        end
      end
      alert_parts = [ "We could not submit your responses yet." ]
      alert_parts << "Answer all required questions before submitting." if missing_required.any?
      if invalid_links.any?
        alert_parts << "Review the highlighted evidence links and set sharing to 'Anyone with the link can view.'"
      end
      if invalid_integer_responses.any?
        alert_parts << "Review the highlighted integer responses and use whole numbers within the allowed range."
      end
      flash.now[:alert] = alert_parts.join(" ")
      @category_groups.each do |category|
        category_branch_parent_ids = SurveyQuestionRules.branch_parent_ids(category.questions)
        category.questions.each do |question|
          @computed_required[question.id] = SurveyQuestionRules.required_for_submission?(
            question,
            answers:,
            branch_parent_ids: category_branch_parent_ids
          )
        end
      end

      # Persist provided answers even when submit fails
      ActiveRecord::Base.transaction do
        allowed_question_ids.each do |question_id|
          submitted_value = answers[question_id.to_s]

          question = questions_map[question_id]
          if question&.choice_question?
            selected_value = submitted_value.to_s
            if question.answer_option_requires_text?(selected_value) || selected_value.casecmp?("Other")
              submitted_value = { "answer" => selected_value, "text" => other_answers[question_id.to_s].to_s }
            end
          end

          record = StudentQuestion.find_or_initialize_by(student_id: student.student_id, question_id: question_id)
          record.advisor_id ||= student.advisor_id

          if submitted_value.present?
            record.answer = submitted_value
            record.save(validate: false)
          elsif record.persisted?
            record.destroy!
          end
        end
      end
      render :show, status: :unprocessable_entity and return
    end

    ActiveRecord::Base.transaction do
      allowed_question_ids.each do |question_id|
        submitted_value = answers[question_id.to_s]

        question = questions_map[question_id]
        if question&.choice_question?
          selected_value = submitted_value.to_s
          if question.answer_option_requires_text?(selected_value) || selected_value.casecmp?("Other")
            submitted_value = { "answer" => selected_value, "text" => other_answers[question_id.to_s].to_s }
          end
        end

        if question&.question_type == "integer" && submitted_value.present? && !valid_integer_response_for_question?(question, submitted_value)
          record = StudentQuestion.find_or_initialize_by(student_id: student.student_id, question_id: question_id)
          record.errors.add(:response_value, "must satisfy integer question constraints")
          raise ActiveRecord::RecordInvalid.new(record)
        end

        record = StudentQuestion.find_or_initialize_by(student_id: student.student_id, question_id: question_id)
        record.advisor_id ||= student.advisor_id

        if submitted_value.present?
          record.answer = submitted_value
          record.save!
        elsif record.persisted?
          record.destroy!
        end
      end
    end

    begin
      assignment = nil
      was_completed = nil

      ActiveRecord::Base.transaction do
        Rails.logger.info "[SUBMIT] Creating/updating assignment for survey #{@survey.id}, student #{student.student_id}"

        assignment = SurveyAssignment.lock.find_by(survey_id: @survey.id, student_id: student.student_id)
        unless assignment
          begin
            assignment = SurveyAssignment.create!(
              survey_id: @survey.id,
              student_id: student.student_id,
              advisor_id: student.advisor_id,
              assigned_at: Time.current
            )
          rescue ActiveRecord::RecordNotUnique
            assignment = SurveyAssignment.lock.find_by!(survey_id: @survey.id, student_id: student.student_id)
          end
        end

        assignment.advisor_id ||= student.advisor_id
        assignment.assigned_at ||= Time.current

        assignment.available_from ||= @survey.available_from
        assignment.available_until ||= @survey.available_until
        assignment.save! if assignment.changed?

        was_completed = assignment.completed_at?

        Rails.logger.info "[SUBMIT] Marking assignment #{assignment.id} as completed"
        assignment.mark_completed!

        begin
          SurveyResponseVersion.capture_current!(
            student: student,
            survey: @survey,
            assignment: assignment,
            actor_user: current_user,
            event: (was_completed ? :revised : :submitted),
            skip_if_unchanged: true
          )
        rescue StandardError => version_error
          Rails.logger.warn "[SUBMIT] Failed to capture survey response version: #{version_error.class}: #{version_error.message}"
        end
      end

      Rails.logger.info "[SUBMIT] Enqueueing notification job"
      begin
        SurveyNotificationJob.perform_later(
          event: :response_submitted,
          survey_assignment_id: assignment.id,
          metadata: { revision: was_completed }
        )

        if was_completed && Feedback.exists?(student_id: student.student_id, survey_id: @survey.id)
          SurveyNotificationJob.perform_later(event: :student_revised_after_feedback, survey_assignment_id: assignment.id)
        end
      rescue StandardError => job_error
        # Don't fail submission if job enqueue fails
        Rails.logger.warn "[SUBMIT] Failed to enqueue notification job: #{job_error.class}: #{job_error.message}"
      end

      Rails.logger.info "[SUBMIT] Building survey response"
      survey_response = SurveyResponse.build(student: student, survey: @survey)
      progress_summary = survey_response.progress_summary
      survey_response_id = survey_response.id
      notice_message = build_progress_notice(
        prefix: "Survey submitted successfully!",
        progress: progress_summary
      )

      Rails.logger.info "[SUBMIT] Redirecting to survey response path with ID: #{survey_response_id}"
      begin
        redirect_to survey_response_path(survey_response_id), notice: notice_message
      rescue ActionController::UrlGenerationError => url_error
        Rails.logger.error "[SUBMIT] URL generation failed: #{url_error.message}"
        redirect_to student_dashboard_path, notice: notice_message
      end
    rescue StandardError => e
      Rails.logger.error "[SUBMIT ERROR] Failed to complete survey submission: #{e.class}: #{e.message}"
      Rails.logger.error "[SUBMIT ERROR] Backtrace:\n#{e.backtrace.first(20).join("\n")}"

      # Re-raise if it's an ActiveRecord error that should propagate
      raise if e.is_a?(ActiveRecord::RecordInvalid) || e.is_a?(ActiveRecord::RecordNotSaved)

      redirect_to survey_path(@survey), alert: "An error occurred while submitting the survey. Please try again or contact support if the problem persists."
    end
  end

  # Saves the current survey progress without validating required fields.
  # Allows students to save their work and continue later.
  #
  # @return [void]
  def save_progress
    student = current_student

    unless student
      if autosave_request?
        render json: { saved: false, message: "We could not find a student record for your account." }, status: :unprocessable_entity
        return
      end
      redirect_to student_dashboard_path, alert: "We could not find a student record for your account."
      return
    end

    assignment = SurveyAssignment.find_by(student_id: student.student_id, survey_id: @survey.id)
    if assignment&.completed_at?
      if !assignment.can_edit_now?
        survey_response = SurveyResponse.build(student: student, survey: @survey)
        if autosave_request?
          render json: { saved: false, message: "This survey is closed." }, status: :unprocessable_entity
          return
        end
        redirect_to survey_response_path(survey_response), alert: "This survey has already been submitted and is now closed. It can only be viewed."
      else
        if autosave_request?
          render json: { saved: false, message: "This submitted survey can only be updated with Submit Survey." }, status: :unprocessable_entity
          return
        end
        redirect_to survey_path(@survey), alert: "This survey has already been submitted. Use Submit Survey to update your answers."
      end
      return
    end

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

    questions_map = @survey.questions.index_by(&:id)
    allowed_question_ids = questions_map.keys

    saved_count = 0
    ActiveRecord::Base.transaction do
      allowed_question_ids.each do |question_id|
        submitted_value = answers[question_id.to_s]
        question = questions_map[question_id]

        # Integer questions support draft saves even for out-of-range values.
        # Normalize to a plain string and persist without submit-time validation.
        if question&.question_type == "integer"
          submitted_value = normalized_integer_draft_value(submitted_value)
        end

        if question&.choice_question?
          selected_value = submitted_value.to_s
          if question.answer_option_requires_text?(selected_value) || selected_value.casecmp?("Other")
            submitted_value = { "answer" => selected_value, "text" => other_answers[question_id.to_s].to_s }
          end
        end

        record = StudentQuestion.find_or_initialize_by(student_id: student.student_id, question_id: question_id)
        record.advisor_id ||= student.advisor_id

        if submitted_value.present?
          record.answer = submitted_value
          # Skip validations when saving progress; validations happen on submit
          if record.save(validate: false)
            saved_count += 1
          end
        elsif record.persisted?
          record.destroy!
        end
      end
    end

    survey_response = SurveyResponse.build(student: student, survey: @survey)
    progress_summary = survey_response.progress_summary
    notice_message = build_progress_notice(
      prefix: "Progress saved! You can continue later.",
      progress: progress_summary
    )

    if autosave_request?
      render json: { saved: true, message: notice_message, saved_count: saved_count }
    else
      redirect_to save_progress_redirect_path, notice: notice_message
    end
  end

  private

  # Finds the survey requested by the route.
  #
  # @return [void]
  def set_survey
    @survey = Survey.includes(:legend, :sections, categories: %i[section questions]).find(params[:id])
  end

  def autosave_request?
    params[:autosave].present? || request.xhr? || request.format.json?
  end

  def save_progress_redirect_path
    if params[:stay].present?
      return_to = safe_internal_path(params[:return_to])
      return return_to.present? ? survey_path(@survey, return_to:) : survey_path(@survey)
    end

    safe_internal_path(params[:exit_to]) || student_dashboard_path
  end

  def safe_internal_path(value)
    path = value.to_s
    return nil if path.blank?
    return nil unless path.start_with?("/") && !path.start_with?("//")

    path
  end

  def question_ids_in_display_order(category_groups)
    Array(category_groups).flat_map do |category|
      next [] unless category

      questions = category.questions
      ordered_questions = if questions.respond_to?(:loaded?) && questions.loaded?
                            questions.sort_by do |q|
                              parent_id = q.respond_to?(:parent_question_id) ? q.parent_question_id : nil
                              group_key = (parent_id || q.id).to_i
                              sub_flag = q.respond_to?(:sub_question?) ? (q.sub_question? ? 1 : 0) : (parent_id ? 1 : 0)
                              sub_order = q.respond_to?(:sub_question_order) ? q.sub_question_order.to_i : 0
                              [ q.question_order.to_i, group_key, sub_flag, sub_order, q.id.to_i ]
                            end
      else
                            relation = questions.order(:question_order)

                            if Question.sub_question_columns_supported?
                              relation
                                .order(Arel.sql("COALESCE(parent_question_id, id)"))
                                .order(Arel.sql("CASE WHEN parent_question_id IS NULL THEN 0 ELSE 1 END"))
                                .order(:sub_question_order, :id)
                                .to_a
                            else
                              relation.order(:id).to_a
                            end
      end
      ordered_questions.map(&:id)
    end
  end

  def valid_integer_response_for_question?(question, value)
    candidate = case value
    when String
      value.strip
    when Numeric
      value.to_s
    when Hash
      (value["answer"] || value[:answer] || value["text"] || value[:text] || value["value"] || value[:value]).to_s.strip
    else
      value.to_s.strip
    end

    return false unless candidate.match?(/\A\d+\z/)

    int_value = candidate.to_i
    min = question.respond_to?(:integer_min_value) ? question.integer_min_value : 1
    max = question.respond_to?(:integer_max_value) ? question.integer_max_value : nil

    return false if int_value < min
    return false if max.present? && int_value > max

    true
  end

  def required_for_submission?(question, answers:, branch_parent_ids: [])
    SurveyQuestionRules.required_for_submission?(question, answers:, branch_parent_ids:)
  end

  def blank_required_response?(question, submitted_value)
    SurveyQuestionRules.blank_required_response?(question, submitted_value)
  end

  def normalized_answer_value(value)
    SurveyQuestionRules.normalize_answer_value(value)
  end

  def normalized_integer_draft_value(value)
    case value
    when String
      value.strip
    when Numeric
      value.to_s
    when Hash
      (value["answer"] || value[:answer] || value["text"] || value[:text] || value["value"] || value[:value]).to_s.strip
    else
      value.to_s.strip
    end
  end

  # Prevents students from editing a survey that has already been submitted.
  # Redirects them to the read-only SurveyResponse view instead.
  def redirect_completed_assignment!
    student = current_student
    return unless student && @survey

    assignment = SurveyAssignment.find_by(student_id: student.student_id, survey_id: @survey.id)
    return unless assignment&.completed_at?

    return if assignment.can_edit_now?

    survey_response = SurveyResponse.build(student: student, survey: @survey)
    redirect_to survey_response_path(survey_response), alert: "This survey has already been submitted and is now closed. It can only be viewed." and return
  end

  def redirect_unavailable_assignment!
    student = current_student
    return unless student && @survey

    assignment = SurveyAssignment.find_by(student_id: student.student_id, survey_id: @survey.id)
    return unless assignment

    unless @survey.is_active?
      survey_response = SurveyResponse.build(student: student, survey: @survey)
      redirect_to survey_response_path(survey_response), alert: "This survey is no longer available." and return
    end

    case assignment.availability_status
    when :not_yet
      message = "This survey is not available yet."
      if assignment.available_from.present?
        message = "This survey will be available starting #{I18n.l(assignment.available_from)}."
      end
      redirect_to surveys_path, alert: message and return
    when :closed
      message = "This survey is no longer available."
      if assignment.available_until.present?
        message = "This survey closed on #{I18n.l(assignment.available_until)}."
      end

      survey_response = SurveyResponse.build(student: student, survey: @survey)
      redirect_to survey_response_path(survey_response), alert: message and return
    end
  end

  # Checks if a Google Sites link is publicly accessible.
  # Returns [Boolean accessible, Symbol reason]
  def evidence_accessible?(url)
    EvidenceLinkChecker.call(url)
  end

  def build_progress_notice(prefix:, progress: {})
    total_questions = progress[:total_questions].to_i
    answered_total = progress[:answered_total].to_i
    return prefix if total_questions.zero?

    description = [
      "#{answered_total}/#{total_questions} questions answered",
      progress[:total_required].to_i.positive? ? "(#{progress[:answered_required]}/#{progress[:total_required]} required)" : nil
    ].compact.join(" ")

    message = [ prefix.to_s.strip, description ].reject(&:blank?).join(" ").strip
    message.ends_with?(".") ? message : "#{message}."
  end
end
