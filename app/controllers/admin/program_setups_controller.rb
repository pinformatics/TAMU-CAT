# Program configuration hub for admins (tracks, majors, years, semesters).
class Admin::ProgramSetupsController < Admin::BaseController
  def show
    @tab = normalize_tab(params[:tab])

    @program_tracks = ProgramTrack.ordered
    @new_program_track = ProgramTrack.new(active: true)

    @majors = Major.order(Arel.sql("LOWER(name) ASC"))
    @new_major = Major.new

    @program_years = ProgramYear.data_source_ready? ? ProgramYear.active.ordered : []
    @new_program_year = ProgramYear.new(active: true)

    @program_semesters = ProgramSemester.ordered
    @current_program_semester = ProgramSemester.current
    @new_program_semester = ProgramSemester.new

    load_target_levels_state if @tab == "targets"
    load_course_targets_state if @tab == "course_targets"
  end

  private

  def normalize_tab(value)
    allowed = %w[tracks majors years semesters targets course_targets]
    tab = value.to_s.strip
    allowed.include?(tab) ? tab : "tracks"
  end

  def load_course_targets_state
    @course_target_semesters = ProgramSemester.ordered
    @selected_course_target_semester_id = params[:course_target_program_semester_id].presence&.to_i || ProgramSemester.current&.id
    @course_target_competencies = Competency.ordered
    @course_targets_ready = CourseCompetencyTarget.data_source_ready?

    unless @course_targets_ready
      @course_competency_targets = []
      @course_target_coverage = course_target_coverage(@course_competency_targets)
      return
    end

    @new_course_competency_target = CourseCompetencyTarget.new

    scope = CourseCompetencyTarget
      .ordered
      .includes(course_offering: [ :program_semester, { course: :department } ], competency: :domain)

    if @selected_course_target_semester_id.present?
      scope = scope.joins(:course_offering)
                   .where(course_offerings: { program_semester_id: @selected_course_target_semester_id })
    end

    @course_competency_targets = scope.to_a
    @course_target_coverage = course_target_coverage(@course_competency_targets)
  end

  def course_target_coverage(targets)
    course_count = targets.map(&:course_offering_id).uniq.size
    competency_count = targets.map(&:competency_id).uniq.size

    {
      target_count: targets.size,
      course_count: course_count,
      competency_count: competency_count
    }
  end

  def load_target_levels_state
    @post_save_warning = session.delete(:target_levels_post_save_warning)
    @semesters = ProgramSemester.ordered
    @tracks = Student.tracks.values
    @class_of_options = [ [ "Select a cohort", "" ] ] + ProgramYear.options_for_select.map { |label, value| [ label, value.to_s ] }

    requested_semester_id = params[:program_semester_id].to_s.presence
    @selected_semester_id = requested_semester_id&.to_i
    @selected_track = params[:track].to_s.presence

    year = params[:class_of].to_s.strip
    @selected_class_of = year.present? ? year.to_i : nil

    load_targets
    @submitted_students_count = submitted_students_count_for_selected_context
  end

  def load_targets
    unless @selected_semester_id.present? && @selected_track.present? && @selected_class_of.present?
      @competencies = []
      @targets_by_title = {}
      @target_coverage_summary = nil
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
    @target_coverage_summary = target_coverage_summary(exact: exact, legacy: legacy, fallback: fallback)
  end

  def target_coverage_summary(exact:, legacy:, fallback:)
    rows = @competencies.map do |title|
      exact_record = exact[title]
      legacy_record = legacy[title]
      fallback_record = fallback[title]
      record = exact_record || legacy_record || fallback_record

      {
        title: title,
        target_level: record&.target_level,
        source: exact_record.present? ? "class" : (legacy_record.present? ? "legacy_program_year" : "missing")
      }
    end

    missing = rows.select { |row| row[:target_level].blank? }
    class_specific = rows.count { |row| row[:source] == "class" }
    legacy_program_year = rows.count { |row| row[:source] == "legacy_program_year" }

    {
      total: rows.size,
      populated: rows.size - missing.size,
      missing_count: missing.size,
      missing_titles: missing.map { |row| row[:title] },
      class_specific_count: class_specific,
      legacy_program_year_count: legacy_program_year
    }
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

  def submitted_students_count_for_selected_context
    return 0 unless @selected_semester_id.present? && @selected_track.present?

    submitted_scope = SurveyAssignment
      .joins(:student)
      .joins(survey: :track_assignments)
      .where(surveys: { program_semester_id: @selected_semester_id })
      .where(survey_track_assignments: { track: @selected_track })
      .where(students: { track: @selected_track })
      .where.not(completed_at: nil)

    if @selected_class_of.present?
      submitted_scope = submitted_scope.where(students: { program_year: @selected_class_of })
    end

    submitted_scope.select(:student_id).distinct.count
  end
end
