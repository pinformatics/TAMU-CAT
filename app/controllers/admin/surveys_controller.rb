# Admin interface for building, editing, and tracking lifecycle events for
# surveys. Provides search, filtering, and management capabilities for survey
# definitions used throughout the program.
require "securerandom"

class Admin::SurveysController < Admin::BaseController
  before_action :set_survey, only: %i[edit update destroy preview copy copy_to_semester archive activate]
  before_action :prepare_supporting_data, only: %i[new create edit update]

  # Lists active and archived surveys with optional search and track filters.
  # Sets instance variables consumed by the index template, including recent
  # change logs and available track filters.
  #
  # @return [void]
  def index
    @search_query = params[:q].to_s.strip
    @selected_track = params[:track].presence

    allowed_sort_columns = {
      "title" => "surveys.title",
      "semester" => "program_semesters.name",
      "updated_at" => "surveys.updated_at",
      "category_count" => "category_count",
      "section_count" => "section_count"
    }

    @sort_column = params[:sort].presence_in(allowed_sort_columns.keys) || "updated_at"
    @sort_direction = params[:direction] == "asc" ? "asc" : "desc"

    active_scope = Survey.active.left_joins(:track_assignments, :program_semester)

    if @selected_track.present?
      if @selected_track == unassigned_track_token
        active_scope = active_scope.where(survey_track_assignments: { id: nil })
      else
        active_scope = active_scope.where(survey_track_assignments: { track: @selected_track })
      end
    end

    if @search_query.present?
      term = "%#{@search_query.downcase}%"
      active_scope = active_scope.where(
        "LOWER(surveys.title) LIKE :term OR LOWER(program_semesters.name) LIKE :term OR LOWER(COALESCE(surveys.description, '')) LIKE :term",
        term: term
      )
    end

    active_scope = active_scope
      .left_joins(:categories, :questions, :sections, :survey_assignments)
      .select(
        "surveys.*, " \
        "COUNT(DISTINCT survey_sections.id) AS section_count, " \
        "COUNT(DISTINCT categories.id) AS category_count, " \
        "COUNT(DISTINCT questions.id) AS question_count, " \
        "COUNT(DISTINCT survey_assignments.id) AS assignment_count, " \
        "COUNT(DISTINCT CASE WHEN survey_assignments.completed_at IS NOT NULL THEN survey_assignments.id END) AS completed_assignment_count"
      )
      .group("surveys.id", "program_semesters.name")

    order_expression = allowed_sort_columns[@sort_column]
    active_scope = active_scope.order(Arel.sql("#{order_expression} #{@sort_direction}"))
    active_scope = active_scope.order("surveys.id ASC")

    @active_surveys = active_scope.preload(:track_assignments, :program_semester).load
    @active_survey_groups = surveys_grouped_by_semester(@active_surveys)

    @track_filter_options = (
      Survey.track_options +
      SurveyTrackAssignment.distinct.pluck(:track)
    ).compact.map(&:to_s).reject(&:blank?).uniq.sort
    @unassigned_track_token = unassigned_track_token

    @archived_surveys = Survey.archived.includes(:categories, :track_assignments, :creator, :program_semester).order(updated_at: :desc)
    @archived_survey_groups = surveys_grouped_by_semester(@archived_surveys)
    @recent_logs = SurveyChangeLog.recent.includes(:survey, :admin).limit(12)
  end

  # Renders the form for creating a new survey, seeding it with a default
  # category and question so admins can begin editing immediately.
  #
  # @return [void]
  def new
    @survey = Survey.new(creator: current_user, semester: default_semester)
    build_default_structure(@survey)
    ensure_section_form_state(@survey)
  end

  # Creates a new survey, assigns tracks, and logs the change for auditing.
  #
  # @return [void]
  def create
    @survey = Survey.new(survey_params)
    @survey.creator ||= current_user
    @survey.semester ||= default_semester

    tracks = selected_tracks
    resolve_category_sections(@survey)

    if @survey.save
      persist_category_section_links
      @survey.assign_tracks!(tracks)
      @survey.log_change!(admin: current_user, action: "create", description: "Survey created with #{tracks.size} track(s)")
      SurveyNotificationJob.perform_later(event: :survey_updated, survey_id: @survey.id, metadata: { summary: "New survey created" })
      redirect_to admin_surveys_path, notice: "Survey created successfully."
    else
      build_default_structure(@survey)
      ensure_section_form_state(@survey)
      render :new, status: :unprocessable_entity
    end
  end

  # Presents the edit form for a survey, ensuring each category has at least
  # one question block ready for editing.
  #
  # @return [void]
  def edit
    build_default_structure(@survey)
    ensure_section_form_state(@survey)
  end

  # Updates survey attributes, persisted category/question structure, and track
  # assignments while capturing a human-readable change summary.
  #
  # @return [void]
  def update
    autosave_request = params[:autosave].to_s == "1"
    force_deadline_for_everyone = params[:force_deadline_for_everyone].to_s == "1"
    tracks = selected_tracks
    before_snapshot = survey_snapshot(@survey)

    before_target_levels = if Question.column_names.include?("program_target_level")
                             @survey.questions.pluck(:id, :program_target_level).to_h
    else
                             {}
    end

    previous_available_from = @survey.available_from
    previous_available_until = @survey.available_until

    if autosave_request && Rails.env.development?
      raw = params[:survey].is_a?(ActionController::Parameters) ? params[:survey] : ActionController::Parameters.new
      sections_keys = raw[:sections_attributes].is_a?(ActionController::Parameters) ? raw[:sections_attributes].keys : []
      categories_keys = raw[:categories_attributes].is_a?(ActionController::Parameters) ? raw[:categories_attributes].keys : []
      questions_count = 0
      if raw[:categories_attributes].is_a?(ActionController::Parameters)
        raw[:categories_attributes].each_value do |cat|
          next unless cat.is_a?(ActionController::Parameters)
          qa = cat[:questions_attributes]
          questions_count += qa.keys.size if qa.is_a?(ActionController::Parameters)
        end
      end

      Rails.logger.info(
        "[autosave] survey=#{@survey.id} incoming sections=#{sections_keys.size} categories=#{categories_keys.size} questions=#{questions_count}"
      )
    end

    permitted_params = survey_params
    scrub_stale_section_attributes!(permitted_params)

    @survey.assign_attributes(permitted_params)
    resolve_category_sections(@survey)

    if @survey.save
      if autosave_request && Rails.env.development?
        Rails.logger.info(
          "[autosave] survey=#{@survey.id} persisted sections=#{@survey.sections.size} categories=#{@survey.categories.size} questions=#{@survey.questions.size}"
        )
      end
      if before_target_levels.present?
        after_target_levels = @survey.questions.reload.pluck(:id, :program_target_level).to_h

        touched_question_ids = []

        before_target_levels.each do |question_id, before_level|
          after_level = after_target_levels[question_id]
          next if before_level == after_level
          next if before_level.blank? && after_level.blank?

          touched_question_ids << question_id
        end

        before_target_levels.each do |question_id, before_level|
          next if after_target_levels.key?(question_id)
          next if before_level.blank?

          touched_question_ids << question_id
        end

        after_target_levels.each do |question_id, after_level|
          next if before_target_levels.key?(question_id)
          next if after_level.blank?

          touched_question_ids << question_id
        end

        touched_question_ids.uniq!

        if touched_question_ids.present?
          completed_count = SurveyAssignment.where(survey_id: @survey.id).where.not(completed_at: nil).count
          if completed_count.positive?
            flash[:warning] = "Target levels changed for #{touched_question_ids.size} question(s). #{completed_count} student(s) have already submitted this survey; reports and exports may reflect the updated targets."
          end
        end
      end

      sync_competency_targets_from_questions!(survey: @survey, tracks: tracks)

        if force_deadline_for_everyone ||
          previous_available_from != @survey.available_from ||
          previous_available_until != @survey.available_until
        all_assignments_scope = SurveyAssignment.where(survey_id: @survey.id)
        has_offerings = SurveyOffering.data_source_ready? && SurveyOffering.where(survey_id: @survey.id).exists?

        inherited_scope_for = lambda do |scope:, column:, previous_value:|
          column_name = case column.to_sym
          when :available_from
            :available_from
          when :available_until
            :available_until
          else
            raise ArgumentError, "Unsupported assignment inheritance column: #{column.inspect}"
          end

          assignments = SurveyAssignment.arel_table
          assignment_column = assignments[column_name]

          if previous_value.nil?
            scope.where(column_name => nil)
          else
            scope.where(
              assignment_column.eq(previous_value).or(
                Arel::Nodes::NamedFunction.new("DATE", [ assignment_column ]).eq(previous_value.to_date)
              )
            )
          end
        end

        if has_offerings
          updates = {
            available_from: @survey.available_from,
            available_until: @survey.available_until,
            updated_at: Time.current
          }

          if SurveyOffering.column_names.include?("portfolio_due_date")
            updates[:portfolio_due_date] = @survey.available_until
          end

          SurveyOffering.where(survey_id: @survey.id).update_all(updates)

          if force_deadline_for_everyone
            all_assignments_scope.update_all(
              available_until: nil,
              updated_at: Time.current
            )
          else
            if previous_available_from != @survey.available_from
              inherited_scope_for.call(
                scope: all_assignments_scope,
                column: :available_from,
                previous_value: previous_available_from
              ).update_all(
                available_from: @survey.available_from,
                updated_at: Time.current
              )
            end

            if previous_available_until != @survey.available_until
              inherited_scope_for.call(
                scope: all_assignments_scope,
                column: :available_until,
                previous_value: previous_available_until
              ).update_all(
                available_until: @survey.available_until,
                updated_at: Time.current
              )
            end
          end
        else
          if force_deadline_for_everyone
            all_assignments_scope.update_all(
              available_until: nil,
              updated_at: Time.current
            )
          else
            if previous_available_from != @survey.available_from
              inherited_scope_for.call(
                scope: all_assignments_scope,
                column: :available_from,
                previous_value: previous_available_from
              ).update_all(
                available_from: @survey.available_from,
                updated_at: Time.current
              )
            end

            if previous_available_until != @survey.available_until
              inherited_scope_for.call(
                scope: all_assignments_scope,
                column: :available_until,
                previous_value: previous_available_until
              ).update_all(
                available_until: @survey.available_until,
                updated_at: Time.current
              )
            end
          end
        end
        end

      persist_category_section_links
      @survey.assign_tracks!(tracks)
      description = change_summary(before_snapshot, survey_snapshot(@survey), tracks)
      @survey.log_change!(admin: current_user, action: "update", description: description)
      SurveyNotificationJob.perform_later(event: :survey_updated, survey_id: @survey.id, metadata: { summary: description })
      notice = if force_deadline_for_everyone
        "Survey updated successfully. Personal assignment deadlines were cleared so everyone now follows the survey deadline, including completed responses."
      else
        "Survey updated successfully."
      end
      redirect_to admin_surveys_path, notice: notice
    else
      Rails.logger.info("[autosave] survey=#{@survey.id} save FAILED: #{@survey.errors.full_messages.to_sentence}") if autosave_request && Rails.env.development?
      build_default_structure(@survey)
      ensure_section_form_state(@survey)
      render :edit, status: :unprocessable_entity
    end
  end

  # Rails nested attributes will raise ActiveRecord::RecordNotFound if the form
  # submits an id that no longer exists for this survey (e.g., stale DOM after
  # deletes + reload races). Drop those entries so updates remain idempotent.
  def scrub_stale_section_attributes!(permitted_params)
    sections = permitted_params[:sections_attributes]
    return unless sections.present?

    sections_hash = sections.respond_to?(:to_h) ? sections.to_h : sections
    return unless sections_hash.is_a?(Hash)

    valid_ids = @survey.sections.pluck(:id).map(&:to_s).to_set

    scrubbed = {}
    sections_hash.each do |key, attrs|
      next unless attrs.present?

      attrs_hash = attrs.respond_to?(:to_h) ? attrs.to_h : attrs
      next unless attrs_hash.is_a?(Hash)

      submitted_id = attrs_hash[:id] || attrs_hash["id"]
      if submitted_id.present? && !valid_ids.include?(submitted_id.to_s)
        Rails.logger.info("[survey_update] dropping stale section id=#{submitted_id} for survey=#{@survey.id}") if Rails.env.development?
        next
      end

      scrubbed[key] = attrs
    end

    permitted_params[:sections_attributes] = scrubbed
  end

  # Deletes a survey and records the action in the change log.
  #
  # @return [void]
  def destroy
    summary = "Survey deleted (#{@survey.title})"
    @survey.log_change!(admin: current_user, action: "delete", description: summary)
    @survey.destroy!
    redirect_to admin_surveys_path, notice: "Survey deleted successfully."
  end

  # Archives a survey while preserving its track configuration for future
  # reactivation and recording the action.
  #
  # @return [void]
  def archive
    removed_assignments = 0

    begin
      Survey.transaction do
        @survey.lock!
        removed_assignments = purge_incomplete_assignments!(@survey)
        @survey.update!(is_active: false, available_until: nil)
        @survey.survey_assignments.update_all(available_until: nil, updated_at: Time.current)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
      redirect_to edit_admin_survey_path(@survey), alert: e.message and return
    end

    summary = "Survey archived"
    if removed_assignments.positive?
      assignment_label = removed_assignments == 1 ? "assignment" : "assignments"
      summary += "; removed #{removed_assignments} pending #{assignment_label}"
    end

    @survey.log_change!(admin: current_user, action: "archive", description: summary)
    SurveyNotificationJob.perform_later(event: :survey_archived, survey_id: @survey.id)

    notice = "Survey archived."
    if removed_assignments.positive?
      assignment_label = removed_assignments == 1 ? "assignment" : "assignments"
      notice = "#{notice} Removed #{removed_assignments} pending #{assignment_label}."
    end

    redirect_to admin_surveys_path, notice: notice
  end

  # Reactivates a previously archived survey and records the action.
  #
  # @return [void]
  def activate
    if @survey.update(is_active: true)
      @survey.log_change!(admin: current_user, action: "activate", description: "Survey reactivated")
      redirect_to admin_surveys_path, notice: "Survey activated."
    else
      redirect_to edit_admin_survey_path(@survey), alert: @survey.errors.full_messages.to_sentence
    end
  end

  # Displays a read-only preview of the survey structure and captures a log
  # entry noting the preview action.
  #
  # @return [void]
  def preview
    offering_scope = @survey.offerings
    preview_offering = offering_scope.where.not(class_of: nil).order(:class_of).first || offering_scope.order(:class_of).first
    preview_track = preview_offering&.track || @survey.track_list.first
    preview_class_of = preview_offering&.class_of
    preview_student = OpenStruct.new(
      student_id: 0,
      advisor: nil,
      user: nil,
      track: preview_track,
      program_year: preview_class_of
    )
    @preview_survey_response = SurveyResponse.new(
      student: preview_student,
      survey: @survey,
      answers_override: {}
    )
  end

  def copy
    prepare_copy_options
  end

  def copy_to_semester
    prepare_copy_options
    target_semester = ProgramSemester.find_by(id: copy_survey_params[:target_program_semester_id])
    copied_survey = Surveys::CopyToSemester.call(
      source_survey: @survey,
      target_semester: target_semester,
      actor: current_user
    )

    redirect_to edit_admin_survey_path(copied_survey),
                notice: "Survey copied to #{copied_survey.semester}. No students were assigned."
  rescue Surveys::CopyToSemester::Error, ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.message
    render :copy, status: :unprocessable_entity
  end

  private

  # Looks up the survey referenced by the request parameters.
  #
  # @return [void]
  def set_survey
    relation = Survey.includes(:sections, categories: :section)
    relation = relation.includes(:offerings) if SurveyOffering.data_source_ready?
    @survey = relation.find(params[:id])
  end

  def purge_incomplete_assignments!(survey)
    assignments = survey.survey_assignments.incomplete
    return 0 unless assignments.exists?
    removed = 0

    assignments.find_each do |assignment|
      SurveyResponseVersion.where(survey_assignment_id: assignment.id).update_all(survey_assignment_id: nil)
      assignment.destroy!
      removed += 1
    end

    removed
  end

  # Strong parameters for survey creation/update, including nested category and
  # question attributes.
  #
  # @return [ActionController::Parameters]
  def survey_params
    question_attributes = [
      :id,
      :question_text,
      :description,
      :tooltip_text,
      :question_type,
      :question_order,
      :answer_options,
      :prompt_format,
      :integer_min,
      :integer_max,
      :is_required,
      :has_evidence_field,
      :_destroy
    ]

    question_attributes << :has_feedback if Question.new.respond_to?(:has_feedback)
    question_attributes << :program_target_level if Question.new.respond_to?(:program_target_level)
    question_attributes << :parent_question_id if Question.new.respond_to?(:parent_question_id)
    question_attributes << :sub_question_order if Question.new.respond_to?(:sub_question_order)

    permitted = params.require(:survey).permit(
      :title,
      :description,
      :semester,
      :available_from,
      :available_until,
      :is_active,
      :show_course_competencies_with_survey,
      :advisor_numeric_feedback_enabled,
      track_list: [],
      offerings_attributes: [
        :id,
        :review_meetings_start,
        :review_meetings_end
      ],
      legend_attributes: [
        :id,
        :title,
        :body,
        :_destroy
      ],
      categories_attributes: [
        :id,
        :name,
        :description,
        :position,
        :section_form_uid,
        :_destroy,
        questions_attributes: [
          *question_attributes
        ]
      ],
      sections_attributes: [
        :id,
        :title,
        :description,
        :position,
        :form_uid,
        :_destroy
      ]
    )

    permitted.delete(:track_list)
    permitted
  end

  # Extracts and normalizes track selections from the submitted parameters.
  #
  # @return [Array<String>] list of unique track identifiers chosen by the admin
  def selected_tracks
    raw = params[:survey]
    values = raw.is_a?(ActionController::Parameters) ? raw[:track_list] : nil

    Array(values)
      .map { |value| Survey.canonical_track(value) }
      .compact
      .uniq
  end

  # Loads supporting data such as available tracks and question types for the
  # survey form.
  #
  # @return [void]
  def prepare_supporting_data
    @available_tracks = Survey.track_options
    @question_types = Question.question_types.keys
    @program_semester_options = ProgramSemester.ordered.pluck(:name)
  end

  def prepare_copy_options
    @copy_target_semesters = ProgramSemester.operational.ordered.where.not(id: @survey.program_semester_id)
    @target_program_semester_id = copy_survey_params[:target_program_semester_id].presence ||
                                  @copy_target_semesters.first&.id
  end

  def copy_survey_params
    params.fetch(:survey_copy, ActionController::Parameters.new).permit(:target_program_semester_id)
  end

  def surveys_grouped_by_semester(surveys)
    surveys
      .group_by { |survey| survey.program_semester&.name.presence || survey.semester.presence || "Unscheduled" }
      .sort_by { |semester_name, rows| semester_group_sort_key(semester_name, rows.first) }
  end

  def semester_group_sort_key(semester_name, survey)
    if (match = semester_name.to_s.match(/\A(\w+)\s+(\d{4})\z/))
      term_order = { "winter" => 0, "spring" => 1, "summer" => 2, "fall" => 3 }[match[1].downcase] || 99
      return [ -match[2].to_i, -term_order, semester_name.to_s ]
    end

    timestamp = survey&.updated_at&.to_time&.to_i || 0
    [ -timestamp, semester_name.to_s ]
  end

  # Phase 1 single-source transition:
  # mirror per-question target level edits into competency_target_levels,
  # while retaining Question#program_target_level for compatibility.
  def sync_competency_targets_from_questions!(survey:, tracks:)
    return unless survey&.respond_to?(:questions)

    titles = Reports::DataAggregator::COMPETENCY_TITLES
    return if titles.blank?

    selected_tracks = Array(tracks).map { |track| Survey.canonical_track(track) || track }
    selected_tracks = selected_tracks.compact.reject(&:blank?).uniq
    selected_tracks = survey.track_list if selected_tracks.blank?
    return if selected_tracks.blank?

    competency_questions = survey.questions.where(question_text: titles)
    return if competency_questions.empty?

    competency_questions.find_each do |question|
      title = question.question_text.to_s.strip
      next if title.blank?

      level = question.respond_to?(:program_target_level) ? question.program_target_level.presence : nil

      selected_tracks.each do |track|
        attrs = {
          program_semester_id: survey.program_semester_id,
          track: track,
          class_of: nil,
          competency_title: title
        }

        if level.blank?
          CompetencyTargetLevel.where(attrs).delete_all
          next
        end

        record = CompetencyTargetLevel.find_or_initialize_by(attrs)
        record.target_level = level.to_i
        record.save!
      end
    end
  end

  # Ensures the survey has at least one category with a question scaffolded for
  # editing.
  #
  # @param survey [Survey]
  # @return [void]
  def build_default_structure(survey)
    if survey.categories.empty?
      category = survey.categories.build(name: "New Category")
      build_default_question(category)
    else
      survey.categories.each do |category|
        build_default_question(category) if category.questions.empty?
      end
    end
  end

  # Adds a placeholder question to a category if none exist.
  #
  # @param category [Category]
  # @return [void]
  def build_default_question(category)
    category.questions.build(
      question_text: "New question",
      question_type: Question.question_types.keys.first,
      question_order: (category.questions.maximum(:question_order) || 0) + 1,
      is_required: false,
      has_evidence_field: false
    )
  end

  # Determines the semester label to use when a survey does not specify one.
  #
  # @return [String]
  def default_semester
    ProgramSemester.current_name.presence || calculated_semester_from_calendar
  end

  def calculated_semester_from_calendar
    current = Time.zone.today
    year = current.year
    season = case current.month
    when 1..4 then "Spring"
    when 5..7 then "Summer"
    else "Fall"
    end
    "#{season} #{year}"
  end

  # Builds a snapshot of salient survey attributes for before/after comparisons.
  #
  # @param survey [Survey]
  # @return [Hash]
  def survey_snapshot(survey)
    snapshot_time = lambda do |value|
      value&.in_time_zone&.strftime("%Y-%m-%d %H:%M")
    end

    {
      title: survey.title,
      semester: survey.semester,
      description: survey.description,
      available_from: snapshot_time.call(survey.available_from),
      available_until: snapshot_time.call(survey.available_until),
      is_active: survey.is_active,
      tracks: survey.track_list,
      categories: survey.categories.map do |category|
        {
          name: category.name,
          question_count: category.questions.size
        }
      end
    }
  end

  # Produces a human-readable summary of differences between two survey
  # snapshots.
  #
  # @param before [Hash]
  # @param after [Hash]
  # @param tracks [Array<String>]
  # @return [String]
  def change_summary(before, after, tracks)
    diffs = []
    %i[title semester description available_from available_until is_active].each do |attribute|
      before_value = before[attribute]
      after_value = after[attribute]
      next if before_value == after_value

      diffs << "#{survey_change_label(attribute)} changed from #{survey_change_value(attribute, before_value)} to #{survey_change_value(attribute, after_value)}."
    end

    if before[:tracks].sort != tracks.sort
      diffs << "Tracks updated to #{tracks.join(', ')}."
    end

    before_counts = before[:categories].map { |c| c[:question_count] }
    after_counts = after[:categories].map { |c| c[:question_count] }
    diffs << "Category or question structure updated." if before_counts != after_counts

    diffs.present? ? diffs.join(" ") : "No question or structure changes were detected."
  end

  def survey_change_label(attribute)
    {
      available_from: "Open date",
      available_until: "Due date",
      is_active: "Is active"
    }.fetch(attribute, attribute.to_s.humanize)
  end

  def survey_change_value(attribute, value)
    return "not set" if value.nil? || (value.respond_to?(:empty?) && value.empty?)

    case attribute
    when :available_from, :available_until
      parsed_time = Time.zone.parse(value.to_s)
      parsed_time ? parsed_time.to_fs(:long) : value
    when :is_active
      ActiveModel::Type::Boolean.new.cast(value) ? "active" : "archived"
    else
      "'#{value}'"
    end
  rescue ArgumentError
    value
  end

  # Token representing surveys with no track assignments when filtering.
  #
  # @return [String]
  def unassigned_track_token
    "__unassigned"
  end

  def ensure_section_form_state(survey)
    return if survey.blank?

    survey.sections.each do |section|
      section.form_uid = section_form_uid_for(section)
    end

    survey.categories.each do |category|
      next if category.section_form_uid.present?

      if category.section.present?
        section_uid = section_form_uid_for(category.section)
        category.section_form_uid = section_uid if section_uid.present?
      elsif category.survey_section_id.present?
        category.section_form_uid = "section-#{category.survey_section_id}"
      end
    end
  end

  def resolve_category_sections(survey)
    return if survey.blank?

    section_lookup = {}
    survey.sections.each do |section|
      next if section.marked_for_destruction?

      section.survey ||= survey
      uid = section_form_uid_for(section)
      next if uid.blank?

      section_lookup[uid] = section
      section_lookup[section.id.to_s] = section if section.id.present?
    end

    survey.categories.each do |category|
      key = category.section_form_uid.presence
      next if key.blank?

      section = section_lookup[key]
      section ||= section_lookup["section-#{key}"] unless key.start_with?("section-")
      next unless section

      if section.persisted?
        category.section = section
      else
        pending_category_section_links << [ category, section ]
      end
    end
  end

  def section_form_uid_for(section)
    return if section.blank?

    if section.form_uid.present?
      section.form_uid
    elsif section.id.present?
      section.form_uid = "section-#{section.id}"
    else
      section.form_uid = "section-temp-#{SecureRandom.hex(6)}"
    end
  end

  def pending_category_section_links
    @pending_category_section_links ||= []
  end

  def persist_category_section_links
    return if pending_category_section_links.empty?

    pending_category_section_links.each do |category, section|
      next unless category.persisted? && section.persisted?

      category.update_columns(survey_section_id: section.id)
    end

    pending_category_section_links.clear
  end
end
