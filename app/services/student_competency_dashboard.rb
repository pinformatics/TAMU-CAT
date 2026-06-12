# frozen_string_literal: true

require "csv"
require "set"

class StudentCompetencyDashboard
  COMPETENCY_TITLES = Reports::DataAggregator::COMPETENCY_TITLES
  DOMAIN_NAMES = Reports::DataAggregator::REPORT_DOMAINS
  ALL_SEMESTERS_VALUE = "all"
  COMPETENCY_IDENTITY_MODELS = {
    "grade_competency_evidences" => GradeCompetencyEvidence,
    "grade_competency_ratings" => GradeCompetencyRating,
    "competency_target_levels" => CompetencyTargetLevel
  }.freeze
  SOURCE_OPTIONS = {
    "self" => "Self",
    "course" => "Course",
    "advisor" => "Advisor legacy",
    "target" => "End-of-Program Target"
  }.freeze

  def initialize(student:, params: {})
    @student = student
    @params = params.to_h.with_indifferent_access
  end

  def call
    {
      student: student,
      filters: filters,
      semesters: semester_options,
      all_semesters_value: ALL_SEMESTERS_VALUE,
      source_options: SOURCE_OPTIONS,
      visible_sources: filters[:sources],
      domains: domain_rows,
      domain_averages: domain_averages,
      summary: student_summary,
      change_summary: change_summary,
      radar_chart: radar_chart,
      trend_chart: trend_chart,
      course_released: course_released?,
      show_advisor: advisor_visible?,
      release_label: release_label,
      csv: csv
    }
  end

  private

  attr_reader :student, :params

  def filters
    requested_semester = params[:semester].to_s.strip.presence
    all_semesters = requested_semester == ALL_SEMESTERS_VALUE
    selected_semester = requested_semester if !all_semesters && semester_options.include?(requested_semester)

    @filters ||= {
      semester: all_semesters ? nil : (selected_semester || current_semester_name),
      all_semesters: all_semesters,
      sources: selected_source_keys
    }
  end

  def selected_source_keys
    requested = Array(params[:sources]).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:blank?)
    valid = requested & SOURCE_OPTIONS.keys
    valid.presence || SOURCE_OPTIONS.keys
  end

  def source_selected?(source)
    filters[:sources].include?(source.to_s)
  end

  def current_semester_name
    current_name = ProgramSemester.current&.name
    return current_name if semester_options.include?(current_name)

    semester_options.last
  end

  def semester_options
    @semester_options ||= begin
      available_semesters = chronologically_sorted_semester_names(ProgramSemester.pluck(:name).compact.uniq)
      current_name = ProgramSemester.current&.name
      current_key = semester_sort_key(current_name)
      first_name = first_enrollment_semester_name
      first_key = semester_sort_key(first_name)

      if current_key
        first_key = current_key if first_key.blank? || ((first_key <=> current_key) == 1)
        options = available_semesters.select do |semester_name|
          key = semester_sort_key(semester_name)
          key && (key <=> first_key) >= 0 && (key <=> current_key) <= 0
        end
      else
        options = first_name ? available_semesters.drop_while { |name| name != first_name } : available_semesters
      end

      options.presence || available_semesters
    end
  end

  def first_enrollment_semester_name
    @first_enrollment_semester_name ||= begin
      names = student_enrollment_semester_names
      names << fallback_first_enrollment_semester_name
      names.compact!
      names.min_by { |name| semester_sort_key(name) || [ 9999, 99 ] } || fallback_first_enrollment_semester_name
    end
  end

  def fallback_first_enrollment_semester_name
    first_name = cohort_semester_names.first
    return if first_name.blank?

    ProgramSemester.find_by_name_case_insensitive(first_name)&.name
  end

  def student_enrollment_semester_names
    @student_enrollment_semester_names ||= begin
      names = []

      names.concat(
        SurveyAssignment
          .joins(survey: :program_semester)
          .where(student_id: student.student_id)
          .distinct
          .pluck("program_semesters.name")
      )

      names.concat(
        StudentQuestion
          .joins(question: { category: :survey })
          .joins("INNER JOIN program_semesters ON program_semesters.id = surveys.program_semester_id")
          .where(student_id: student.student_id, questions: { question_text: COMPETENCY_TITLES })
          .distinct
          .pluck("program_semesters.name")
      )

      names.concat(
        Feedback
          .joins(:question, :survey)
          .joins("INNER JOIN program_semesters ON program_semesters.id = surveys.program_semester_id")
          .where(student_id: student.student_id, questions: { question_text: COMPETENCY_TITLES })
          .distinct
          .pluck("program_semesters.name")
      )

      rating_semester_scope = GradeCompetencyRating
          .joins(:grade_import_batch)
          .merge(GradeImportBatch.reportable)
          .joins("INNER JOIN program_semesters ON program_semesters.id = grade_import_batches.program_semester_id")
          .where(student_id: student.student_id)

      names.concat(
        filter_competency_identity(rating_semester_scope, table_name: "grade_competency_ratings")
          .distinct
          .pluck("program_semesters.name")
      )

      ordered_names = ProgramSemester.ordered.where(name: names.compact.uniq).pluck(:name)
      chronologically_sorted_semester_names(ordered_names)
    end
  end

  def chronologically_sorted_semester_names(names)
    names.compact.uniq.sort_by { |name| semester_sort_key(name) || [ 9999, 99, name.to_s ] }
  end

  def semester_sort_key(name)
    match = name.to_s.match(/\A(\w+)\s+(\d{4})\z/)
    return nil unless match

    term = match[1].downcase
    year = match[2].to_i
    term_order = {
      "winter" => 0,
      "spring" => 1,
      "summer" => 2,
      "fall" => 3
    }[term]
    return nil if term_order.nil?

    [ year, term_order ]
  end

  def cohort_semester_names
    return [] if student.program_year.blank?

    start_year = student.program_year.to_i - 1
    [
      "Fall #{start_year}",
      "Spring #{start_year + 1}",
      "Fall #{start_year + 1}",
      "Spring #{start_year + 2}"
    ]
  end

  def selected_program_semester
    return nil if filters[:semester].blank?

    @selected_program_semester ||= ProgramSemester.find_by("LOWER(name) = ?", filters[:semester].to_s.downcase)
  end

  def course_released?
    @course_released ||= begin
      if filters[:semester].blank?
        true
      else
        release = selected_program_semester&.course_grade_release_date
        release.blank? || release.released?
      end
    end
  end

  def release_label
    return "Released course results only" if filters[:semester].blank?
    return "Visible now" if course_released?

    next_release = selected_program_semester&.course_grade_release_date&.release_date
    next_release ? "Available #{I18n.l(next_release.in_time_zone, format: :long)}" : "Not released"
  end

  def domain_rows
    @domain_rows ||= domain_competencies.map do |domain|
      competencies = domain[:competencies].map do |competency|
        build_competency_row(competency[:title])
      end

      {
        id: domain[:name].parameterize(separator: "_"),
        name: domain[:name],
        averages: source_averages_for(competencies),
        competencies: competencies
      }
    end
  end

  def build_competency_row(title)
    target_detail = program_target_details[title] || {}
    self_detail = self_rating_details[title] || {}
    advisor_detail = advisor_rating_details[title] || {}
    course_detail = course_rating_details[title] || {}
    target_value = target_detail[:value]
    course_value = course_released? ? course_detail[:value] : nil
    course_sources = course_released? ? course_sources_by_title[title].to_a : []

    {
      title: title,
      self_rating: self_detail[:value],
      advisor_rating: advisor_detail[:value],
      course_rating: course_value,
      end_program_target: target_value,
      course_sources: course_sources,
      self_updated_at: self_detail[:updated_at],
      advisor_updated_at: advisor_detail[:updated_at],
      course_updated_at: course_detail[:updated_at],
      target_updated_at: target_detail[:updated_at],
      self_status: self_detail[:value].present? ? "present" : "missing",
      advisor_status: advisor_detail[:value].present? ? "present" : "missing",
      course_status: course_status_for(title, course_value, course_sources),
      target_status: target_value.present? ? "present" : "missing",
      self_below_target: below_target?(self_detail[:value], target_value),
      course_below_target: below_target?(course_value, target_value)
    }
  end

  def course_status_for(title, course_value, course_sources)
    return "embargoed" unless course_released?
    return "present" if course_value.present? || course_sources.present?
    return "embargoed" if embargoed_course_titles.include?(title)

    "no_evidence"
  end

  def below_target?(value, target)
    value.present? && target.present? && value.to_f < target.to_f
  end

  def domain_competencies
    rows = Domain.includes(:competencies).ordered.to_a
    if rows.any?
      return rows.map do |domain|
        {
          name: domain.name,
          competencies: domain.competencies.map { |competency| { title: competency.title } }
        }
      end
    end

    DOMAIN_NAMES.map do |domain_name|
      titles = COMPETENCY_TITLES.select { |title| fallback_domain_lookup[title] == domain_name }
      { name: domain_name, competencies: titles.map { |title| { title: title } } }
    end
  end

  def self_rating_scope
    StudentQuestion
      .joins(question: { category: { survey: :program_semester } })
      .where(student_id: student.student_id, questions: { question_text: COMPETENCY_TITLES })
  end

  def self_ratings
    @self_ratings ||= self_rating_details.transform_values { |detail| detail[:value] }
  end

  def self_rating_details
    @self_rating_details ||= begin
      lookup = latest_rating_detail_lookup(
        filtered_by_semester(self_rating_scope)
        .select("questions.question_text, student_questions.response_value, student_questions.updated_at, student_questions.id")
        .order("questions.question_text ASC, student_questions.updated_at DESC, student_questions.id DESC"),
        value_method: :response_value
      )

      version_ratings = CompetencySurveyVersionRatings.call(
        student_ids: [ student.student_id ],
        survey_scope: self_rating_version_survey_scope,
        competency_titles: COMPETENCY_TITLES
      ).fetch(student.student_id, {})

      version_ratings.each do |title, value|
        lookup[title] ||= { value: normalize_rating(value), updated_at: nil }
      end

      lookup
    end
  end

  def advisor_ratings
    @advisor_ratings ||= advisor_rating_details.transform_values { |detail| detail[:value] }
  end

  def advisor_rating_details
    @advisor_rating_details ||= begin
      lookup = latest_rating_detail_lookup(
        filtered_by_semester(
          Feedback
            .joins(:question, survey: :program_semester)
            .where(student_id: student.student_id, questions: { question_text: COMPETENCY_TITLES })
        )
          .select("questions.question_text, feedback.average_score, feedback.updated_at, feedback.id")
          .order("questions.question_text ASC, feedback.updated_at DESC, feedback.id DESC"),
        value_method: :average_score
      )

      submitted_ratings = CompetencySurveyVersionRatings.call(
        student_ids: [ student.student_id ],
        survey_scope: submitted_advisor_feedback_survey_scope,
        competency_titles: COMPETENCY_TITLES
      ).fetch(student.student_id, {})

      submitted_ratings.each do |title, value|
        lookup[title] ||= { value: normalize_rating(value), updated_at: nil }
      end

      lookup
    end
  end

  def advisor_visible?
    source_selected?("advisor") && advisor_ratings.values.any? { |value| !value.nil? }
  end

  def course_ratings
    @course_ratings ||= course_rating_details.transform_values { |detail| detail[:value] }
  end

  def course_rating_details
    @course_rating_details ||= begin
      course_rating_details_for_semester(filters[:semester])
    end
  end

  def course_sources_by_title
    @course_sources_by_title ||= begin
      rows = GradeCompetencyEvidence
        .joins(:grade_import_batch)
        .merge(GradeImportBatch.reportable)
        .includes(:competency, :grade_import_file)
        .where(student_id: student.student_id)
        .order(:competency_title, :course_code, :assignment_name, :updated_at)
      rows = filter_competency_identity(rows, table_name: "grade_competency_evidences")
      rows = filter_course_rows_by_semester(rows)

      rows.group_by { |row| canonical_competency_title(row) }.transform_values do |entries|
        entries.map do |entry|
          {
            course_code: entry.course_code.presence || "Unspecified course",
            assignment_name: entry.assignment_name,
            mapped_level: entry.mapped_level,
            course_target_level: entry.course_target_level,
            raw_grade: entry.raw_grade,
            source_file: entry.grade_import_file&.file_name,
            updated_at: entry.updated_at,
            semester: entry.grade_import_batch&.program_semester&.name
          }
        end
      end
    end
  end

  def filter_course_rows_by_semester(scope)
    if filters[:semester].blank?
      return scope.includes(grade_import_batch: { program_semester: :course_grade_release_date }).to_a.select do |row|
        course_row_released?(row)
      end
    end

    return scope.none if selected_program_semester.blank?

    scope.where(grade_import_batches: { program_semester_id: selected_program_semester.id })
  end

  def course_row_released?(row)
    release = row.grade_import_batch&.program_semester&.course_grade_release_date
    release.blank? || release.released?
  end

  def embargoed_course_titles
    @embargoed_course_titles ||= begin
      return Set.new if filters[:semester].present?

      rows = GradeCompetencyEvidence
        .joins(:grade_import_batch)
        .merge(GradeImportBatch.reportable)
        .includes(:competency, grade_import_batch: { program_semester: :course_grade_release_date })
        .where(student_id: student.student_id)
      rows = filter_competency_identity(rows, table_name: "grade_competency_evidences")
        .select(:competency_id, :competency_title, :grade_import_batch_id)
        .to_a

      rows.reject { |row| course_row_released?(row) }.map { |row| canonical_competency_title(row) }.to_set
    end
  end

  def program_target_level_for(title)
    return program_target_lookup[title] if program_target_lookup.key?(title)

    nil
  end

  def program_target_lookup
    @program_target_lookup ||= program_target_details.transform_values { |detail| detail[:value] }
  end

  def program_target_details
    @program_target_details ||= target_detail_lookup_for(target_program_semester)
  end

  def target_program_semester
    selected_program_semester || graduated_target_program_semester || ProgramSemester.current
  end

  def graduated_target_program_semester
    return unless filters[:all_semesters]
    return unless student.respond_to?(:graduated?) && student.graduated?

    @graduated_target_program_semester ||= begin
      target_semester_from_graduation_date || target_semester_from_latest_student_data
    end
  end

  def target_semester_from_graduation_date
    return unless student.respond_to?(:graduated_at)

    graduation_date = student.graduated_at&.to_date
    return if graduation_date.blank?

    ProgramSemester
      .where("starts_on <= ? AND ends_on >= ?", graduation_date, graduation_date)
      .ordered
      .to_a
      .last ||
      ProgramSemester.where("ends_on <= ?", graduation_date).ordered.to_a.last
  end

  def target_semester_from_latest_student_data
    latest_name = student_enrollment_semester_names.max_by { |name| semester_sort_key(name) || [ 0, 0, name.to_s ] }
    ProgramSemester.find_by_name_case_insensitive(latest_name)
  end

  def target_lookup_for(program_semester)
    target_detail_lookup_for(program_semester).transform_values { |detail| detail[:value] }
  end

  def target_detail_lookup_for(program_semester)
    return {} if program_semester.blank? || student.track_key.blank?

    records = CompetencyTargetLevel
      .includes(:competency)
      .where(program_semester_id: program_semester.id)
      .where("LOWER(track) = ?", student.track_key)
    records = filter_competency_identity(records, table_name: "competency_target_levels").to_a

    COMPETENCY_TITLES.index_with do |title|
      matches = records.select { |record| canonical_competency_title(record) == title }
      exact_year = matches.find { |record| record.program_year == student.program_year }
      exact_class = matches.find { |record| record.class_of == student.program_year }
      fallback = matches.find { |record| record.program_year.blank? && record.class_of.blank? }
      target = exact_year || exact_class || fallback || matches.first
      {
        value: target&.target_level,
        updated_at: target&.updated_at
      }
    end
  end

  def latest_rating_detail_lookup(rows, value_method:)
    rows.each_with_object({}) do |row, lookup|
      next if lookup.key?(row.question_text)

      lookup[row.question_text] = {
        value: normalize_rating(row.public_send(value_method)),
        updated_at: row.updated_at
      }
    end
  end

  def filter_competency_identity(scope, table_name:)
    return scope.where(competency_title: COMPETENCY_TITLES) if competency_ids.empty?

    table = competency_identity_table(table_name)
    scope.where(
      table[:competency_id].in(competency_ids)
        .or(table[:competency_title].in(COMPETENCY_TITLES))
    )
  end

  def competency_ids
    @competency_ids ||= Competency.where(title: COMPETENCY_TITLES).pluck(:id)
  end

  def competency_identity_table(table_name)
    COMPETENCY_IDENTITY_MODELS.fetch(table_name).arel_table
  end

  def canonical_competency_title(record)
    record.competency&.title.presence || record.competency_title
  rescue ActiveModel::MissingAttributeError
    record.competency_title
  end

  def filtered_by_semester(scope)
    return scope if filters[:semester].blank?

    scope.where("LOWER(program_semesters.name) = ?", filters[:semester].downcase)
  end

  def self_rating_version_survey_scope
    scope = Survey.joins(:program_semester)
    if filters[:semester].present?
      scope = scope.where("LOWER(program_semesters.name) = ?", filters[:semester].downcase)
    end
    scope
  end

  def submitted_advisor_feedback_survey_scope
    scope = Survey
      .joins(:program_semester, :advisor_feedback_submissions)
      .merge(AdvisorFeedbackSubmission.submitted.where(student_id: student.student_id))

    if filters[:semester].present?
      scope = scope.where("LOWER(program_semesters.name) = ?", filters[:semester].downcase)
    end

    scope.distinct
  end

  def normalize_rating(value)
    return nil if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    value.to_s[/([0-5])(?:\D*)\z/, 1]&.to_f
  end

  def radar_chart
    labels = COMPETENCY_TITLES
    datasets = [
      (source_selected?("self") ? { label: "Self", data: labels.map { |title| self_ratings[title] } } : nil),
      (advisor_visible? ? { label: "Advisor", data: labels.map { |title| advisor_ratings[title] } } : nil),
      (source_selected?("course") ? { label: "Course", data: labels.map { |title| course_released? ? course_ratings[title] : nil } } : nil),
      (source_selected?("target") ? { label: "End Program Target", data: labels.map { |title| program_target_level_for(title) } } : nil)
    ].compact

    {
      labels: labels,
      datasets: datasets
    }
  end

  def trend_chart
    series = {
      "Self average" => source_selected?("self") ? self_trend_by_semester : {},
      "Advisor average" => source_selected?("advisor") ? advisor_trend_by_semester : {},
      "Course average" => source_selected?("course") ? course_trend_by_semester : {},
      "Target average" => source_selected?("target") ? target_trend_by_semester : {}
    }.select { |_label, values| values.present? }

    semester_names = chronologically_sorted_semester_names(series.values.flat_map(&:keys))

    {
      labels: semester_names,
      datasets: series.map do |label, values|
        { label: label, data: semester_names.map { |name| values[name] } }
      end
    }
  end

  def self_trend_by_semester
    @self_trend_by_semester ||= begin
      rows = self_rating_scope
        .select("program_semesters.name AS semester_name, questions.question_text, student_questions.response_value")
        .order("program_semesters.created_at ASC, program_semesters.name ASC")

      average_rows_by_semester(rows, :response_value)
    end
  end

  def advisor_trend_by_semester
    @advisor_trend_by_semester ||= begin
      rows = Feedback
        .joins(:question, survey: :program_semester)
        .where(student_id: student.student_id, questions: { question_text: COMPETENCY_TITLES })
        .select("program_semesters.name AS semester_name, questions.question_text, feedback.average_score")
        .order("program_semesters.created_at ASC, program_semesters.name ASC")

      average_rows_by_semester(rows, :average_score)
    end
  end

  def course_trend_by_semester
    @course_trend_by_semester ||= begin
      rows = GradeCompetencyRating
        .joins(grade_import_batch: :program_semester)
        .merge(GradeImportBatch.reportable)
        .includes(grade_import_batch: { program_semester: :course_grade_release_date })
        .where(student_id: student.student_id)
      rows = filter_competency_identity(rows, table_name: "grade_competency_ratings")
        .select("program_semesters.name AS semester_name, grade_competency_ratings.aggregated_level, grade_competency_ratings.grade_import_batch_id")
        .to_a
        .select { |row| course_row_released?(row) }

      rows.group_by(&:semester_name).transform_values do |entries|
        values = entries.filter_map { |entry| normalize_rating(entry.aggregated_level) }
        CourseCompetencyRule.aggregate(values, rule_key: SiteSetting.course_competency_rule)
      end
    end
  end

  def target_trend_by_semester
    @target_trend_by_semester ||= begin
      ProgramSemester.ordered.each_with_object({}) do |program_semester, lookup|
        targets = target_lookup_for(program_semester).values.compact
        next if targets.empty?

        lookup[program_semester.name] = average(targets)
      end
    end
  end

  def average_rows_by_semester(rows, value_method)
    rows.group_by(&:semester_name).transform_values do |entries|
      average(entries.filter_map { |entry| normalize_rating(entry.public_send(value_method)) })
    end
  end

  def average(values)
    values = values.compact
    return nil if values.empty?

    (values.sum.to_f / values.size).round(2)
  end

  def change_summary
    @change_summary ||= begin
      current_semester = filters[:semester]

      if current_semester.blank?
        {
          current_semester: "All semesters",
          previous_semester: nil,
          headline: "Choose one semester to compare it with the previous semester.",
          source_changes: [],
          competency_changes: []
        }
      elsif (previous_semester = previous_semester_name(current_semester)).blank?
        {
          current_semester: current_semester,
          previous_semester: nil,
          headline: "No earlier semester is available for this comparison yet.",
          source_changes: [],
          competency_changes: []
        }
      else
        source_changes = change_source_summaries(current_semester, previous_semester)
        competency_changes = change_competency_summaries(current_semester, previous_semester)

        headline = if source_changes.blank? && competency_changes.blank?
          "There is not enough overlapping data yet to compare #{current_semester} with #{previous_semester}."
        else
          "Compared with #{previous_semester}, these are the clearest changes in #{current_semester}."
        end

        {
          current_semester: current_semester,
          previous_semester: previous_semester,
          headline: headline,
          source_changes: source_changes,
          competency_changes: competency_changes
        }
      end
    end
  end

  def previous_semester_name(current_semester)
    current_key = semester_sort_key(current_semester)
    return nil if current_key.blank?

    semester_options
      .select { |name| (semester_sort_key(name) <=> current_key) == -1 }
      .max_by { |name| semester_sort_key(name) || [ 0, 0 ] }
  end

  def change_source_summaries(current_semester, previous_semester)
    change_sources.filter_map do |source|
      previous_average = source_average_for_semester(source[:key], previous_semester)
      current_average = source_average_for_semester(source[:key], current_semester)
      next if previous_average.blank? || current_average.blank?

      delta = (current_average.to_f - previous_average.to_f).round(2)
      {
        source: source[:key],
        label: source[:label],
        previous: previous_average,
        current: current_average,
        delta: delta,
        direction: change_direction(delta),
        sentence: change_sentence(source[:label], previous_average, current_average, delta)
      }
    end
  end

  def change_competency_summaries(current_semester, previous_semester)
    change_sources.flat_map do |source|
      previous_details = source_details_for_semester(source[:key], previous_semester)
      current_details = source_details_for_semester(source[:key], current_semester)

      COMPETENCY_TITLES.filter_map do |title|
        previous_value = previous_details.dig(title, :value)
        current_value = current_details.dig(title, :value)
        next if previous_value.blank? || current_value.blank?

        delta = (current_value.to_f - previous_value.to_f).round(2)
        next if delta.zero?

        {
          source: source[:key],
          label: source[:label],
          title: title,
          previous: previous_value,
          current: current_value,
          delta: delta,
          direction: change_direction(delta)
        }
      end
    end
      .sort_by { |row| [ -row[:delta].abs, row[:title].to_s ] }
      .first(3)
  end

  def change_sources
    SOURCE_OPTIONS.keys.filter_map do |source_key|
      next if source_key == "target"
      next unless source_selected?(source_key)
      next if source_key == "advisor" && advisor_ratings.values.all?(&:nil?)

      {
        key: source_key,
        label: {
          "self" => "Self-assessment",
          "course" => "Course-derived",
          "advisor" => "Advisor legacy"
        }.fetch(source_key)
      }
    end
  end

  def source_average_for_semester(source, semester_name)
    values = source_details_for_semester(source, semester_name).values.filter_map { |detail| detail[:value] }
    average(values)
  end

  def source_details_for_semester(source, semester_name)
    case source
    when "self"
      self_rating_details_for_semester(semester_name)
    when "course"
      course_rating_details_for_semester(semester_name)
    when "advisor"
      advisor_rating_details_for_semester(semester_name)
    else
      {}
    end
  end

  def self_rating_details_for_semester(semester_name)
    lookup = latest_rating_detail_lookup(
      self_rating_scope
        .where("LOWER(program_semesters.name) = ?", semester_name.to_s.downcase)
        .select("questions.question_text, student_questions.response_value, student_questions.updated_at, student_questions.id")
        .order("questions.question_text ASC, student_questions.updated_at DESC, student_questions.id DESC"),
      value_method: :response_value
    )

    version_ratings = CompetencySurveyVersionRatings.call(
      student_ids: [ student.student_id ],
      survey_scope: Survey.joins(:program_semester).where("LOWER(program_semesters.name) = ?", semester_name.to_s.downcase),
      competency_titles: COMPETENCY_TITLES
    ).fetch(student.student_id, {})

    version_ratings.each do |title, value|
      lookup[title] ||= { value: normalize_rating(value), updated_at: nil }
    end

    lookup
  end

  def advisor_rating_details_for_semester(semester_name)
    lookup = latest_rating_detail_lookup(
      Feedback
        .joins(:question, survey: :program_semester)
        .where(student_id: student.student_id, questions: { question_text: COMPETENCY_TITLES })
        .where("LOWER(program_semesters.name) = ?", semester_name.to_s.downcase)
        .select("questions.question_text, feedback.average_score, feedback.updated_at, feedback.id")
        .order("questions.question_text ASC, feedback.updated_at DESC, feedback.id DESC"),
      value_method: :average_score
    )

    submitted_ratings = CompetencySurveyVersionRatings.call(
      student_ids: [ student.student_id ],
      survey_scope: Survey
        .joins(:program_semester, :advisor_feedback_submissions)
        .merge(AdvisorFeedbackSubmission.submitted.where(student_id: student.student_id))
        .where("LOWER(program_semesters.name) = ?", semester_name.to_s.downcase)
        .distinct,
      competency_titles: COMPETENCY_TITLES
    ).fetch(student.student_id, {})

    submitted_ratings.each do |title, value|
      lookup[title] ||= { value: normalize_rating(value), updated_at: nil }
    end

    lookup
  end

  def course_rating_details_for_semester(semester_name)
    rating_rows = GradeCompetencyRating
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .includes(:competency)
      .where(student_id: student.student_id)
    rating_rows = filter_competency_identity(rating_rows, table_name: "grade_competency_ratings")
      .select(:competency_id, :competency_title, :aggregated_level, :updated_at, :grade_import_batch_id)
    rating_rows = released_course_rows_for_semester(rating_rows, semester_name)

    rating_entries = rating_rows.map do |row|
      {
        batch_id: row.grade_import_batch_id,
        title: canonical_competency_title(row),
        value: row.aggregated_level&.to_f,
        updated_at: row.updated_at
      }
    end
    rated_keys = rating_entries.map { |entry| [ entry[:batch_id], entry[:title] ] }.to_set

    evidence_rows = GradeCompetencyEvidence
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .includes(:competency)
      .where(student_id: student.student_id)
    evidence_rows = filter_competency_identity(evidence_rows, table_name: "grade_competency_evidences")
      .select(:competency_id, :competency_title, :mapped_level, :updated_at, :grade_import_batch_id)
    evidence_rows = released_course_rows_for_semester(evidence_rows, semester_name)

    fallback_entries = evidence_rows
      .group_by { |row| [ row.grade_import_batch_id, canonical_competency_title(row) ] }
      .filter_map do |(batch_id, title), rows|
        next if rated_keys.include?([ batch_id, title ])

        value = rows.filter_map { |row| row.mapped_level&.to_f }.max
        next if value.blank?

        {
          batch_id: batch_id,
          title: title,
          value: value,
          updated_at: rows.filter_map(&:updated_at).max
        }
      end

    (rating_entries + fallback_entries).group_by { |entry| entry[:title] }.transform_values do |entries|
      values = entries.filter_map { |entry| entry[:value] }
      {
        value: CourseCompetencyRule.aggregate(values, rule_key: SiteSetting.course_competency_rule),
        updated_at: entries.filter_map { |entry| entry[:updated_at] }.max
      }
    end
  end

  def released_course_rows_for_semester(scope, semester_name)
    if semester_name.present?
      semester = ProgramSemester.find_by_name_case_insensitive(semester_name)
      return [] if semester.blank?

      return scope
        .where(grade_import_batches: { program_semester_id: semester.id })
        .includes(grade_import_batch: { program_semester: :course_grade_release_date })
        .to_a
        .select { |row| course_row_released?(row) }
    end

    filter_course_rows_by_semester(scope)
  end

  def change_direction(delta)
    return "increased" if delta.positive?
    return "decreased" if delta.negative?

    "stayed about the same"
  end

  def change_sentence(label, previous_average, current_average, delta)
    direction = change_direction(delta)
    return "#{label} average stayed about the same at #{format_change_score(current_average)}." if delta.zero?

    "#{label} average #{direction} from #{format_change_score(previous_average)} to #{format_change_score(current_average)}."
  end

  def format_change_score(value)
    return nil if value.blank?

    value.to_f.round(2).to_s.sub(/\.0+\z/, "").sub(/(\.\d*[1-9])0+\z/, "\\1")
  end

  def source_averages_for(competencies)
    {
      self: source_selected?("self") ? average(competencies.map { |competency| competency[:self_rating] }) : nil,
      advisor: advisor_visible? ? average(competencies.map { |competency| competency[:advisor_rating] }) : nil,
      course: source_selected?("course") ? average(competencies.map { |competency| competency[:course_rating] }) : nil,
      target: source_selected?("target") ? average(competencies.map { |competency| competency[:end_program_target] }) : nil
    }
  end

  def domain_averages
    @domain_averages ||= domain_rows.each_with_object({}) do |domain, lookup|
      lookup[domain[:name]] = domain[:averages]
    end
  end

  def student_summary
    @student_summary ||= begin
      ranked_domains = domain_rows.filter_map do |domain|
        score = average([
          (domain[:averages][:course] if source_selected?("course")),
          (domain[:averages][:self] if source_selected?("self"))
        ])
        next if score.blank?

        { name: domain[:name], score: score }
      end

      growth_rows = domain_rows.flat_map { |domain| domain[:competencies] }.filter_map do |competency|
        target = competency[:end_program_target]
        next if target.blank?

        observed = [
          (competency[:course_rating] if source_selected?("course")),
          (competency[:self_rating] if source_selected?("self"))
        ].compact.max
        next if observed.blank? || observed.to_f >= target.to_f

        {
          title: competency[:title],
          current: observed,
          target: target,
          gap: (target.to_f - observed.to_f).round(2)
        }
      end

      {
        strongest_domains: ranked_domains.sort_by { |row| -row[:score].to_f }.first(2),
        lowest_domains: ranked_domains.sort_by { |row| row[:score].to_f }.first(2),
        growth_areas: growth_rows.sort_by { |row| -row[:gap].to_f }.first(3),
        missing_self_count: count_competencies_with_status(:self_status, "missing"),
        no_course_evidence_count: count_competencies_with_status(:course_status, "no_evidence"),
        embargoed_course_count: count_competencies_with_status(:course_status, "embargoed"),
        below_target_count: domain_rows.flat_map { |domain| domain[:competencies] }.count do |competency|
          competency[:self_below_target] || competency[:course_below_target]
        end
      }
    end
  end

  def count_competencies_with_status(status_key, status)
    domain_rows.flat_map { |domain| domain[:competencies] }.count { |competency| competency[status_key] == status }
  end

  def csv
    CSV.generate(headers: true) do |csv|
      headers = [
        "Semester",
        "Domain",
        "Competency",
        "Domain Self Average",
        "Domain Advisor Average",
        "Domain Course Average",
        "Domain Target Average"
      ]

      headers += [ "Self Rating", "Self Status", "Self Last Updated", "Self Below Target" ] if source_selected?("self")
      headers += [ "Advisor Rating", "Advisor Status", "Advisor Last Updated" ] if advisor_visible?
      headers += [ "Course Rating", "Course Status", "Course Last Updated", "Course Below Target", "Source Course", "Source Semester", "Source Competency Level", "Source Target Level" ] if source_selected?("course")
      headers += [ "End of Program Target", "Target Status", "Target Last Updated" ] if source_selected?("target")

      csv << headers

      domain_rows.each do |domain|
        domain[:competencies].each do |competency|
          source_rows = source_selected?("course") ? (competency[:course_sources].presence || [ nil ]) : [ nil ]
          source_rows.each do |source|
            row = [
              selected_semester_label,
              domain[:name],
              competency[:title],
              domain[:averages][:self],
              domain[:averages][:advisor],
              domain[:averages][:course],
              domain[:averages][:target]
            ]

            if source_selected?("self")
              row += [
                competency[:self_rating],
                competency[:self_status],
                competency[:self_updated_at],
                competency[:self_below_target]
              ]
            end

            if advisor_visible?
              row += [
                competency[:advisor_rating],
                competency[:advisor_status],
                competency[:advisor_updated_at]
              ]
            end

            if source_selected?("course")
              row += [
                competency[:course_rating],
                competency[:course_status],
                competency[:course_updated_at],
                competency[:course_below_target],
                source&.dig(:course_code),
                source&.dig(:semester),
                source&.dig(:mapped_level),
                source&.dig(:course_target_level)
              ]
            end

            if source_selected?("target")
              row += [
                competency[:end_program_target],
                competency[:target_status],
                competency[:target_updated_at]
              ]
            end

            csv << row
          end
        end
      end
    end
  end

  def selected_semester_label
    filters[:semester].presence || "All semesters"
  end

  def fallback_domain_lookup
    @fallback_domain_lookup ||= begin
      {
        "Public and Population Health Assessment" => "Health Care Environment and Community",
        "Delivery, Organization, and Financing of Health Services and Health Systems" => "Health Care Environment and Community",
        "Policy Analysis" => "Health Care Environment and Community",
        "Legal & Ethical Bases for Health Services and Health Systems" => "Health Care Environment and Community",
        "Ethics, Accountability, and Self-Assessment" => "Leadership Skills",
        "Organizational Dynamics" => "Leadership Skills",
        "Problem Solving, Decision Making, and Critical Thinking" => "Leadership Skills",
        "Team Building and Collaboration" => "Leadership Skills",
        "Strategic Planning" => "Management Skills",
        "Business Planning" => "Management Skills",
        "Communication" => "Management Skills",
        "Financial Management" => "Management Skills",
        "Performance Improvement" => "Management Skills",
        "Project Management" => "Management Skills",
        "Systems Thinking" => "Analytic and Technical Skills",
        "Data Analysis and Information Management" => "Analytic and Technical Skills",
        "Quantitative Methods for Health Services Delivery" => "Analytic and Technical Skills"
      }
    end
  end
end
