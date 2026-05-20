require "test_helper"

class ImpersonationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @student = users(:student)
  end

  test "non-admin cannot open impersonation page" do
    sign_in @student

    get new_impersonation_path

    assert_redirected_to dashboard_path
    assert_match(/admin privileges/i, flash[:alert].to_s)
  end

  test "admin can open impersonation page with searchable selects" do
    sign_in @admin

    get new_impersonation_path

    assert_response :success
    assert_select "[data-combobox='true']", count: 2
    assert_select "[data-combobox-menu='true'].hidden", count: 2
    assert_select "[data-combobox-menu='true'].u-hidden", count: 0
    assert_select "[data-combobox-option-value='#{@student.id}']"
  end

  test "admin can impersonate a student by numeric id" do
    sign_in @admin

    post impersonation_path, params: { impersonation: { user_id: @student.id.to_s } }

    assert_redirected_to student_dashboard_path
    follow_redirect!
    assert_match(/Now viewing as/i, flash[:notice].to_s)

    delete impersonation_path
    assert_redirected_to admin_dashboard_path
  end

  test "admin can impersonate a student by email embedded in combobox value" do
    sign_in @admin

    post impersonation_path, params: { impersonation: { user_id: "#{@student.name} <#{@student.email}>" } }

    assert_redirected_to student_dashboard_path
    follow_redirect!
    assert_match(/Now viewing as/i, flash[:notice].to_s)
  end

  test "admin can impersonate a student by name when no email present" do
    sign_in @admin

    post impersonation_path, params: { impersonation: { user_id: @student.name } }

    assert_redirected_to student_dashboard_path
    follow_redirect!
    assert_match(/Now viewing as/i, flash[:notice].to_s)
  end

  test "admin impersonation rejects unknown student" do
    sign_in @admin

    post impersonation_path, params: { impersonation: { user_id: "missing@example.com" } }

    assert_redirected_to new_impersonation_path
    assert_match(/Student not found/i, flash[:alert].to_s)
  end

  test "destroy redirects when not impersonating" do
    sign_in @admin

    delete impersonation_path

    assert_redirected_to dashboard_path
    assert_match(/not currently viewing/i, flash[:alert].to_s)
  end
end

class ImpersonationsControllerUnitTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers
  tests ImpersonationsController

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
  end

  test "destroy signs out when impersonator id no longer resolves" do
    impersonated_student = users(:student)
    sign_in impersonated_student

    session[:impersonator_user_id] = -1
    session[:impersonation_kind] = "student"

    delete :destroy

    assert_redirected_to new_user_session_path
    assert_match(/expired/i, flash[:alert].to_s)
  end
end
