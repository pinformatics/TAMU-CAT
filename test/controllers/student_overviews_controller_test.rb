require "test_helper"
require "roo"
require "tempfile"
require "uri"

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
    assert_includes response.body, "Survey Records and Stats"
    assert_includes response.body, "Current Students"
    assert_includes response.body, "student-overview-students-tab"
    assert_includes response.body, "student-overview-stats-tab"
    assert_includes response.body, "Students by Domain"
    assert_includes response.body, "Competencies"
    assert_includes response.body, "Year"
    assert_not_includes response.body, "Class of"
    assert_not_includes response.body, "Log on"
    assert_includes response.body, "1 / #{Reports::DataAggregator::COMPETENCY_TITLES.size}"
    assert_includes response.body, "meeting target"
    assert_includes response.body, @student.user.display_name
    assert_includes response.body, @other_student.user.display_name
    assert_includes response.body, student_overview_path(@student)
    assert_includes response.body, export_excel_student_overviews_path
  end

  test "admin can export filtered student overview workbook" do
    create_met_competency_for(@student)
    sign_in @admin

    get export_excel_student_overviews_path(q: @student.user.name)

    assert_response :success
    assert_equal "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", response.media_type
    assert_includes response.headers["Content-Disposition"], "student-overviews"
    assert_includes response.headers["Content-Disposition"], ".xlsx"

    open_xlsx_response do |workbook|
      assert_equal [ "Students", "Domain Heatmap", "Filters" ], workbook.sheets

      students_sheet = workbook.sheet("Students")
      assert_equal "Student", students_sheet.cell(4, 1)
      assert_includes students_sheet.column(1), @student.user.display_name
      assert_not_includes students_sheet.column(1), @other_student.user.display_name

      heatmap_sheet = workbook.sheet("Domain Heatmap")
      assert_equal "Student", heatmap_sheet.cell(4, 1)
      assert_includes heatmap_sheet.row(4), Reports::DataAggregator::REPORT_DOMAINS.first
    end
  end

  test "student overview export button preserves current filters" do
    sign_in @admin

    get student_overviews_path(
      q: @student.user.email,
      track: "Residential",
      program_year: "2026",
      student_status: "all"
    )

    assert_response :success
    assert_link_path_and_query(
      "Download Excel",
      export_excel_student_overviews_path,
      "q" => @student.user.email,
      "track" => "Residential",
      "program_year" => "2026",
      "student_status" => "all"
    )
  end

  test "advisor only sees assigned advisees" do
    sign_in @advisor

    get student_overviews_path

    assert_response :success
    assert_includes response.body, @student.user.display_name
    assert_not_includes response.body, @other_student.user.display_name
  end

  test "advisor export only includes assigned advisees" do
    sign_in @advisor

    get export_excel_student_overviews_path

    assert_response :success

    open_xlsx_response do |workbook|
      students_sheet = workbook.sheet("Students")
      assert_includes students_sheet.column(1), @student.user.display_name
      assert_not_includes students_sheet.column(1), @other_student.user.display_name
    end
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
    assert_includes response.body, "Graduated / Inactive Students"
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
    assert_includes response.body, "Competency History"
    assert_includes response.body, "Competency Review Notes"
    assert_includes response.body, competency_history_student_overview_path(@student)
    assert_select ".c-ferpa-export-notice", text: /Student-level competency history exports/
    assert_select "a[data-turbo='false'][data-turbo-confirm*='FERPA reminder']", text: "Export history CSV"
    assert_includes response.body, "Competency Comparison"
    assert_includes response.body, "<th>Self</th>"
    assert_includes response.body, "<th>Advisor</th>"
    assert_includes response.body, "<th>Course</th>"
    assert_includes response.body, "Updated"
    assert_includes response.body, surveys(:fall_2025).title
    assert_includes response.body, "View response"
    assert_includes response.body, admin_competency_path(@student)
  end

  test "student detail renders confidential advisor note bodies" do
    ConfidentialAdvisorNote.create!(
      student: @student,
      survey: surveys(:fall_2025),
      advisor: advisors(:advisor),
      body: "Confidential overview note that should render."
    )
    sign_in @admin

    get student_overview_path(@student)

    assert_response :success
    assert_includes response.body, "Confidential overview note that should render."
    assert_includes response.body, "Advisor notes"
    assert_includes response.body, "Competency Review Notes"
  end

  test "advisor cannot open another advisor student detail" do
    sign_in @advisor

    get student_overview_path(@other_student)

    assert_redirected_to student_overviews_path
    assert_equal "That student overview is not available from your account.", flash[:alert]
  end

  test "staff can export one student competency history" do
    create_course_evidence_for(@student)
    sign_in @admin

    get competency_history_student_overview_path(@student)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Course evidence"
    assert_includes response.body, "PHPM-601"
    assert_includes response.body, "Yes"
  end

  test "advisor cannot export another advisor student competency history" do
    create_course_evidence_for(@other_student)
    sign_in @advisor

    get competency_history_student_overview_path(@other_student)

    assert_redirected_to student_overviews_path
    assert_equal "That student competency history is not available from your account.", flash[:alert]
  end

  test "students cannot access staff student overviews" do
    sign_in users(:student)

    get student_overviews_path

    assert_redirected_to dashboard_path
    assert_equal ApplicationController::STAFF_ONLY_MESSAGE, flash[:alert]
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

  def create_course_evidence_for(student)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = GradeImportFile.create!(
      grade_import_batch: batch,
      file_name: "Outcomes-26S-PHPM-601.csv",
      file_checksum: "student-overview-history-#{student.student_id}",
      status: "processed"
    )
    GradeCompetencyEvidence.create!(
      grade_import_batch: batch,
      grade_import_file: file,
      student: student,
      competency_title: competency_title,
      course_code: "PHPM-601",
      assignment_name: "Course outcome",
      raw_grade: 4,
      mapped_level: 4,
      course_target_level: 3,
      source_key: "student-overview-history-#{student.student_id}",
      import_fingerprint: "student-overview-history-#{student.student_id}"
    )
  end

  def open_xlsx_response
    Tempfile.create([ "student-overviews", ".xlsx" ], binmode: true) do |file|
      file.write(response.body)
      file.flush
      yield Roo::Excelx.new(file.path)
    end
  end

  def assert_link_path_and_query(label, expected_path, expected_query)
    link = css_select("a").find { |anchor| anchor.text.squish == label }
    assert link, "Expected to find #{label.inspect} link"

    uri = URI.parse(link["href"])
    assert_equal expected_path, uri.path

    query = Rack::Utils.parse_nested_query(uri.query)
    expected_query.each do |key, value|
      assert_equal value, query[key], "Expected #{label} query #{key}=#{value.inspect}; found #{query.inspect}"
    end
  end
end
