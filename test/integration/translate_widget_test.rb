# frozen_string_literal: true

require "test_helper"

class TranslateWidgetTest < ActionDispatch::IntegrationTest
  test "auth layout renders the persistent translate widget without inline bootstrap" do
    get new_user_session_path

    assert_response :success
    assert_select "#gt-compact[data-turbo-permanent]"
    assert_select "#gt-toggle[aria-controls='gt-panel'][aria-expanded='false']"
    assert_select "#gt-panel[aria-hidden='true']"
    refute_includes response.body, "Google Translate widget loader"
  end

  test "signed in layout renders the persistent translate widget without inline bootstrap" do
    sign_in users(:student)

    get student_dashboard_path

    assert_response :success
    assert_select "#gt-compact[data-turbo-permanent]"
    assert_select "#google_translate_element"
    refute_includes response.body, "Google Translate widget loader"
  end
end
