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
    assert_equal ApplicationController::ADMIN_ONLY_MESSAGE, flash[:alert]
  end

  test "admin can open impersonation page with searchable selects" do
    sign_in @admin

    get new_impersonation_path

    assert_response :success
    assert_select "[data-combobox='true']", count: 2
    assert_select "[data-combobox-menu='true'].hidden", count: 2
    assert_select "[data-combobox-menu='true'].u-hidden", count: 0
    assert_select "input[type='hidden'][name='impersonation[user_id]'][data-combobox-value='true']"
    assert_select "datalist", count: 0
    assert_select "[data-combobox-option-value='#{@student.id}']"
    assert_select "[data-combobox-option-search*='#{@student.email}']"
    assert_select "[data-combobox-option-search*='123456789']"
    assert_includes response.body, "UIN 123456789"
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

  test "admin can impersonate a student by UIN" do
    sign_in @admin

    post impersonation_path, params: { impersonation: { user_id: students(:student).uin } }

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

  test "private option builders and lookup handle blank fallback and embedded uin" do
    student_user = users(:student)
    student = student_user.student_profile
    student.update!(uin: nil)

    option = @controller.send(:student_impersonation_option, student_user)
    assert_equal student_user.id, option[:value]
    assert_equal student_user.full_name, option[:label]
    assert_equal student_user.email, option[:description]

    advisor_option = @controller.send(:user_impersonation_option, users(:advisor))
    assert_equal users(:advisor).email, advisor_option[:description]

    assert_nil @controller.send(:find_student_user, " ")
    assert_nil @controller.send(:find_student_user, "-123")
  ensure
    student&.update!(uin: "123456789")
  end

  test "private lookup supports numeric unknown email uin text and name misses" do
    student_user = users(:student)
    student = student_user.student_profile

    assert_equal student_user, @controller.send(:find_student_user, "ID #{student.uin} selected")
    assert_nil @controller.send(:find_student_user, "missing student name")
    assert_nil @controller.send(:find_student_user, "missing@example.com")
    assert_nil @controller.send(:find_student_user, "999999999")
  end

  test "private guards and impersonator helper cover admin and non-impersonating paths" do
    sign_in users(:admin)
    assert_nil @controller.send(:require_admin!)

    session[:impersonator_user_id] = users(:admin).id
    assert @controller.send(:impersonating?)
    assert_equal users(:admin), @controller.send(:impersonator_user)

    session.delete(:impersonator_user_id)
    assert_nil @controller.send(:impersonator_user)
  end
end
