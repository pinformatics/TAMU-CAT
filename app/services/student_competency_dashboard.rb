# frozen_string_literal: true

require "csv"

class StudentCompetencyDashboard
  COMPETENCY_TITLES = Reports::DataAggregator::COMPETENCY_TITLES
  DOMAIN_NAMES = Reports::DataAggregator::REPORT_DOMAINS

  def initialize(student:, params: {})
    @student = student
    @params = params.to_h.with_indifferent_access
  end

  def call
    {
      student: student,
      filters: filters,
      semesters: semester_options,
      domains: domain_rows,
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
    selected_semester = requested_semester if semester_options.include?(requested_semester)

    @filters ||= {
      semester: selected_semester || current_semester_name
    }
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

      names.concat(
        GradeCompetencyRating
          .joins(:grade_import_batch)
          .merge(GradeImportBatch.reportable)
          .joins("INNER JOIN program_semesters ON program_semesters.id = grade_import_batches.program_semester_id")
          .where(student_id: student.student_id, competency_title: COMPETENCY_TITLES)
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
    @selected_program_semester ||= ProgramSemester.find_by("LOWER(name) = ?", filters[:semester].to_s.downcase)
  end

  def course_released?
    @course_released ||= begin
      release = selected_program_semester&.course_grade_release_date
      release.blank? || release.released?
    end
  end

  def release_label
    return "Visible now" if course_released?

    next_release = selected_program_semester&.course_grade_release_date&.release_date
    next_release ? "Available #{I18n.l(next_release.in_time_zone, format: :long)}" : "Not released"
  end

  def domain_rows
    @domain_rows ||= domain_competencies.map do |domain|
      {
        id: domain[:name].parameterize(separator: "_"),
        name: domain[:name],
        competencies: domain[:competencies].map do |competency|
          title = competency[:title]
          end_program_target = program_target_level_for(title)
          {
            title: title,
            self_rating: self_ratings[title],
            advisor_rating: advisor_ratings[title],
            course_rating: course_released? ? course_ratings[title] : nil,
            end_program_target: end_program_target,
            course_sources: course_released? ? course_sources_by_title[title].to_a : []
          }
        end
      }
    end
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
    @self_ratings ||= begin
      lookup = latest_rating_lookup(
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
        lookup[title] ||= value
      end

      lookup
    end
  end

  def advisor_ratings
    @advisor_ratings ||= begin
      lookup = latest_rating_lookup(
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
        lookup[title] ||= value
      end

      lookup
    end
  end

  def advisor_visible?
    advisor_ratings.values.any? { |value| !value.nil? }
  end

  def course_ratings
    @course_ratings ||= begin
      rows = GradeCompetencyRating
        .joins(:grade_import_batch)
        .merge(GradeImportBatch.reportable)
        .where(student_id: student.student_id, competency_title: COMPETENCY_TITLES)
        .select(:competency_title, :aggregated_level)
      rows = filter_course_rows_by_semester(rows)

      rows.group_by(&:competency_title).transform_values do |ratings|
        CourseCompetencyRule.aggregate(ratings.filter_map { |rating| rating.aggregated_level&.to_f }, rule_key: SiteSetting.course_competency_rule)
      end
    end
  end

  def course_sources_by_title
    @course_sources_by_title ||= begin
      rows = GradeCompetencyEvidence
        .joins(:grade_import_batch)
        .merge(GradeImportBatch.reportable)
        .includes(:grade_import_file)
        .where(student_id: student.student_id, competency_title: COMPETENCY_TITLES)
        .order(:competency_title, :course_code, :assignment_name, :updated_at)
      rows = filter_course_rows_by_semester(rows)

      rows.group_by(&:competency_title).transform_values do |entries|
        entries.map do |entry|
          {
            course_code: entry.course_code.presence || "Unspecified course",
            assignment_name: entry.assignment_name,
            mapped_level: entry.mapped_level,
            course_target_level: entry.course_target_level,
            raw_grade: entry.raw_grade,
            source_file: entry.grade_import_file&.file_name,
            updated_at: entry.updated_at
          }
        end
      end
    end
  end

  def filter_course_rows_by_semester(scope)
    return scope if selected_program_semester.blank?

    scope.where(grade_import_batches: { program_semester_id: [ selected_program_semester.id, nil ] })
  end

  def program_target_level_for(title)
    return program_target_lookup[title] if program_target_lookup.key?(title)

    nil
  end

  def program_target_lookup
    @program_target_lookup ||= target_lookup_for(selected_program_semester)
  end

  def target_lookup_for(program_semester)
    return {} if program_semester.blank? || student.track_key.blank?

    records = CompetencyTargetLevel
      .where(competency_title: COMPETENCY_TITLES, program_semester_id: program_semester.id)
      .where("LOWER(track) = ?", student.track_key)
      .to_a

    COMPETENCY_TITLES.index_with do |title|
      matches = records.select { |record| record.competency_title == title }
      exact_year = matches.find { |record| record.program_year == student.program_year }
      exact_class = matches.find { |record| record.class_of == student.program_year }
      fallback = matches.find { |record| record.program_year.blank? && record.class_of.blank? }
      (exact_year || exact_class || fallback || matches.first)&.target_level
    end
  end

  def latest_rating_lookup(rows, value_method:)
    rows.each_with_object({}) do |row, lookup|
      next if lookup.key?(row.question_text)

      lookup[row.question_text] = normalize_rating(row.public_send(value_method))
    end
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
      { label: "Self", data: labels.map { |title| self_ratings[title] } },
      (advisor_visible? ? { label: "Advisor", data: labels.map { |title| advisor_ratings[title] } } : nil),
      { label: "Course", data: labels.map { |title| course_released? ? course_ratings[title] : nil } },
      { label: "End Program Target", data: labels.map { |title| program_target_level_for(title) } }
    ].compact

    {
      labels: labels,
      datasets: datasets
    }
  end

  def trend_chart
    rows = self_rating_scope
      .select("program_semesters.name AS semester_name, questions.question_text, student_questions.response_value")
      .order("program_semesters.created_at ASC, program_semesters.name ASC")

    semester_names = rows.map(&:semester_name).compact.uniq
    self_by_semester = rows.group_by(&:semester_name).transform_values do |entries|
      values = entries.filter_map { |entry| normalize_rating(entry.response_value) }
      average(values)
    end

    {
      labels: semester_names,
      datasets: [
        { label: "Self average", data: semester_names.map { |name| self_by_semester[name] } }
      ]
    }
  end

  def average(values)
    values = values.compact
    return nil if values.empty?

    (values.sum.to_f / values.size).round(2)
  end

  def csv
    CSV.generate(headers: true) do |csv|
      csv << [
        "Semester",
        "Domain",
        "Competency",
        "Self Rating",
        "Advisor Rating",
        "Course Rating",
        "End of Program Target",
        "Source Course",
        "Source Competency Level",
        "Source Target Level"
      ]
      domain_rows.each do |domain|
        domain[:competencies].each do |competency|
          source_rows = competency[:course_sources].presence || [ nil ]
          source_rows.each do |source|
            csv << [
              filters[:semester],
              domain[:name],
              competency[:title],
              competency[:self_rating],
              competency[:advisor_rating],
              competency[:course_rating],
              competency[:end_program_target],
              source&.dig(:course_code),
              source&.dig(:mapped_level),
              source&.dig(:course_target_level)
            ]
          end
        end
      end
    end
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
