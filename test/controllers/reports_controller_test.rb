# frozen_string_literal: true

require "test_helper"
require "csv"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = users(:student)
  end

  # Access Control Tests - show action
  test "show requires authentication" do
    get reports_path

    assert_redirected_to new_user_session_path
  end

  test "show allows admin access" do
    sign_in @admin

    get reports_path

    assert_response :success
    assert_includes response.body, "Course Target Attainment"
    assert_includes response.body, "Course Contribution Report"
    assert_includes response.body, "Cohort Comparison"
    assert_includes response.body, "Heatmaps"
    assert_includes response.body, "FERPA reminder"
  end

  test "show uses report module tabs" do
    sign_in @admin

    get reports_path

    assert_response :success
    assert_download_href export_course_competency_reports_path, label: "Download CSV"

    get reports_path(report_tab: "cohort_comparison")

    assert_response :success
    assert_select "nav[aria-label='Report modules'] a[aria-current='page']", text: /Cohort Comparison/
    assert_download_href export_report_tab_path(report_tab: "cohort_comparison", format: :csv), label: "Download CSV"
    assert_select "input[name='course_code']", count: 0
    refute_includes response.body, "Course Contribution Report"

    get reports_path(report_tab: "domain_heatmap")

    assert_response :success
    assert_select "nav[aria-label='Report modules'] a[aria-current='page']", text: /Heatmaps/
    assert_download_href export_report_tab_path(report_tab: "domain_heatmap", format: :csv), label: "Download CSV"
    assert_includes response.body, "Student/Course Heatmap"
    assert_includes response.body, "Student by Domain Heatmap"
    refute_includes response.body, "Course Contribution Report"

    get reports_path(report_tab: "portfolio_export")

    assert_response :success
    assert_select "nav[aria-label='Report modules'] a[aria-current='page']", text: /Student Profile/
    assert_download_href export_reports_portfolio_path, label: "Download Excel"
    assert_select "input[name='q']"

    get reports_path(report_tab: "dashboard")

    assert_response :success
    assert_download_href export_reports_excel_path(section: "dashboard"), label: "Download Excel"
    assert_select ".c-analytics-root[data-controller='reports']"
  end

  test "show renders student profile rows in report style" do
    sign_in @admin
    student = students(:student)
    question = Question.create!(
      category: categories(:clinical_skills),
      question_text: StudentPortfolioExporter::PORTFOLIO_QUESTION_TEXT,
      question_order: 25,
      question_type: "evidence",
      is_required: true
    )
    StudentQuestion.create!(
      student: student,
      question: question,
      response_value: "https://sites.google.com/example/profile-export"
    )
    semester = program_semesters(:fall_2025)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "student-profile-course.csv",
      file_checksum: "checksum-student-profile-course",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: student,
      assignment_name: "Course Evidence",
      course_code: "PHPM-601",
      competency_title: "Policy Analysis",
      raw_grade: 5,
      mapped_level: 5,
      course_target_level: 4,
      source_key: "student-profile-course",
      import_fingerprint: "fingerprint-student-profile-course"
    )

    get reports_path(report_tab: "portfolio_export", q: student.user.display_name)

    assert_response :success
    assert_includes response.body, "Student Profile"
    assert_includes response.body, "https://sites.google.com/example/profile-export"
    assert_includes response.body, "Open profile"
    assert_select ".c-filter-bar input[name='q']"
    assert_select ".c-stats-grid .c-eyebrow", text: "Tracks"
    assert_select ".c-stats-grid .c-eyebrow", text: "Cohorts"
    assert_select ".c-stats-grid .c-eyebrow", text: "Course Evidence", count: 0
    assert_select ".c-stats-grid .c-eyebrow", text: "Below Target", count: 0
    assert_select ".c-table th", text: "UIN"
    assert_select ".c-table th", text: "Name"
    assert_select ".c-table th", text: "Email"
    assert_select ".c-table th", text: "Year"
    assert_select ".c-table th", text: "Google Sites"
    assert_select ".c-table th", text: "Course Evidence", count: 0
    assert_select ".c-table th", text: "Targets Met", count: 0
    assert_select ".c-table th", text: "Below Target", count: 0
    assert_select ".c-table th", text: "Met Rate", count: 0
    assert_select ".c-table td", text: student.uin
    assert_select ".c-table td", text: student.user.email
    assert_select ".c-table td", text: student.program_year.to_s
  end

  test "show renders course competency report rows with filters" do
    sign_in @admin
    student = students(:student)
    semester = program_semesters(:fall_2025)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "reports-course.csv",
      file_checksum: "checksum-reports-course",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: student,
      assignment_name: "Final",
      course_code: "PHPM-601",
      competency_title: "Policy Analysis",
      raw_grade: 5,
      mapped_level: 5,
      course_target_level: 4,
      source_key: "reports-course",
      import_fingerprint: "fingerprint-reports-course"
    )

    get reports_path(course_code: "PHPM-601")

    assert_response :success
    assert_includes response.body, "PHPM-601"
    assert_includes response.body, "Policy Analysis"
    assert_includes response.body, "100.0%"
    assert_includes response.body, "Download CSV"
    assert_select "details.c-accordion summary", text: /PHPM-601/
    assert_select "details.c-accordion summary", text: /1 competency/

    get reports_path(report_tab: "domain_heatmap", course_code: "PHPM-601")

    assert_response :success
    assert_select "details.c-accordion summary", text: /#{Regexp.escape(student.user.name)}/
    assert_select "details.c-accordion summary", text: /1 course/
    assert_select "details.c-accordion summary .c-accordion__action", text: /Show details/
    assert_select "details.c-accordion table th", text: "Course"
  end

  test "export_course_competencies returns csv and records audit" do
    sign_in @admin
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "reports-course-export.csv",
      file_checksum: "checksum-reports-course-export",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: students(:student),
      assignment_name: "Final",
      course_code: "PHPM-601",
      competency_title: "Policy Analysis",
      raw_grade: 5,
      mapped_level: 5,
      course_target_level: 4,
      source_key: "reports-course-export",
      import_fingerprint: "fingerprint-reports-course-export"
    )

    assert_difference -> { AdminActivityLog.where(action: "student_data_export").count }, 1 do
      get export_course_competency_reports_path(format: :csv, course_code: "PHPM-601")
    end

    assert_response :success
    assert_equal "text/csv", response.media_type
    parsed = CSV.parse(response.body, headers: true)
    assert_equal "PHPM-601", parsed.first["Course"]
    assert_equal "Policy Analysis", parsed.first["Competency"]
    activity = AdminActivityLog.where(action: "student_data_export").order(created_at: :desc).first
    assert_equal "course_competency_report_csv", activity.metadata["export_type"]
    assert_equal "PHPM-601", activity.metadata["course_code"]
  end

  test "export_tab_csv downloads cohort comparison csv" do
    sign_in @admin

    assert_difference -> { AdminActivityLog.where(action: "student_data_export").count }, 1 do
      get export_report_tab_path(report_tab: "cohort_comparison", format: :csv)
    end

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Cohort,Students,Self Avg,Advisor Avg,Course Avg,Below Target"
    activity = AdminActivityLog.where(action: "student_data_export").order(created_at: :desc).first
    assert_equal "cohort_comparison_report_csv", activity.metadata["export_type"]
  end

  test "export_tab_csv downloads combined heatmaps csv" do
    sign_in @admin

    get export_report_tab_path(report_tab: "domain_heatmap", format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Student/Course Heatmap"
    assert_includes response.body, "Student by Domain Heatmap"
  end

  test "export_tab_csv downloads dashboard summary csv" do
    sign_in @admin

    get export_report_tab_path(report_tab: "dashboard", format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Metric,Value,Change,Description,Sample Size"
  end

  test "export_portfolio downloads student profile workbook" do
    sign_in @admin

    assert_difference -> { AdminActivityLog.where(action: "student_data_export").count }, 1 do
      get export_reports_portfolio_path
    end

    assert_response :success
    assert_includes response.headers["Content-Disposition"], ".xlsx"
    assert_equal "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", response.media_type
    activity = AdminActivityLog.where(action: "student_data_export").order(created_at: :desc).first
    assert_equal "student_profile_portfolio_excel", activity.metadata["export_type"]
  end

  test "show allows advisor access" do
    sign_in @advisor

    get reports_path

    assert_response :success
  end

  test "show denies student access and redirects to dashboard" do
    sign_in @student

    get reports_path

    assert_redirected_to dashboard_path
    assert_equal "Reports are only available to administrators and advisors.", flash[:alert]
  end

  # Access Control Tests - export_pdf action
  test "export_pdf requires authentication" do
    get export_reports_pdf_path(section: "all")

    assert_redirected_to new_user_session_path
  end

  test "export_pdf allows admin access" do
    sign_in @admin

    get export_reports_pdf_path(section: "all")

    assert_response :success
  end

  test "export_pdf allows advisor access" do
    sign_in @advisor

    get export_reports_pdf_path(section: "all")

    assert_response :success
  end

  test "export_pdf denies student access" do
    sign_in @student

    get export_reports_pdf_path(section: "all")

    assert_redirected_to dashboard_path
    assert_equal "Reports are only available to administrators and advisors.", flash[:alert]
  end

  # Access Control Tests - export_excel action
  test "export_excel requires authentication" do
    get export_reports_excel_path

    assert_redirected_to new_user_session_path
  end

  test "export_excel allows admin access" do
    sign_in @admin

    assert_difference -> { AdminActivityLog.where(action: "student_data_export").count }, 1 do
      get export_reports_excel_path
    end

    assert_response :success
  end

  test "export_excel allows advisor access" do
    sign_in @advisor

    get export_reports_excel_path

    assert_response :success
  end

  test "export_excel denies student access" do
    sign_in @student

    get export_reports_excel_path

    assert_redirected_to dashboard_path
    assert_equal "Reports are only available to administrators and advisors.", flash[:alert]
  end

  # PDF Export Tests
  test "export_pdf generates PDF with correct content type" do
    sign_in @admin

    get export_reports_pdf_path(section: "all")

    assert_response :success
    assert_equal "application/pdf", @response.content_type
  end

  test "export_pdf sets correct disposition as attachment" do
    sign_in @admin

    get export_reports_pdf_path(section: "all")

    assert_response :success
    assert_match(/attachment/, @response.headers["Content-Disposition"])
  end

  test "export_pdf filename includes timestamp" do
    sign_in @admin

    get export_reports_pdf_path(section: "all")

    assert_response :success
    assert_match(/health-reports-\d{8}-\d{4}\.pdf/, @response.headers["Content-Disposition"])
  end

  test "export_pdf handles section parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "competency")

    assert_response :success
  end

  test "export_pdf handles empty string section parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "all")

    assert_response :success
  end

  test "export_pdf normalizes dashboard section to nil" do
    sign_in @admin

    get export_reports_pdf_path(section: "dashboard")

    assert_response :success
  end

  test "export_pdf normalizes all section to nil" do
    sign_in @admin

    get export_reports_pdf_path(section: "all")

    assert_response :success
  end

  test "export_pdf normalizes full section to nil" do
    sign_in @admin

    get export_reports_pdf_path(section: "full")

    assert_response :success
  end

  test "export_pdf normalizes default section to nil" do
    sign_in @admin

    get export_reports_pdf_path(section: "default")

    assert_response :success
  end

  test "export_pdf keeps valid section values" do
    sign_in @admin

    get export_reports_pdf_path(section: "competency-summary")

    assert_response :success
  end

  # Excel Export Tests
  test "export_excel generates Excel with correct content type" do
    sign_in @admin

    get export_reports_excel_path

    assert_response :success
    assert_equal "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", @response.content_type
  end

  test "export_excel sets correct disposition as attachment" do
    sign_in @admin

    get export_reports_excel_path

    assert_response :success
    assert_match(/attachment/, @response.headers["Content-Disposition"])
  end

  test "export_excel filename includes timestamp" do
    sign_in @admin

    get export_reports_excel_path

    assert_response :success
    assert_match(/health-reports-\d{8}-\d{4}\.xlsx/, @response.headers["Content-Disposition"])
  end

  test "export_excel handles section parameter" do
    sign_in @admin

    get export_reports_excel_path(section: "competency")

    assert_response :success
  end

  test "export_excel handles nil section parameter" do
    sign_in @admin

    get export_reports_excel_path(section: "")

    assert_response :success
  end

  test "export_excel normalizes section values" do
    sign_in @admin

    get export_reports_excel_path(section: "all")

    assert_response :success
  end

  # Filter Parameters Tests
  test "export_pdf accepts track parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "all", track: "CS")

    assert_response :success
  end

  test "export_pdf accepts semester parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "all", semester: "Fall 2023")

    assert_response :success
  end

  test "export_pdf accepts survey_id parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "all", survey_id: 1)

    assert_response :success
  end

  test "export_pdf accepts category_id parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "all", category_id: 1)

    assert_response :success
  end

  test "export_pdf accepts student_id parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "all", student_id: 1)

    assert_response :success
  end

  test "export_pdf accepts advisor_id parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "all", advisor_id: 1)

    assert_response :success
  end

  test "export_pdf accepts competency parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "all", competency: "Problem Solving")

    assert_response :success
  end

  test "export_pdf accepts multiple filter parameters" do
    sign_in @admin

    get export_reports_pdf_path(
      section: "all",
      track: "CS",
      semester: "Fall 2023",
      survey_id: 1
    )

    assert_response :success
  end

  test "export_excel accepts track parameter" do
    sign_in @admin

    get export_reports_excel_path(track: "CS")

    assert_response :success
  end

  test "export_excel accepts semester parameter" do
    sign_in @admin

    get export_reports_excel_path(semester: "Fall 2023")

    assert_response :success
  end

  test "export_excel accepts survey_id parameter" do
    sign_in @admin

    get export_reports_excel_path(survey_id: 1)

    assert_response :success
  end

  test "export_excel accepts category_id parameter" do
    sign_in @admin

    get export_reports_excel_path(category_id: 1)

    assert_response :success
  end

  test "export_excel accepts student_id parameter" do
    sign_in @admin

    get export_reports_excel_path(student_id: 1)

    assert_response :success
  end

  test "export_excel accepts advisor_id parameter" do
    sign_in @admin

    get export_reports_excel_path(advisor_id: 1)

    assert_response :success
  end

  test "export_excel accepts competency parameter" do
    sign_in @admin

    get export_reports_excel_path(competency: "Problem Solving")

    assert_response :success
  end

  test "export_excel accepts multiple filter parameters" do
    sign_in @admin

    get export_reports_excel_path(
      track: "CS",
      semester: "Fall 2023",
      survey_id: 1
    )

    assert_response :success
  end

  # Role-based access verification
  test "only admins and advisors can access show" do
    sign_in @student
    get reports_path
    assert_redirected_to dashboard_path

    sign_out @student

    sign_in @advisor
    get reports_path
    assert_response :success

    sign_out @advisor

    sign_in @admin
    get reports_path
    assert_response :success
  end

  test "only admins and advisors can export PDF" do
    sign_in @student
    get export_reports_pdf_path(section: "all")
    assert_redirected_to dashboard_path

    sign_out @student

    sign_in @advisor
    get export_reports_pdf_path(section: "all")
    assert_response :success

    sign_out @advisor

    sign_in @admin
    get export_reports_pdf_path(section: "all")
    assert_response :success
  end

  test "only admins and advisors can export Excel" do
    sign_in @student
    get export_reports_excel_path
    assert_redirected_to dashboard_path

    sign_out @student

    sign_in @advisor
    get export_reports_excel_path
    assert_response :success

    sign_out @advisor

    sign_in @admin
    get export_reports_excel_path
    assert_response :success
  end

  # Content Verification Tests
  test "show renders successfully for admin" do
    sign_in @admin

    get reports_path

    assert_response :success
  end

  test "show renders successfully for advisor" do
    sign_in @advisor

    get reports_path

    assert_response :success
  end

  # Parameter Handling Tests
  test "show accepts filter parameters" do
    sign_in @admin

    get reports_path(track: "CS", semester: "Fall 2023")

    assert_response :success
  end

  test "export_pdf handles whitespace in section parameter" do
    sign_in @admin

    get export_reports_pdf_path(section: "  ")

    assert_response :success
  end

  test "export_excel handles whitespace in section parameter" do
    sign_in @admin

    get export_reports_excel_path(section: "  ")

    assert_response :success
  end

  # Export Format Tests
  test "PDF export returns binary data" do
    sign_in @admin

    get export_reports_pdf_path(section: "all")

    assert_response :success
    assert @response.body.present?
    assert @response.body.start_with?("%PDF")
  end

  test "Excel export returns binary data" do
    sign_in @admin

    get export_reports_excel_path

    assert_response :success
    assert @response.body.present?
  end

  # Multiple Exports Tests
  test "can export PDF multiple times" do
    sign_in @admin

    3.times do
      get export_reports_pdf_path(section: "all")
      assert_response :success
    end
  end

  test "can export Excel multiple times" do
    sign_in @admin

    3.times do
      get export_reports_excel_path
      assert_response :success
    end
  end

  # Section Parameter Edge Cases
  test "export_pdf handles various section values" do
    sign_in @admin

    sections = [ "competency", "alignment", "benchmark", "competency-detail" ]
    sections.each do |section|
      get export_reports_pdf_path(section: section)
      assert_response :success
    end
  end

  test "export_excel handles various section values" do
    sign_in @admin

    sections = [ "competency", "alignment", "benchmark", "competency-detail" ]
    sections.each do |section|
      get export_reports_excel_path(section: section)
      assert_response :success
    end
  end

  # Timestamp Verification
  test "PDF filename includes valid timestamp format" do
    sign_in @admin

    get export_reports_pdf_path(section: "all")

    assert_response :success
    assert_match(/health-reports-\d{8}-\d{4}\.pdf/, @response.headers["Content-Disposition"])
  end

  test "Excel filename includes valid timestamp format" do
    sign_in @admin

    get export_reports_excel_path

    assert_response :success
    assert_match(/health-reports-\d{8}-\d{4}\.xlsx/, @response.headers["Content-Disposition"])
  end

  # Error Handling Tests
  test "export_pdf handles invalid parameters gracefully" do
    sign_in @admin

    get export_reports_pdf_path(section: "all", invalid_param: "value")

    assert_response :success
  end

  test "export_excel handles invalid parameters gracefully" do
    sign_in @admin

    get export_reports_excel_path(invalid_param: "value")

    assert_response :success
  end

  # Alert Message Tests
  test "student redirect includes appropriate alert message" do
    sign_in @student

    get reports_path

    assert_redirected_to dashboard_path
    assert_not_nil flash[:alert]
    assert_includes flash[:alert], "administrators and advisors"
  end

  test "student redirect from PDF export includes alert" do
    sign_in @student

    get export_reports_pdf_path(section: "all")

    assert_redirected_to dashboard_path
    assert_not_nil flash[:alert]
  end

  test "student redirect from Excel export includes alert" do
    sign_in @student

    get export_reports_excel_path

    assert_redirected_to dashboard_path
    assert_not_nil flash[:alert]
  end

  private

  def assert_download_href(expected_path, label:)
    hrefs = css_select("a")
      .select { |link| link.text.squish == label }
      .map { |link| link["href"] }

    assert_includes hrefs, expected_path, "Expected #{label} link to #{expected_path}; found #{hrefs.inspect}"
  end
end
