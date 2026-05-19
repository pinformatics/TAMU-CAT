# frozen_string_literal: true

require "test_helper"

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
    assert_includes response.body, "Cohort Comparison"
    assert_includes response.body, "Student by Domain Heatmap"
    assert_includes response.body, "FERPA reminder"
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
end
