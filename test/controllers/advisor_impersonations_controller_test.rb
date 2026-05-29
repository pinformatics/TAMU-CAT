require "test_helper"

class AdvisorImpersonationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = users(:student)
  end

  test "non-admin cannot open advisor impersonation page" do
    sign_in @student

    get new_advisor_impersonation_path

    assert_redirected_to dashboard_path
    assert_match(/admin access is required/i, flash[:alert].to_s)
  end

  test "advisor cannot open advisor impersonation page" do
    sign_in @advisor

    get new_advisor_impersonation_path

    assert_redirected_to dashboard_path
    assert_match(/admin access is required/i, flash[:alert].to_s)
  end

  test "admin can open advisor impersonation page" do
    sign_in @admin

    get new_advisor_impersonation_path

    assert_response :success
  end

  test "admin can impersonate an advisor" do
    sign_in @admin

    post advisor_impersonation_path, params: { advisor_impersonation: { user_id: @advisor.id.to_s } }

    assert_redirected_to advisor_dashboard_path

    delete advisor_impersonation_path
    assert_redirected_to admin_dashboard_path
  end

  test "advisor impersonation rejects unknown advisor" do
    sign_in @admin

    post advisor_impersonation_path, params: { advisor_impersonation: { user_id: 9_999_999 } }

    assert_redirected_to new_advisor_impersonation_path
    assert_match(/Advisor not found/i, flash[:alert].to_s)
  end

  test "destroy redirects when not impersonating" do
    sign_in @admin

    delete advisor_impersonation_path

    assert_redirected_to dashboard_path
    assert_match(/not currently emulating/i, flash[:alert].to_s)
  end
end
