require "test_helper"

class Admin::CompetencyMatrixTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @competency_name = Reports::DataAggregator::COMPETENCY_TITLES.first
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

  test "course ratings are scoped to the selected import semester" do
    create_course_rating(level: 2.0, semester: program_semesters(:spring_2025))
    create_course_rating(level: 5.0, semester: program_semesters(:fall_2025))

    payload = Admin::CompetencyMatrix.new(params: { semester: "Fall 2025" }, actor_user: @admin).call
    student_row = payload[:students].find { |row| row[:id] == @student.student_id }

    assert_in_delta 5.0, student_row.dig(:ratings, @competency_name, :course_rating), 0.001
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
end
