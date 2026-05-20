require "test_helper"

class StudentOverviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = students(:student)
    @other_student = students(:other_student)
  end

  test "admin can see all students and heatmap" do
    create_met_competency_for(@student)
    sign_in @admin

    get student_overviews_path

    assert_response :success
    assert_includes response.body, "Student Overview"
    assert_includes response.body, "Student Records and Stats"
    assert_includes response.body, "student-overview-students-tab"
    assert_includes response.body, "student-overview-stats-tab"
    assert_includes response.body, "Students by Domain"
    assert_includes response.body, "Competencies"
    assert_includes response.body, "Log on"
    assert_includes response.body, "1 / #{Reports::DataAggregator::COMPETENCY_TITLES.size}"
    assert_includes response.body, "meeting target"
    assert_includes response.body, @student.user.display_name
    assert_includes response.body, @other_student.user.display_name
    assert_includes response.body, student_overview_path(@student)
  end

  test "advisor only sees assigned advisees" do
    sign_in @advisor

    get student_overviews_path

    assert_response :success
    assert_includes response.body, @student.user.display_name
    assert_not_includes response.body, @other_student.user.display_name
  end

  test "student overview hides archived students by default and can include them explicitly" do
    @other_student.archive!(archived_by: @admin, reason: "Graduated cohort")
    sign_in @admin

    get student_overviews_path

    assert_response :success
    assert_includes response.body, @student.user.display_name
    assert_not_includes response.body, @other_student.user.display_name

    get student_overviews_path(student_status: "all")

    assert_response :success
    assert_includes response.body, @other_student.user.display_name
    assert_includes response.body, "Archived"
  end

  test "staff can open all in one student detail" do
    survey_assignments(:residential_assignment).update!(completed_at: 1.day.ago)
    create_met_competency_for(@student)
    sign_in @admin

    get student_overview_path(@student)

    assert_response :success
    assert_includes response.body, "All-in-one view"
    assert_includes response.body, "Advisor History"
    assert_includes response.body, "Survey Responses"
    assert_includes response.body, "Domain Snapshot"
    assert_includes response.body, "Competency Comparison"
    assert_includes response.body, "<th>Self</th>"
    assert_includes response.body, "<th>Advisor</th>"
    assert_includes response.body, "<th>Course</th>"
    assert_includes response.body, "Updated"
    assert_includes response.body, surveys(:fall_2025).title
    assert_includes response.body, "View response"
    assert_includes response.body, admin_competency_path(@student)
  end

  test "advisor cannot open another advisor student detail" do
    sign_in @advisor

    get student_overview_path(@other_student)

    assert_response :not_found
  end

  test "students cannot access staff student overviews" do
    sign_in users(:student)

    get student_overviews_path

    assert_redirected_to dashboard_path
    assert_match "Advisor or admin access required", flash[:alert]
  end

  private

  def create_met_competency_for(student)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    semester = program_semesters(:fall_2025)

    CompetencyTargetLevel.create!(
      program_semester: semester,
      track: student.track,
      program_year: student.program_year,
      competency_title: competency_title,
      target_level: 3
    )

    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => false }
    )

    GradeCompetencyRating.create!(
      grade_import_batch: batch,
      student: student,
      competency_title: competency_title,
      aggregated_level: 4,
      aggregation_rule: "max",
      evidence_count: 1
    )
  end
end
