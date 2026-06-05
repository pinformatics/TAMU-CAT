# frozen_string_literal: true

# NOTE: `Admin` is an ActiveRecord model class in this app (app/models/admin.rb),
# so we define namespaced controllers using `class Admin::X < Admin::BaseController`
# (matching existing admin controllers) rather than `module Admin`.
class Admin::TargetLevelsController < Admin::BaseController
  def index
    redirect_to admin_program_setup_path(
      tab: "targets",
      program_semester_id: params[:program_semester_id],
      track: params[:track],
      class_of: params[:class_of]
    )
  end

  def update
    load_selector_options

    unless @selected_semester_id.present? && @selected_track.present? && @selected_class_of.present?
      redirect_to admin_program_setup_path(tab: "targets"), alert: "Select a semester, track, and cohort before updating target levels."
      return
    end

    competency_titles = Reports::DataAggregator::COMPETENCY_TITLES

    before_targets = CompetencyTargetLevel
      .where(
        program_semester_id: @selected_semester_id,
        track: @selected_track,
        class_of: @selected_class_of,
        competency_title: competency_titles
      )
      .pluck(:competency_title, :target_level)
      .to_h

    targets_payload = params[:targets]

    targets = if targets_payload.respond_to?(:to_unsafe_h)
      targets_payload.to_unsafe_h
    else
      targets_payload
    end

    targets ||= {}

    ActiveRecord::Base.transaction do
      targets.values.each do |entry|
        next unless entry.is_a?(Hash)

        title = entry["competency_title"].to_s
        raw_level = entry["target_level"].to_s.strip

        next if title.blank?

        if raw_level.blank?
          CompetencyTargetLevel.where(
            program_semester_id: @selected_semester_id,
            track: @selected_track,
            class_of: @selected_class_of,
            competency_title: title
          ).delete_all
          next
        end

        level = raw_level.to_i
        record = CompetencyTargetLevel.find_or_initialize_by(
          program_semester_id: @selected_semester_id,
          track: @selected_track,
          class_of: @selected_class_of,
          competency_title: title
        )
        record.target_level = level
        record.save!
      end
    end

    after_targets = CompetencyTargetLevel
      .where(
        program_semester_id: @selected_semester_id,
        track: @selected_track,
        class_of: @selected_class_of,
        competency_title: competency_titles
      )
      .pluck(:competency_title, :target_level)
      .to_h

    if before_targets != after_targets
      submitted_students = submitted_students_count_for_selected_context

      if submitted_students.positive?
        semester_label = @semesters.find { |s| s.id == @selected_semester_id }&.name || "selected semester"
        session[:target_levels_post_save_warning] = "Target levels changed. #{submitted_students} student(s) have already submitted surveys for #{@selected_track} (#{semester_label}); reports may reflect the updated targets."
        notify_admins_target_levels_changed_after_submissions!(
          semester_label: semester_label,
          submitted_students: submitted_students
        )
      end
    end

    redirect_to admin_program_setup_path(
      tab: "targets",
      program_semester_id: @selected_semester_id,
      track: @selected_track,
      class_of: @selected_class_of
    ), notice: "Target levels updated."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to admin_program_setup_path(
      tab: "targets",
      program_semester_id: @selected_semester_id,
      track: @selected_track,
      class_of: @selected_class_of
    ), alert: e.record.errors.full_messages.to_sentence
  end

  def fill_defaults
    load_selector_options

    unless @selected_semester_id.present? && @selected_track.present? && @selected_class_of.present?
      redirect_to admin_program_setup_path(tab: "targets"), alert: "Select a semester, track, and cohort before filling default target levels."
      return
    end

    result = TargetLevels::DefaultApplier.new(
      program_semester_id: @selected_semester_id,
      track: @selected_track,
      class_of: @selected_class_of
    ).call

    redirect_to admin_program_setup_path(
      tab: "targets",
      program_semester_id: @selected_semester_id,
      track: @selected_track,
      class_of: @selected_class_of
    ), notice: "Default target levels filled: #{result.created_count} added, #{result.skipped_count} already set."
  rescue ArgumentError => e
    redirect_to admin_program_setup_path(
      tab: "targets",
      program_semester_id: @selected_semester_id,
      track: @selected_track,
      class_of: @selected_class_of
    ), alert: e.message
  end

  def copy_to_current
    load_selector_options

    unless @selected_semester_id.present? && @selected_track.present? && @selected_class_of.present?
      redirect_to admin_program_setup_path(tab: "targets"), alert: "Select a source semester, track, and cohort before copying target levels."
      return
    end

    current_semester = ProgramSemester.current
    if current_semester.blank?
      redirect_to selected_context_path, alert: "Set a current semester before copying target levels."
      return
    end

    if current_semester.id == @selected_semester_id
      redirect_to selected_context_path, alert: "This context is already the current semester."
      return
    end

    source_records = copy_source_target_records
    if source_records.empty?
      redirect_to selected_context_path, alert: "No configured target levels were found for the selected source context."
      return
    end

    result = copy_target_records_to_current!(source_records, current_semester)

    if result[:changed].positive?
      submitted_students = submitted_students_count_for_context(
        semester_id: current_semester.id,
        track: @selected_track,
        class_of: @selected_class_of
      )

      if submitted_students.positive?
        session[:target_levels_post_save_warning] = "Target levels changed. #{submitted_students} student(s) have already submitted surveys for #{@selected_track} (#{current_semester.name}); reports may reflect the updated targets."
        notify_admins_target_levels_changed_after_submissions!(
          semester_label: current_semester.name,
          submitted_students: submitted_students,
          semester_id: current_semester.id,
          track: @selected_track,
          class_of: @selected_class_of
        )
      end
    end

    redirect_to admin_program_setup_path(
      tab: "targets",
      program_semester_id: current_semester.id,
      track: @selected_track,
      class_of: @selected_class_of
    ), notice: "Copied #{result[:changed]} target #{'level'.pluralize(result[:changed])} to #{current_semester.name}. #{result[:unchanged]} already matched."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to selected_context_path, alert: e.record.errors.full_messages.to_sentence
  end

  private

  def load_selector_options
    @semesters = ProgramSemester.ordered
    @tracks = Student.tracks.values
    @class_of_options = [ [ "Select a cohort", "" ] ] + ProgramYear.options_for_select.map { |label, value| [ label, value.to_s ] }

    requested_semester_id = params[:program_semester_id].to_s.presence
    @selected_semester_id = requested_semester_id&.to_i
    @selected_track = params[:track].to_s.presence

    year = params[:class_of].to_s.strip
    @selected_class_of = year.present? ? year.to_i : nil
  end

  def load_targets
    unless @selected_semester_id.present? && @selected_track.present? && @selected_class_of.present?
      @competencies = []
      @targets_by_title = {}
      return
    end

    @competencies = Reports::DataAggregator::COMPETENCY_TITLES

    scoped = CompetencyTargetLevel.where(
      program_semester_id: @selected_semester_id,
      track: @selected_track,
      competency_title: @competencies
    )

    exact = scoped.where(class_of: @selected_class_of).index_by(&:competency_title)
    legacy = legacy_target_records(scoped, @selected_class_of).index_by(&:competency_title)
    fallback = {}

    @targets_by_title = @competencies.index_with do |title|
      (exact[title] || legacy[title] || fallback[title])&.target_level
    end
  end

  def submitted_students_count_for_selected_context
    submitted_students_count_for_context(
      semester_id: @selected_semester_id,
      track: @selected_track,
      class_of: @selected_class_of
    )
  end

  def submitted_students_count_for_context(semester_id:, track:, class_of:)
    return 0 unless semester_id.present? && track.present?

    submitted_scope = SurveyAssignment
      .joins(:student)
      .joins(survey: :track_assignments)
      .where(surveys: { program_semester_id: semester_id })
      .where(survey_track_assignments: { track: track })
      .where(students: { track: track })
      .where.not(completed_at: nil)

    if class_of.present?
      submitted_scope = submitted_scope.where(students: { program_year: class_of })
    end

    submitted_scope.select(:student_id).distinct.count
  end

  def notify_admins_target_levels_changed_after_submissions!(semester_label:, submitted_students:, semester_id: @selected_semester_id, track: @selected_track, class_of: @selected_class_of)
    message = "Program target levels changed for #{track}, Class of #{class_of}, #{semester_label} after #{submitted_students} student(s) had already submitted surveys."

    User.admins.find_each do |admin_user|
      notification = Notification.deliver!(
        user: admin_user,
        title: "Target Levels Changed After Submissions",
        message: message,
        notifiable: ProgramSemester.find_by(id: semester_id)
      )
      NotificationEmailDeliveryJob.perform_later(notification_id: notification.id)
    end
  end

  def copy_source_target_records
    competency_titles = Reports::DataAggregator::COMPETENCY_TITLES
    scoped = CompetencyTargetLevel.where(
      program_semester_id: @selected_semester_id,
      track: @selected_track,
      competency_title: competency_titles
    )

    exact = scoped.where(class_of: @selected_class_of).index_by(&:competency_title)
    legacy = legacy_target_records(scoped, @selected_class_of).index_by(&:competency_title)

    competency_titles.filter_map do |title|
      record = exact[title] || legacy[title]
      record if record&.target_level.present?
    end
  end

  def copy_target_records_to_current!(source_records, current_semester)
    result = { changed: 0, unchanged: 0 }

    ActiveRecord::Base.transaction do
      source_records.each do |source|
        target = CompetencyTargetLevel.find_or_initialize_by(
          program_semester_id: current_semester.id,
          track: @selected_track,
          class_of: @selected_class_of,
          competency_title: source.competency_title
        )

        if target.persisted? && target.target_level.to_i == source.target_level.to_i
          result[:unchanged] += 1
          next
        end

        target.target_level = source.target_level
        target.program_year = nil if target.respond_to?(:program_year)
        target.save!
        result[:changed] += 1
      end
    end

    result
  end

  def selected_context_path
    admin_program_setup_path(
      tab: "targets",
      program_semester_id: @selected_semester_id,
      track: @selected_track,
      class_of: @selected_class_of
    )
  end

  def legacy_program_year_candidates(class_of)
    year = class_of.to_i
    candidates = [ year ]
    candidates << 2 if year == 2026
    candidates << 1 if year == 2027
    candidates.uniq
  end

  def legacy_program_year_order_sql(class_of)
    year = class_of.to_i
    mapped_year = { 2026 => 2, 2027 => 1 }[year]
    return "program_year = #{year} DESC" if mapped_year.blank?

    "CASE program_year WHEN #{year} THEN 0 WHEN #{mapped_year} THEN 1 ELSE 2 END"
  end

  def legacy_class_of_candidates(class_of)
    year = class_of.to_i
    candidates = []
    candidates << 2 if year == 2026
    candidates << 1 if year == 2027
    candidates
  end

  def legacy_target_records(scoped, class_of)
    program_year_records = scoped
      .where(class_of: nil, program_year: legacy_program_year_candidates(class_of))
      .order(Arel.sql(legacy_program_year_order_sql(class_of)))
      .to_a

    old_class_records = scoped
      .where(program_year: nil, class_of: legacy_class_of_candidates(class_of))
      .to_a

    program_year_records + old_class_records
  end
end
