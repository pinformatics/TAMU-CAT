# frozen_string_literal: true

class Admin::CompetencyMatrix
  COMPETENCY_TITLES = Reports::DataAggregator::COMPETENCY_TITLES
  DOMAIN_NAMES = Reports::DataAggregator::REPORT_DOMAINS

  def initialize(params: {}, actor_user: nil)
    @params = params.to_h.with_indifferent_access
    @actor_user = actor_user
  end

  def call
    students = filtered_students.to_a
    student_ids = students.map(&:student_id)
    visible_titles = visible_competency_titles
    self_ratings = latest_self_ratings(student_ids)
    advisor_ratings = latest_advisor_ratings(student_ids)
    course_ratings = latest_course_ratings(student_ids)
    target_levels = target_levels_for(students)

    {
      filters: normalized_filters,
      filter_options: filter_options,
      domains: domains,
      visible_competency_count: visible_titles.size,
      course_competency_rule: active_course_competency_rule,
      course_competency_rule_label: CourseCompetencyRule.label_for(active_course_competency_rule),
      course_competency_rule_options: CourseCompetencyRule.options,
      students: students.map do |student|
        build_student_row(student, self_ratings:, advisor_ratings:, course_ratings:, target_levels:)
      end
    }
  end

  private

  attr_reader :params, :actor_user

  def build_student_row(student, self_ratings:, advisor_ratings:, course_ratings:, target_levels:)
    {
      id: student.student_id,
      name: student.user&.display_name || student.student_id.to_s,
      email: student.user&.email,
      uin: student.uin,
      track: track_label_for(student),
      program_year: student.program_year,
      advisor_name: student.advisor&.display_name,
      lifecycle_label: student.lifecycle_label,
      current_record: student.current_record?,
      ratings: visible_competency_titles.index_with do |title|
        {
          self_rating: self_ratings.dig(student.student_id, title),
          advisor_rating: advisor_ratings.dig(student.student_id, title),
          course_rating: course_ratings.dig(student.student_id, title),
          program_target: target_levels.dig(student.student_id, title)
        }
      end
    }
  end

  def domains
    domain_lookup = competency_domain_lookup

    DOMAIN_NAMES.filter_map do |domain_name|
      competencies = visible_competency_titles.filter_map do |title|
        next unless domain_lookup[title] == domain_name

        { id: competency_slug(title), title: title }
      end

      next if competencies.empty?

      {
        id: competency_slug(domain_name),
        name: domain_name,
        competencies: competencies
      }
    end
  end

  def normalized_filters
    @normalized_filters ||= {
      q: params[:q].to_s.strip,
      track: canonical_track_filter,
      program_year: normalized_program_year,
      advisor_id: normalized_advisor_id,
      semester: normalized_semester,
      domain: normalized_domain,
      student_status: normalized_student_status,
      competencies: normalized_competencies
    }
  end

  def filter_options
    @filter_options ||= {
      tracks: track_options,
      program_years: program_year_options,
      advisors: advisor_options,
      semesters: semester_options,
      domains: domain_options,
      student_statuses: Student.lifecycle_filter_options,
      competencies: competency_options
    }
  end

  def filtered_students
    scope = lifecycle_student_scope.includes(:user, advisor: :user).left_outer_joins(:user)

    if normalized_filters[:q].present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(normalized_filters[:q])}%"
      scope = scope.where(
        "users.name ILIKE :term OR users.email ILIKE :term OR CAST(students.student_id AS TEXT) ILIKE :term OR students.uin ILIKE :term",
        term: term
      )
    end

    if normalized_filters[:track].present?
      scope = scope.where("LOWER(track) = ?", normalized_filters[:track])
    end

    if normalized_filters[:program_year].present?
      scope = scope.where(program_year: normalized_filters[:program_year])
    end

    if normalized_filters[:advisor_id].present?
      scope = scope.where(advisor_id: normalized_filters[:advisor_id])
    end

    scope.order(Arel.sql("LOWER(COALESCE(users.name, users.email, '')) ASC"), :student_id)
  end

  def latest_self_ratings(student_ids)
    return {} if student_ids.empty?

    rows = StudentQuestion
      .joins(question: { category: { survey: :program_semester } })
      .where(student_id: student_ids, questions: { question_text: visible_competency_titles })
      .select("student_questions.student_id, questions.question_text, student_questions.response_value, student_questions.updated_at, student_questions.id")
      .order("student_questions.student_id ASC, questions.question_text ASC, student_questions.updated_at DESC, student_questions.id DESC")

    if normalized_filters[:semester].present?
      rows = rows.where("LOWER(program_semesters.name) = ?", normalized_filters[:semester].downcase)
    end

    lookup = rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |row, memo|
      next if memo[row.student_id].key?(row.question_text)

      memo[row.student_id][row.question_text] = normalize_rating(row.response_value)
    end

    version_ratings = CompetencySurveyVersionRatings.call(
      student_ids: student_ids,
      survey_scope: self_rating_version_survey_scope,
      competency_titles: visible_competency_titles
    )

    version_ratings.each do |student_id, ratings|
      ratings.each do |title, value|
        lookup[student_id][title] ||= value
      end
    end

    lookup
  end

  def latest_advisor_ratings(student_ids)
    return {} if student_ids.empty?

    rows = Feedback
      .joins(:question, survey: :program_semester)
      .where(student_id: student_ids, questions: { question_text: visible_competency_titles })
      .select("feedback.student_id, questions.question_text, feedback.average_score, feedback.updated_at, feedback.id")
      .order("feedback.student_id ASC, questions.question_text ASC, feedback.updated_at DESC, feedback.id DESC")

    if normalized_filters[:semester].present?
      rows = rows.where("LOWER(program_semesters.name) = ?", normalized_filters[:semester].downcase)
    end

    lookup = rows.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |row, lookup|
      next if lookup[row.student_id].key?(row.question_text)

      lookup[row.student_id][row.question_text] = normalize_rating(row.average_score)
    end

    submitted_ratings = CompetencySurveyVersionRatings.call(
      student_ids: student_ids,
      survey_scope: submitted_advisor_feedback_survey_scope,
      competency_titles: visible_competency_titles
    )

    submitted_ratings.each do |student_id, ratings|
      ratings.each do |title, value|
        lookup[student_id][title] ||= value
      end
    end

    lookup
  end

  def latest_course_ratings(student_ids)
    return {} if student_ids.empty?

    rows = GradeCompetencyRating
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .includes(:competency)
      .where(student_id: student_ids)
    rows = filter_competency_identity(rows, table_name: "grade_competency_ratings")
    rows = rows.select("grade_competency_ratings.student_id, grade_competency_ratings.competency_id, grade_competency_ratings.competency_title, grade_competency_ratings.aggregated_level")

    if normalized_filters[:semester].present?
      semester = ProgramSemester.find_by_name_case_insensitive(normalized_filters[:semester])
      rows = semester ? rows.where(grade_import_batches: { program_semester_id: semester.id }) : rows.none
    end

    grouped = rows.to_a.group_by { |row| [ row.student_id, canonical_competency_title(row) ] }

    grouped.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |((student_id, competency_title), entries), lookup|
      levels = entries.filter_map { |entry| entry.aggregated_level&.to_f }
      lookup[student_id][competency_title] = CourseCompetencyRule.aggregate(levels, rule_key: active_course_competency_rule)
    end
  end

  def active_course_competency_rule
    @active_course_competency_rule ||= SiteSetting.course_competency_rule
  end

  def self_rating_version_survey_scope
    scope = Survey.joins(:program_semester)
    if normalized_filters[:semester].present?
      scope = scope.where("LOWER(program_semesters.name) = ?", normalized_filters[:semester].downcase)
    end
    scope
  end

  def submitted_advisor_feedback_survey_scope
    scope = Survey
      .joins(:program_semester, :advisor_feedback_submissions)
      .merge(AdvisorFeedbackSubmission.submitted)

    if normalized_filters[:semester].present?
      scope = scope.where("LOWER(program_semesters.name) = ?", normalized_filters[:semester].downcase)
    end

    scope.distinct
  end

  def target_levels_for(students)
    semester = selected_program_semester
    return {} if students.empty? || semester.blank?

    tracks = students.map { |student| track_label_for(student) }.compact.uniq
    records = CompetencyTargetLevel
      .includes(:competency)
      .where(program_semester_id: semester.id)
      .where(track: tracks)
    records = filter_competency_identity(records, table_name: "competency_target_levels").to_a

    students.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |student, lookup|
      student_track = track_label_for(student)
      next if student_track.blank?

      visible_competency_titles.each do |title|
        matches = records.select { |record| record.track == student_track && canonical_competency_title(record) == title }
        exact_year = matches.find { |record| record.program_year == student.program_year }
        exact_class = matches.find { |record| record.class_of == student.program_year }
        fallback = matches.find { |record| record.program_year.blank? && record.class_of.blank? }
        lookup[student.student_id][title] = (exact_year || exact_class || fallback || matches.first)&.target_level
      end
    end
  end

  def selected_program_semester
    @selected_program_semester ||= begin
      if normalized_filters[:semester].present?
        ProgramSemester.find_by_name_case_insensitive(normalized_filters[:semester])
      else
        ProgramSemester.current
      end
    end
  end

  def normalize_rating(value)
    return nil if value.blank?

    numeric = begin
      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    return numeric if numeric

    match = value.to_s.match(/([0-5])(?:\D*)\z/)
    match ? match[1].to_f : nil
  end

  def competency_domain_lookup
    @competency_domain_lookup ||= begin
      counts = Question
        .joins(:category)
        .where(question_text: COMPETENCY_TITLES)
        .group(:question_text, "categories.name")
        .count

      grouped = Hash.new { |hash, key| hash[key] = [] }
      counts.each do |(title, domain_name), count|
        grouped[title] << [ domain_name, count ]
      end

      COMPETENCY_TITLES.each_with_object({}) do |title, lookup|
        domain_name = grouped[title]
          .select { |entry| DOMAIN_NAMES.include?(entry.first) }
          .max_by(&:last)
          &.first

        lookup[title] = domain_name || fallback_domain_lookup[title]
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

  def track_options
    Student.tracks.values
  end

  def program_year_options
    lifecycle_student_scope.where.not(program_year: nil).distinct.order(:program_year).pluck(:program_year)
  end

  def advisor_options
    advisor_ids = lifecycle_student_scope.where.not(advisor_id: nil).distinct.order(:advisor_id).pluck(:advisor_id)

    Advisor
      .where(advisor_id: advisor_ids)
      .includes(:user)
      .sort_by { |advisor| advisor.display_name.to_s.downcase }
      .map { |advisor| { id: advisor.advisor_id, name: advisor.display_name } }
  end

  def semester_options
    ProgramSemester.ordered.pluck(:name).compact.uniq
  end

  def domain_options
    domains = competency_domain_lookup.values.compact.uniq
    DOMAIN_NAMES.select { |name| domains.include?(name) }
  end

  def competency_options
    DOMAIN_NAMES.flat_map do |domain_name|
      titles = COMPETENCY_TITLES.select { |title| competency_domain_lookup[title] == domain_name }
      next [] if titles.empty?

      titles.map { |title| { title: title, domain: domain_name } }
    end
  end

  def canonical_track_filter
    value = params[:track].to_s.strip
    return nil if value.blank?

    ProgramTrack.canonical_key(value)
  end

  def normalized_program_year
    value = params[:program_year].to_s.strip
    value.present? ? value.to_i : nil
  end

  def normalized_advisor_id
    value = params[:advisor_id].to_s.strip
    value.present? ? value.to_i : nil
  end

  def normalized_semester
    value = params[:semester].to_s.strip
    value.presence
  end

  def normalized_domain
    value = params[:domain].to_s.strip
    value.presence
  end

  def normalized_student_status
    Student.normalize_lifecycle_filter(params[:student_status])
  end

  def normalized_competencies
    Array(params[:competencies])
      .map { |value| value.to_s.strip }
      .reject(&:blank?)
      .select { |title| COMPETENCY_TITLES.include?(title) }
      .uniq
  end

  def track_label_for(student)
    student.track.presence || student[:track].to_s.strip.titleize.presence
  end

  def competency_slug(value)
    value.to_s.parameterize(separator: "_")
  end

  def filter_competency_identity(scope, table_name:)
    return scope.where(competency_title: visible_competency_titles) if visible_competency_ids.empty?

    scope.where(
      "#{table_name}.competency_id IN (:ids) OR #{table_name}.competency_title IN (:titles)",
      ids: visible_competency_ids,
      titles: visible_competency_titles
    )
  end

  def visible_competency_ids
    @visible_competency_ids ||= Competency.where(title: visible_competency_titles).pluck(:id)
  end

  def canonical_competency_title(record)
    record.competency&.title.presence || record.competency_title
  rescue ActiveModel::MissingAttributeError
    record.competency_title
  end

  def base_student_scope
    @base_student_scope ||= begin
      if actor_user&.role_advisor?
        Student.where(advisor_id: actor_user.id)
      else
        Student.all
      end
    end
  end

  def lifecycle_student_scope
    @lifecycle_student_scope ||= base_student_scope.with_lifecycle_filter(normalized_filters[:student_status])
  end

  def visible_competency_titles
    @visible_competency_titles ||= begin
      titles = COMPETENCY_TITLES

      if normalized_filters[:domain].present?
        titles = titles.select { |title| competency_domain_lookup[title] == normalized_filters[:domain] }
      end

      if normalized_filters[:competencies].present?
        titles = titles.select { |title| normalized_filters[:competencies].include?(title) }
      end

      titles
    end
  end
end
