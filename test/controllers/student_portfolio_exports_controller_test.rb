require "test_helper"

class StudentPortfolioExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = students(:student)
    @other_student = students(:other_student)
    @student.update!(advisor_id: @advisor.id)
    @other_student.update!(advisor_id: users(:other_advisor).id)
    @portfolio_question = Question.create!(
      category: categories(:clinical_skills),
      question_text: StudentPortfolioExporter::PORTFOLIO_QUESTION_TEXT,
      question_order: 20,
      question_type: "evidence",
      is_required: true
    )
    StudentQuestion.create!(
      student: @student,
      question: @portfolio_question,
      response_value: "https://sites.google.com/example/student"
    )
    StudentQuestion.create!(
      student: @other_student,
      question: @portfolio_question,
      response_value: "https://sites.google.com/example/other"
    )
  end

  test "legacy portfolio export page redirects into reports" do
    sign_in @admin

    get student_portfolio_export_path

    assert_redirected_to reports_path(report_tab: "portfolio_export")
  end

  test "legacy portfolio export page preserves filters when redirecting into reports" do
    sign_in @admin

    get student_portfolio_export_path(q: @student.user.email, track: "Residential", program_year: "2026")

    assert_redirected_to reports_path(
      q: @student.user.email,
      track: "Residential",
      program_year: "2026",
      report_tab: "portfolio_export"
    )
  end

  test "advisor legacy portfolio export page redirects into reports" do
    sign_in @advisor

    get student_portfolio_export_path

    assert_redirected_to reports_path(report_tab: "portfolio_export")
  end

  test "legacy export download redirects to reports export" do
    sign_in @admin

    get download_student_portfolio_export_path

    assert_redirected_to export_reports_portfolio_path
  end

  test "legacy export download preserves filters when redirecting to workbook" do
    sign_in @admin

    get download_student_portfolio_export_path(q: @student.user.email, track: "Residential", program_year: "2026")

    assert_redirected_to export_reports_portfolio_path(
      q: @student.user.email,
      track: "Residential",
      program_year: "2026"
    )
  end

  test "student cannot access portfolio export" do
    sign_in users(:student)

    get student_portfolio_export_path

    assert_redirected_to dashboard_path
  end
end
