# frozen_string_literal: true

require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:student)
  end

  test "redirects to sign in when not authenticated" do
    get account_path

    assert_response :redirect
    assert_redirected_to new_user_session_path
  end

  test "shows read-only account page for authenticated user" do
    sign_in @user

    get account_path

    assert_response :success
    assert_includes response.body, "Account Information"
    assert_includes response.body, @user.name
    assert_includes response.body, @user.email
    assert_includes response.body, "Account information is read-only"
    assert_select "form[action=?]", account_path, count: 0
    assert_select "input[name='user[name]']", count: 0
    assert_select "input[type='submit'][value='Save changes']", count: 0
    assert_select "a", text: "Edit", count: 0
  end

  test "old account edit path redirects to account page" do
    sign_in @user

    get edit_account_path

    assert_redirected_to account_path
  end

  test "patch account does not update account information" do
    sign_in @user

    patch account_path, params: { user: { name: "Updated Name", email: "hacker@example.com" } }

    assert_redirected_to account_path
    assert_equal "Account information is managed by your sign-in account and cannot be edited here.", flash[:alert]

    follow_redirect!

    assert_select ".c-flash-stack .c-flash-toast.flash__alert", text: /Account information is managed/

    @user.reload
    assert_equal "Student User", @user.name
    assert_equal "student@example.com", @user.email
  end

  test "patch account requires authentication" do
    patch account_path, params: { user: { name: "Updated Name" } }

    assert_redirected_to new_user_session_path
  end
end
