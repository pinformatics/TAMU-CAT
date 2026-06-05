require "test_helper"
require "securerandom"

class Admin::CompetencyMatrixTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @competency_name = Reports::DataAggregator::COMPETENCY_TITLES.first
    domain = Domain.find_or_create_by!(name: Reports::DataAggregator::REPORT_DOMAINS.first)
    Competency.find_or_create_by!(title: @competency_name) do |competency|
      competency.domain = domain
      competency.position = 0
    end
    SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
  end

  teardown do
    SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
  end

  test "course ratings respect the global course competency rule" do
    create_course_rating(level: 2.0)
    create_course_rating(level: 3.0)

    SiteSetting.set_course_competency_rule!("avg")

    payload = Admin::CompetencyMatrix.new(params: {}, actor_user: @admin).call
    student_row = payload[:students].find { |row| row[:id] == @student.student_id }
    value = student_row.dig(:ratings, @competency_name, :course_rating)

    assert_in_delta 2.5, value, 0.001
    assert_equal "avg", payload[:course_competency_rule]
    assert_equal "Avg", payload[:course_competency_rule_label]
  end

  test "course ratings support every global course competency rule option" do
    [ 3.0, 4.0, 1.0, 2.0, 1.0 ].each { |level| create_course_rating(level: level) }

    {
      "max" => { value: 4.0, label: "Max" },
      "min" => { value: 1.0, label: "Min" },
      "avg" => { value: 2.2, label: "Avg" },
      "ceil_avg" => { value: 3.0, label: "Ceil(avg)" },
      "floor_avg" => { value: 2.0, label: "Floor(avg)" }
    }.each do |rule, expected|
      SiteSetting.set_course_competency_rule!(rule)

      payload = Admin::CompetencyMatrix.new(params: {}, actor_user: @admin).call
      student_row = payload[:students].find { |row| row[:id] == @student.student_id }
      value = student_row.dig(:ratings, @competency_name, :course_rating)

      assert_in_delta expected[:value], value, 0.001
      assert_equal rule, payload[:course_competency_rule]
      assert_equal expected[:label], payload[:course_competency_rule_label]
    end
  end

  test "invalid global rule falls back to max" do
    create_course_rating(level: 2.0)
    create_course_rating(level: 3.0)
    SiteSetting.set("course_competency_rule", "something_else")

    payload = Admin::CompetencyMatrix.new(params: {}, actor_user: @admin).call
    student_row = payload[:students].find { |row| row[:id] == @student.student_id }
    value = student_row.dig(:ratings, @competency_name, :course_rating)

    assert_equal 3.0, value
    assert_equal "max", payload[:course_competency_rule]
  end

  test "course ratings prefer canonical competency id when source title drifts" do
    rating = create_course_rating(level: 4.0)
    rating.update_columns(competency_title: "Imported typo for #{@competency_name}")

    payload = Admin::CompetencyMatrix.new(params: {}, actor_user: @admin).call
    student_row = payload[:students].find { |row| row[:id] == @student.student_id }

    assert_in_delta 4.0, student_row.dig(:ratings, @competency_name, :course_rating), 0.001
  end

  test "course ratings are scoped to the selected import semester" do
    create_course_rating(level: 2.0, semester: program_semesters(:spring_2025))
    create_course_rating(level: 5.0, semester: program_semesters(:fall_2025))

    payload = Admin::CompetencyMatrix.new(params: { semester: "Fall 2025" }, actor_user: @admin).call
    student_row = payload[:students].find { |row| row[:id] == @student.student_id }

    assert_in_delta 5.0, student_row.dig(:ratings, @competency_name, :course_rating), 0.001
  end

  test "advisor legacy ratings do not override course-derived ratings" do
    create_advisor_feedback(score: 1.0, semester: program_semesters(:fall_2025))
    create_course_rating(level: 5.0, semester: program_semesters(:fall_2025))

    payload = Admin::CompetencyMatrix.new(params: { semester: "Fall 2025" }, actor_user: @admin).call
    student_row = payload[:students].find { |row| row[:id] == @student.student_id }
    ratings = student_row[:ratings][@competency_name]

    assert_in_delta 1.0, ratings[:advisor_rating], 0.001
    assert_in_delta 5.0, ratings[:course_rating], 0.001
  end

  test "program targets use the selected semester and student cohort" do
    CompetencyTargetLevel.create!(
      program_semester: program_semesters(:fall_2025),
      track: @student.track,
      class_of: @student.program_year,
      competency_title: @competency_name,
      target_level: 3
    )
    CompetencyTargetLevel.create!(
      program_semester: program_semesters(:spring_2026),
      track: @student.track,
      class_of: @student.program_year,
      competency_title: @competency_name,
      target_level: 5
    )

    spring_payload = Admin::CompetencyMatrix.new(params: { semester: "Spring 2026" }, actor_user: @admin).call
    spring_row = spring_payload[:students].find { |row| row[:id] == @student.student_id }
    default_payload = Admin::CompetencyMatrix.new(params: {}, actor_user: @admin).call
    default_row = default_payload[:students].find { |row| row[:id] == @student.student_id }

    assert_equal 5, spring_row.dig(:ratings, @competency_name, :program_target)
    assert_equal 3, default_row.dig(:ratings, @competency_name, :program_target)
  end

  test "private helpers cover empty scopes blank tracks and rating parsing" do
    matrix = Admin::CompetencyMatrix.new(params: { sources: [ "self" ] }, actor_user: @admin)

    assert_equal({}, matrix.send(:latest_self_ratings, []))
    assert_equal({}, matrix.send(:latest_advisor_ratings, []))
    assert_equal({}, matrix.send(:latest_course_ratings, []))
    assert_equal({}, matrix.send(:target_levels_for, []))

    blank_track_student = Struct.new(:student_id, :track, :program_year) do
      def track_key = nil
      def [](key) = key == :track ? track : nil
    end.new(987_654, nil, nil)

    assert_equal({}, matrix.send(:target_levels_for, [ blank_track_student ]))
    assert_nil matrix.send(:normalize_rating, nil)
    assert_nil matrix.send(:normalize_rating, "not rated")
    assert_equal 4.0, matrix.send(:normalize_rating, "Level 4")

    fallback_track_student = Struct.new(:track) do
      def [](key) = key == :track ? "executive" : nil
    end.new("")
    assert_equal "Executive", matrix.send(:track_label_for, fallback_track_student)
  end

  test "student row falls back when optional associations are absent" do
    row_student = Struct.new(:student_id, :user, :uin, :track, :program_year, :advisor) do
      def [](key) = key == :track ? track : nil
      def track_key = nil
      def lifecycle_label = "Current"
      def current_record? = true
    end.new(111_222, nil, "000111222", nil, 2026, nil)

    matrix = Admin::CompetencyMatrix.new(params: { competencies: [ @competency_name ] }, actor_user: @admin)
    row = matrix.send(
      :build_student_row,
      row_student,
      self_ratings: {},
      advisor_ratings: {},
      course_ratings: {},
      target_levels: {}
    )

    assert_equal "111222", row[:name]
    assert_nil row[:email]
    assert_nil row[:advisor_name]
    assert_equal "000111222", row[:uin]
    assert_equal [ @competency_name ], row[:ratings].keys
  end

  test "advisor actor scope and normalized filters cover alternate branches" do
    advisor_user = users(:advisor)
    matrix = Admin::CompetencyMatrix.new(
      params: {
        q: "  student  ",
        track: "Residential",
        program_year: "2026",
        advisor_id: advisors(:advisor).advisor_id.to_s,
        semester: "Fall 2025",
        domain: Reports::DataAggregator::REPORT_DOMAINS.first,
        student_status: "graduated",
        competencies: [ @competency_name, "", "Not real" ]
      },
      actor_user: advisor_user
    )

    filters = matrix.send(:normalized_filters)

    assert_equal "student", filters[:q]
    assert_equal "residential", filters[:track]
    assert_equal 2026, filters[:program_year]
    assert_equal advisors(:advisor).advisor_id, filters[:advisor_id]
    assert_equal "Fall 2025", filters[:semester]
    assert_equal Reports::DataAggregator::REPORT_DOMAINS.first, filters[:domain]
    assert_equal [ @competency_name ], filters[:competencies]
    assert matrix.send(:base_student_scope).where(advisor_id: advisor_user.id).exists? || matrix.send(:base_student_scope).empty?
    assert_equal "public_and_population_health_assessment", matrix.send(:competency_slug, @competency_name)
  end

  private

  def create_course_rating(level:, semester: nil)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => false }
    )

    GradeCompetencyRating.create!(
      grade_import_batch: batch,
      student: @student,
      competency_title: @competency_name,
      aggregated_level: level,
      aggregation_rule: "max",
      evidence_count: 1
    )
  end

  def create_advisor_feedback(score:, semester:)
    survey = Survey.new(
      title: "Advisor Legacy Matrix Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      is_active: true
    )
    survey.save!(validate: false)
    section = SurveySection.create!(survey: survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = Category.create!(survey: survey, section: section, name: "Health Care Environment and Community")
    question = category.questions.create!(
      question_text: @competency_name,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5],
      has_feedback: true
    )

    Feedback.create!(
      student: @student,
      advisor: advisors(:advisor),
      survey: survey,
      category: category,
      question: question,
      average_score: score
    )
  end
end
