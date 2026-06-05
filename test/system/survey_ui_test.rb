require "application_system_test_case"

class SurveyUiTest < ApplicationSystemTestCase
  test "student views survey and sees questions" do
    user = users(:student)
    student = students(:student)
    sign_in user
    visit survey_path(surveys(:fall_2025))

    assert_selector "form"
    assert_text "How do you rate your clinical skills?"
  end

  test "student navbar includes mobile navigation drawer controls" do
    sign_in users(:student)
    visit student_dashboard_path

    assert_selector "[data-mobile-nav-toggle][aria-controls='student-mobile-nav']", visible: :all
    assert_selector "#student-mobile-nav[data-mobile-nav-drawer]", visible: :all
    assert_selector "#student-mobile-nav [data-mobile-nav-close]", visible: :all
  end
end
