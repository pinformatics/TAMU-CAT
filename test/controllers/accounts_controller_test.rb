# frozen_string_literal: true

require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @student_user = users(:student)
    @student = students(:student)
    @admin = users(:admin)
  end

  test "redirects to sign in when not authenticated" do
    get account_path

    assert_response :redirect
    assert_redirected_to new_user_session_path
  end

  test "shows student account page as read-only with edit button" do
    sign_in @student_user

    get account_path

    assert_response :success
    assert_includes response.body, "Account Information"
    assert_includes response.body, @student_user.name
    assert_includes response.body, @student_user.email
    assert_includes response.body, "Program Details"
    assert_select "form[action=?]", account_path, count: 0
    assert_select "input[name='student[uin]']", count: 0
    assert_select "select[name='student[program_year]']", count: 0
    assert_select "select[name='student[major]']", count: 0
    assert_select "select[name='student[track]']", count: 0
    assert_select "select[name='student[advisor_id]']", count: 0
    assert_select "input[name='user[name]']", count: 0
    assert_select "input[type='submit'][value='Save changes']", count: 0
    assert_select "nav[aria-label='Account and settings navigation']"
    assert_select "nav[aria-label='Account and settings navigation'] a[href=?].is-active", account_path, text: "Account"
    assert_select "nav[aria-label='Account and settings navigation'] a[href=?]", settings_path, text: "Settings"
    assert_select "nav[aria-label='Account and settings navigation'] a[href=?].c-tab--danger", destroy_user_session_path, text: "Sign out"
    assert_select "a[href=?]", edit_account_path, text: "Edit"
  end

  test "shows read-only account page for non-student user" do
    sign_in @admin

    get account_path

    assert_response :success
    assert_includes response.body, "Account Information"
    assert_includes response.body, @admin.name
    assert_includes response.body, @admin.email
    assert_includes response.body, "Account identity details are read-only"
    assert_select "form[action=?]", account_path, count: 0
    assert_select "input[name='user[name]']", count: 0
    assert_select "nav[aria-label='Account and settings navigation']"
    assert_select "nav[aria-label='Account and settings navigation'] a[href=?].is-active", account_path, text: "Account"
    assert_select "nav[aria-label='Account and settings navigation'] a[href=?]", settings_path, text: "Settings"
    assert_select "nav[aria-label='Account and settings navigation'] a[href=?].c-tab--danger", destroy_user_session_path, text: "Sign out"
    assert_select "a", text: "Edit", count: 0
  end

  test "edit displays student account program form" do
    sign_in @student_user

    get edit_account_path

    assert_response :success
    assert_includes response.body, "Edit Account Information"
    assert_select "form[action=?]", account_path
    assert_select "input[name='student[uin]']"
    assert_select "select[name='student[program_year]']"
    assert_select "select[name='student[major]']"
    assert_select "select[name='student[track]']"
    assert_select "select[name='student[advisor_id]']"
    assert_select "input[name='user[name]']", count: 0
    assert_select "nav[aria-label='Account and settings navigation'] a[href=?].is-active", account_path, text: "Account"
    assert_select "nav[aria-label='Account and settings navigation'] a[href=?]", settings_path, text: "Settings"
    assert_select "nav[aria-label='Account and settings navigation'] a[href=?].c-tab--danger", destroy_user_session_path, text: "Sign out"
  end

  test "edit redirects non-student user to account page" do
    sign_in @admin

    get edit_account_path

    assert_redirected_to account_path
    assert_equal "Account identity details are managed by your sign-in account and cannot be edited here.", flash[:alert]
  end

  test "patch account does not update account information" do
    sign_in @student_user

    patch account_path, params: { user: { name: "Updated Name", email: "hacker@example.com" } }

    assert_redirected_to account_path
    assert_equal "Account identity details are managed by your sign-in account and cannot be edited here.", flash[:alert]

    follow_redirect!

    assert_select ".c-flash-stack .c-flash-toast.flash__alert", text: /Account identity details are managed/

    @student_user.reload
    assert_equal "Student User", @student_user.name
    assert_equal "student@example.com", @student_user.email
  end

  test "patch account updates student program details" do
    sign_in @student_user
    original_attrs = @student.attributes.slice("uin", "major", "track", "program_year", "advisor_id")
    new_advisor = advisors(:other_advisor)

    patch account_path, params: {
      student: {
        uin: "222333444",
        major: "MHA",
        track: "Executive",
        program_year: 2027,
        advisor_id: new_advisor.advisor_id
      }
    }

    assert_redirected_to account_path
    assert_equal "Student profile updated.", flash[:notice]

    @student.reload
    assert_equal "222333444", @student.uin
    assert_equal "MHA", @student.major
    assert_equal "Executive", @student.track
    assert_equal 2027, @student.program_year
    assert_equal new_advisor.advisor_id, @student.advisor_id
  ensure
    @student.update!(original_attrs) if @student&.persisted?
  end

  test "patch account re-renders student program details with validation errors" do
    sign_in @student_user

    patch account_path, params: {
      student: {
        uin: "",
        major: "",
        track: "",
        program_year: "",
        advisor_id: nil
      }
    }

    assert_response :unprocessable_entity
    assert_select "h2", text: "Program Details"
    assert_select ".c-card--danger"
  end

  test "patch account requires authentication" do
    patch account_path, params: { user: { name: "Updated Name" } }

    assert_redirected_to new_user_session_path
  end
end
