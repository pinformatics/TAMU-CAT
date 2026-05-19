# CRUD endpoints for advisor feedback records associated with survey
# responses.
class FeedbacksController < ApplicationController
  before_action :set_feedback, only: %i[ show edit update destroy ]
  before_action :set_survey_and_student, only: %i[new create]
  before_action :ensure_survey_active_for_feedback!, only: %i[new create edit update destroy]

  # Lists all feedback entries.
  #
  # @return [void]
  def index
    @feedbacks = Feedback.all
  end

  # Displays a single feedback entry.
  #
  # @return [void]
  def show
  end

  # Renders the new feedback form.
  #
  # @return [void]
  def new
    @submission_intent = normalize_submission_intent(params[:submission_intent])
    @saved_popup = params[:saved].to_s == "1"
    load_feedback_new_context
  end

  # Renders the edit form for existing feedback.
  #
  # @return [void]
  def edit; end

  # Creates a feedback record from submitted attributes.
  #
  # @return [void]
  def create
    @submission_intent = normalize_submission_intent(params[:submission_intent])
    Rails.logger.debug "[FeedbacksController#create] params_keys=#{params.keys.inspect} ratings_present=#{params[:ratings].present?} feedback_present=#{params[:feedback].present?}"
    @advisor = current_advisor_profile
    resolved_advisor_id = @advisor&.advisor_id || @student&.advisor_id
    if resolved_advisor_id.blank? && current_user&.role_admin?
      admin_advisor = Advisor.find_or_create_by!(advisor_id: current_user.id)
      resolved_advisor_id = admin_advisor.advisor_id
    end
    # Support two modes:
    # 1) batch per-category ratings via params[:ratings]
    # 2) per-category single feedback via nested feedback params
    if params[:ratings].present?
      raw_ratings = params.require(:ratings)
      ratings = raw_ratings.to_unsafe_h.each_with_object({}) do |(cat_id, values), memo|
        allowed = if values.respond_to?(:permit)
                    values.permit(:id, :lock_version, :average_score, :comments).to_h
        else
                    values.to_h.slice("id", "lock_version", "average_score", "comments")
        end
        memo[cat_id] = allowed
      end

      if submit_intent?
        @missing_rating_question_ids = missing_required_rating_question_ids(ratings)
        if @missing_rating_question_ids.any?
          @feedback = Feedback.new
          load_feedback_new_context
          flash.now[:alert] = "Please complete all required Advisor Rating fields before submitting."
          respond_to do |format|
            format.html { render :new, status: :unprocessable_entity }
            format.json do
              render json: {
                error: "missing_required_advisor_ratings",
                missing_question_ids: @missing_rating_question_ids
              }, status: :unprocessable_entity
            end
          end
          return
        end
      end

      batch_errors = {}
      saved_feedbacks = []

      Feedback.transaction do
        ratings.each do |qid_str, data|
          Rails.logger.debug "[FeedbacksController#create] processing question=#{qid_str} data=#{data.inspect}"
          qid = qid_str.to_i
          attrs = data.to_h

          # Skip empty inputs
          next if attrs["average_score"].blank? && attrs["comments"].blank?

          question = Question.find_by(id: qid)

          fb = if attrs["id"].present?
            Feedback.find_by(id: attrs["id"], student_id: @student.student_id, survey_id: @survey.id, advisor_id: resolved_advisor_id)
          else
            Feedback.new(student_id: @student.student_id,
              survey_id: @survey.id,
              question_id: qid,
              category_id: question&.category_id,
              advisor_id: resolved_advisor_id)
          end

          Rails.logger.debug "[FeedbacksController#create] found fb=#{fb.inspect} attrs=#{attrs.inspect}"

          unless fb
            batch_errors[qid] = [ "Feedback record not found" ]
            next
          end

          fb.average_score = attrs["average_score"].presence
          fb.comments = attrs["comments"].presence
          fb.survey_id = @survey.id
          fb.student_id = @student.student_id
          fb.advisor_id = resolved_advisor_id
          fb.question_id = qid

          if fb.advisor_id.blank?
            batch_errors[qid] = [ "Advisor not assigned for this student." ]
            next
          end

          if attrs["lock_version"].present?
            fb.lock_version = attrs["lock_version"].to_i
          end

          begin
            unless fb.save
              batch_errors[qid] = fb.errors.full_messages
            else
              saved_feedbacks << fb
            end
          rescue ActiveRecord::StaleObjectError
            batch_errors[qid] = [ "This feedback was updated by someone else. Refresh and try again." ]
          end
        end

        if batch_errors.any?
          raise ActiveRecord::Rollback
        else
          begin
            save_confidential_advisor_note_from_params!
          rescue ActiveRecord::StaleObjectError
            batch_errors[:confidential_advisor_note] = [ "This note was updated by someone else. Refresh and try again." ]
            raise ActiveRecord::Rollback
          end
        end
      end

      if batch_errors.any?
        @batch_errors = batch_errors
        Rails.logger.error "[FeedbacksController#create] batch_errors=#{batch_errors.inspect}"
        @feedback = Feedback.new
        load_feedback_new_context
        respond_to do |format|
          format.html { render :new, status: :unprocessable_entity }
          format.json { render json: { errors: batch_errors }, status: :unprocessable_entity }
        end
        return
      end

      if saved_feedbacks.empty?
        # Allow note-only saves so the single Save action persists all page content.
        if params[:confidential_advisor_note].present?
          begin
            save_confidential_advisor_note_from_params!
          rescue ActiveRecord::StaleObjectError
            @feedback = Feedback.new
            load_feedback_new_context
            flash.now[:alert] = "This note was updated by someone else. Refresh and try again."
            respond_to do |format|
              format.html { render :new, status: :conflict }
              format.json { render json: { error: "conflict" }, status: :conflict }
            end
            return
          end
          respond_to do |format|
            sync_feedback_submission_state!(resolved_advisor_id)
            format.html { redirect_to feedback_success_redirect_path, notice: feedback_saved_notice, status: :see_other }
            format.json { render json: { ok: true }, status: :created }
          end
          return
        end

        Rails.logger.error "[FeedbacksController#create] saved_feedbacks empty; ratings=#{ratings.inspect}"
        @feedback = Feedback.new
        @feedback.errors.add(:base, "No ratings provided")
        load_feedback_new_context
        respond_to do |format|
          format.html { render :new, status: :unprocessable_entity }
          format.json { render json: { error: "No ratings provided" }, status: :unprocessable_entity }
        end
        return
      end

      @feedback = saved_feedbacks.first
      sync_feedback_submission_state!(resolved_advisor_id)
      enqueue_feedback_received_notification!(@feedback)

      respond_to do |format|
        format.html { redirect_to feedback_success_redirect_path, notice: feedback_saved_notice, status: :see_other }
        format.json { render json: saved_feedbacks, status: :created }
      end
      return
    elsif params[:feedback].present? && params.dig(:feedback, :question_id).present?
      # per-question single feedback
      set_survey_and_student unless @survey && @student
      @advisor = current_advisor_profile
      @feedback = Feedback.new(
        survey_id: @survey.id,
        student_id: @student.student_id,
        advisor_id: resolved_advisor_id,
        question_id: feedback_params[:question_id],
        category_id: Question.find_by(id: feedback_params[:question_id])&.category_id,
        average_score: feedback_params[:average_score],
        comments: feedback_params[:comments]
      )
    else
      # Support note-only submissions even when the feedback UI posts no ratings.
      if params[:confidential_advisor_note].present?
        save_confidential_advisor_note_from_params!
        sync_feedback_submission_state!(resolved_advisor_id)
        respond_to do |format|
          format.html { redirect_to feedback_success_redirect_path, notice: feedback_saved_notice, status: :see_other }
          format.json { render json: { ok: true }, status: :created }
        end
        return
      end

      @feedback = Feedback.new
      @feedback.errors.add(:base, "No category or ratings provided")
      respond_to do |format|
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { error: "No category or ratings provided" }, status: :unprocessable_entity }
      end
      return
    end

    respond_to do |format|
      if @feedback.save
        begin
          save_confidential_advisor_note_from_params!
          sync_feedback_submission_state!(@feedback.advisor_id)
          enqueue_feedback_received_notification!(@feedback)
        rescue ActiveRecord::StaleObjectError
          load_feedback_new_context
          flash.now[:alert] = "This note was updated by someone else. Refresh and try again."
          format.html { render :new, status: :conflict }
          format.json { render json: { error: "conflict" }, status: :conflict }
          return
        end
        format.html { redirect_to feedback_success_redirect_path, notice: feedback_saved_notice, status: :see_other }
        format.json { render json: @feedback, status: :created, location: @feedback }
      else
        load_feedback_new_context
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @feedback.errors, status: :unprocessable_entity }
      end
    end
  end

  # Updates an existing feedback entry.
  #
  # @return [void]
  def update
    respond_to do |format|
      if @feedback.update(feedback_params)
        # If we have survey_id and student_id context, redirect back to the advisor feedback page
        if feedback_params[:survey_id].present? && feedback_params[:student_id].present?
          format.html { redirect_to new_feedback_path(survey_id: feedback_params[:survey_id], student_id: feedback_params[:student_id]), notice: "Feedback was successfully updated.", status: :see_other }
        else
          format.html { redirect_to @feedback, notice: "Feedback was successfully updated.", status: :see_other }
        end
        format.json { render :show, status: :ok, location: @feedback }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @feedback.errors, status: :unprocessable_entity }
      end
    end
  end

  # Deletes feedback and redirects back to the index.
  #
  # @return [void]
  def destroy
    @feedback.destroy!

    respond_to do |format|
      format.html { redirect_to feedbacks_path, notice: "Feedback was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
  # Finds the feedback referenced in the request.
  #
  # @return [void]
  def set_feedback
    @feedback = Feedback.find(params[:id])
  end

  # Strong parameters for feedback creation/update.
  #
  # @return [ActionController::Parameters]
  def feedback_params
    params.require(:feedback).permit(:advisor_id, :category_id, :survey_id, :student_id, :question_id, :comments, :average_score, :lock_version)
  end

  def load_feedback_new_context
    # Build PORO and related data the `new` view expects so re-rendering `new`
    # preserves student responses and existing feedback state.
    @return_to = safe_return_to_param
    version = latest_survey_response_version
    @survey_response = SurveyResponse.build(
      student: @student,
      survey: @survey,
      answers_override: version ? remapped_version_answers(version) : nil,
      as_of: version&.created_at
    )
    question_ids = @survey.questions.select(:id)
    @responses = StudentQuestion.where(student_id: @student.student_id, question_id: question_ids).includes(question: :category)
    @existing_feedbacks = Feedback.where(student_id: @student.student_id, survey_id: @survey.id).includes(:category, :advisor, :question)

    pick_latest = lambda do |items|
      items.compact.max_by { |fb| fb.updated_at || fb.created_at || Time.at(0) }
    end

    @existing_feedbacks_by_category = @existing_feedbacks
      .select { |fb| fb.category_id.present? }
      .group_by(&:category_id)
      .transform_values { |items| pick_latest.call(items) }

    @existing_feedbacks_by_question = @existing_feedbacks
      .select { |fb| fb.question_id.present? }
      .group_by(&:question_id)
      .transform_values { |items| pick_latest.call(items) }

    apply_feedback_prefill! if params[:prefill].to_s == "true"

    load_confidential_note_context
  end

  def load_confidential_note_context
    @confidential_notes_enabled = false
    @confidential_note_owner_advisor_id = nil
    @confidential_note_current = nil
    @confidential_note_tabs = []

    current = current_user
    return unless current

    if current.role_advisor?
      advisor_profile = current_advisor_profile
      return unless advisor_profile
      return unless @student&.advisor_id.present? && advisor_profile.advisor_id == @student.advisor_id

      @confidential_note_owner_advisor_id = advisor_profile.advisor_id
    elsif current.role_admin?
      return unless @student&.advisor_id.present?

      @confidential_note_owner_advisor_id = @student.advisor_id
    else
      return
    end

    @confidential_notes_enabled = true

    notes = ConfidentialAdvisorNote
              .where(student_id: @student.student_id, advisor_id: @confidential_note_owner_advisor_id)
              .includes(:survey)

    @confidential_note_current = notes.find { |note| note.survey_id == @survey.id }

    other_notes = notes.reject { |note| note.survey_id == @survey.id }

    tabs = []
    tabs << {
      survey: @survey,
      note: @confidential_note_current,
      editable: true
    }

    other_notes.each do |note|
      tabs << {
        survey: note.survey,
        note: note,
        editable: false
      }
    end

    @confidential_note_tabs = tabs
  end

  def set_survey_and_student
    survey_id = params[:survey_id] || params.dig(:feedback, :survey_id)
    student_id = params[:student_id] || params.dig(:feedback, :student_id)

    @survey = Survey.find(survey_id)
    @student = Student.find(student_id)
  end

  def ensure_survey_active_for_feedback!
    survey = @survey || @feedback&.survey
    return if survey&.is_active?

    redirect_to student_records_path, alert: "This survey is archived and feedback is read-only."
  end

  def save_confidential_advisor_note_from_params!
    return unless params[:confidential_advisor_note].present?

    advisor_id = confidential_note_owner_advisor_id_for_current_user
    return unless advisor_id

    body = params.dig(:confidential_advisor_note, :body).to_s
    submitted_lock_version = params.dig(:confidential_advisor_note, :lock_version)

    note = ConfidentialAdvisorNote.find_or_initialize_by(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: advisor_id
    )

    if body.strip.blank?
      note.destroy if note.persisted?
      return
    end

    note.body = body
    if submitted_lock_version.present?
      note.lock_version = submitted_lock_version.to_i
    end
    note.save!
  end

  def confidential_note_owner_advisor_id_for_current_user
    current = current_user
    return nil unless current

    if current.role_advisor?
      advisor_profile = current_advisor_profile
      return nil unless advisor_profile
      return nil unless @student&.advisor_id.present? && advisor_profile.advisor_id == @student.advisor_id

      return advisor_profile.advisor_id
    end

    if current.role_admin?
      return nil unless @student&.advisor_id.present?

      return @student.advisor_id
    end

    nil
  end

  def feedback_saved_notice
    student_name = @student&.full_name.presence || @student&.user&.display_name.presence || @student&.email || "Student"
    survey_name = @survey&.title.presence || "Survey"
    if submit_intent?
      "Submitted feedback for #{student_name} on #{survey_name}."
    else
      "Saved draft feedback for #{student_name} on #{survey_name}."
    end
  end

  def feedback_success_redirect_path
    safe_return_to_param
  end

  def normalize_submission_intent(raw_value)
    value = raw_value.to_s.strip.downcase
    return "save" if value == "save"
    return "submit" if value == "submit"

    "save"
  end

  def submit_intent?
    @submission_intent == "submit"
  end

  def required_feedback_question_ids
    survey_questions = @survey.questions.includes(category: :section)
    survey_questions
      .select do |question|
        !question.sub_question? &&
          (!question.respond_to?(:has_feedback?) || question.has_feedback?)
      end
      .map(&:id)
      .uniq
  end

  def missing_required_rating_question_ids(ratings_hash)
    provided_rating_ids = ratings_hash.each_with_object([]) do |(question_id, attributes), memo|
      score = attributes.to_h["average_score"].to_s
      memo << question_id.to_i if score.present?
    end

    required_feedback_question_ids - provided_rating_ids
  end

  def sync_feedback_submission_state!(advisor_id)
    return if advisor_id.blank?

    pair_feedback_scope = Feedback.where(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: advisor_id
    )

    has_feedback_data = pair_feedback_scope.where(
      "average_score IS NOT NULL OR (comments IS NOT NULL AND comments <> '')"
    ).exists?

    has_confidential_note = ConfidentialAdvisorNote.where(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: advisor_id
    ).exists?

    submission = AdvisorFeedbackSubmission.find_or_initialize_by(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: advisor_id
    )

    if !has_feedback_data && !has_confidential_note
      submission.destroy if submission.persisted?
      return
    end

    now = Time.current
    submission.last_saved_at = now
    submission.submitted_at = now if submit_intent?
    submission.save!
  end

  def latest_survey_response_version
    @latest_survey_response_version ||= SurveyResponseVersion
      .where(student_id: @student.student_id, survey_id: @survey.id)
      .order(created_at: :desc, id: :desc)
      .first
  end

  def remapped_version_answers(version)
    current_questions = @survey.questions.order(:id).to_a
    raw_answers = version.answers.to_h.transform_keys(&:to_s)
    id_offset = legacy_answer_id_offset(current_questions, raw_answers)

    current_questions.each_with_object({}) do |question, memo|
      value = raw_answers[question.id.to_s] || raw_answers[(question.id - id_offset).to_s]
      memo[question.id] = value if value.present?
    end
  end

  def legacy_answer_id_offset(current_questions, answers)
    numeric_answer_ids = answers.keys.filter_map { |key| key.match?(/\A\d+\z/) ? key.to_i : nil }
    return 0 if current_questions.empty? || numeric_answer_ids.empty?
    return 0 if current_questions.any? { |question| answers.key?(question.id.to_s) }

    current_question_ids = current_questions.map(&:id)
    numeric_answer_ids
      .flat_map { |answer_id| current_question_ids.map { |question_id| question_id - answer_id } }
      .tally
      .max_by { |offset, count| [ count, -offset.abs ] }
      &.first || 0
  end

  def apply_feedback_prefill!
    survey_answers = @survey_response.answers

    feedback_questions.each do |question|
      next if @existing_feedbacks_by_question[question.id].present?

      score = normalize_feedback_prefill_score(survey_answers[question.id] || survey_answers[question.id.to_s])
      next if score.blank?

      @existing_feedbacks_by_question[question.id] = Feedback.new(
        student_id: @student.student_id,
        survey_id: @survey.id,
        advisor_id: confidential_note_owner_advisor_id_for_current_user || @student.advisor_id,
        question_id: question.id,
        category_id: question.category_id,
        average_score: score
      )
    end
  end

  def feedback_questions
    @feedback_questions ||= @survey
      .questions
      .includes(category: :section)
      .select do |question|
        !question.sub_question? &&
          question.question_type == "dropdown" &&
          question.category&.section&.mha_competency? &&
          (!question.respond_to?(:has_feedback?) || question.has_feedback?)
      end
  end

  def normalize_feedback_prefill_score(value)
    raw = case value
    when Hash
      value["answer"] || value[:answer] || value["value"] || value[:value] || value["rating"] || value[:rating]
    else
      value
    end

    numeric = begin
      Float(raw)
    rescue ArgumentError, TypeError
      raw.to_s[/([0-5])(?:\D*)\z/, 1]&.to_f
    end

    return nil unless numeric&.between?(0, 5)

    numeric.round.to_s
  end

  def safe_return_to_param
    return_to = params[:return_to].to_s
    return student_records_path if return_to.blank?

    # Only allow local (relative) paths to avoid open redirects.
    return_to.start_with?("/") && !return_to.start_with?("//") ? return_to : student_records_path
  end

  def enqueue_feedback_received_notification!(feedback)
    return unless submit_intent?
    return unless feedback&.id

    SurveyNotificationJob.perform_later(event: :feedback_received, feedback_id: feedback.id)
  rescue StandardError => e
    Rails.logger.warn("Feedback notification enqueue failed for Feedback #{feedback&.id}: #{e.class} - #{e.message}")
  end
end
