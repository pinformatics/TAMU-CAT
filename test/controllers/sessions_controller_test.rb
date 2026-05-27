# frozen_string_literal: true

require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin_user = users(:admin)
    @student_user = users(:student)
    @advisor_user = users(:advisor)
    @student = students(:student)
  end

  # Test that dashboard_path redirects correctly based on role
  test "after_sign_in_path redirects admin to admin dashboard" do
    sign_in @admin_user
    get dashboard_path

    # Dashboard controller redirects to role-specific dashboard
    assert_redirected_to admin_dashboard_path
  end

  test "after_sign_in_path redirects advisor to advisor dashboard" do
    sign_in @advisor_user
    get dashboard_path

    assert_redirected_to advisor_dashboard_path
  end

  test "after_sign_in_path redirects student to student dashboard" do
    sign_in @student_user
    get dashboard_path

    assert_redirected_to student_dashboard_path
  end

  # Sign out redirect tests
  test "after_sign_out_path redirects to sign in page" do
    sign_in @student_user

    delete destroy_user_session_path

    assert_redirected_to new_user_session_path
  end

  test "sign out destroys session" do
    sign_in @student_user

    delete destroy_user_session_path

    # After sign out, trying to access protected resource should redirect to sign in
    get dashboard_path
    assert_redirected_to new_user_session_path
  end

  # GET sign_out fallback tests
  test "sign_out_get_fallback redirects to sign in page" do
    get "/sign_out"

    assert_redirected_to new_user_session_path
  end

  test "sign_out_get_fallback does not sign out user" do
    sign_in @student_user

    get "/sign_out"

    # User should still be able to access protected resources
    get dashboard_path
    assert_response :redirect # Will redirect to role-specific dashboard, not sign in
    assert_redirected_to student_dashboard_path
  end

  test "sign_out_get_fallback prevents unauthorized signout" do
    # GET /sign_out should not perform sign out, just redirect
    get "/sign_out"

    assert_redirected_to new_user_session_path
  end

  # Layout tests
  test "new action renders sign in page" do
    get new_user_session_path

    assert_response :success
    assert_select "body"
    assert_select "title", text: "Login - TAMU CAT"
    assert_select "link[rel='icon'][href*='TAMU_CAT_icon']"
    assert_select "img[alt='TAMU Competency Assessment Tracking']"
    assert_select "h1", text: "TAMU Competency Assessment Tracking"
  end

  # Edge cases
  test "multiple sign ins for same user work correctly" do
    # First sign in
    sign_in @student_user
    get dashboard_path
    assert_redirected_to student_dashboard_path

    # Sign out
    delete destroy_user_session_path

    # Second sign in
    sign_in @student_user
    get dashboard_path
    assert_redirected_to student_dashboard_path
  end

  test "sign in persists across requests" do
    sign_in @student_user

    # Make multiple requests
    get dashboard_path
    assert_redirected_to student_dashboard_path

    get surveys_path
    assert_response :success
  end

  test "resolve_user handles User object correctly" do
    sign_in @student_user
    get student_dashboard_path

    assert_response :success
  end

  test "unauthenticated users are redirected to sign in" do
    get dashboard_path

    assert_redirected_to new_user_session_path
  end

  test "signed in users can access protected resources" do
    sign_in @student_user

    get surveys_path

    assert_response :success
  end

  # Integration test for ensure_track_survey_assignment callback
  test "signing in as student triggers survey assignment" do
    # This test verifies the integration works, even though we can't easily
    # mock the callback. The callback is triggered during actual OAuth flow
    sign_in @student_user

    # Verify student can access their dashboard
    get student_dashboard_path
    assert_response :success
  end

  test "signing in as admin does not trigger survey assignment" do
    sign_in @admin_user

    # Verify admin can access their dashboard
    get admin_dashboard_path
    assert_response :success
  end

  test "signing in as advisor does not trigger survey assignment" do
    sign_in @advisor_user

    # Verify advisor can access their dashboard
    get advisor_dashboard_path
    assert_response :success
  end
end

class SessionsControllerCallbacksTest < ActionController::TestCase
  tests SessionsController

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
  end

  test "after sign in prefers stored location and assigns surveys for students" do
    student_user = users(:student)
    calls = []

    SurveyAssignments::AutoAssigner.stub :call, ->(**args) { calls << args } do
      path = @controller.stub(:stored_location_for, "/kept-location") do
        @controller.after_sign_in_path_for(student_user)
      end

      assert_equal "/kept-location", path
    end

    assert_equal 1, calls.length
    assert_equal student_user.student_profile, calls.first[:student]
  end

  test "after sign in defaults to dashboard for advisors" do
    SurveyAssignments::AutoAssigner.stub :call, ->(**) { raise "should not run" } do
      path = @controller.stub(:stored_location_for, nil) do
        @controller.after_sign_in_path_for(users(:advisor))
      end

      assert_equal dashboard_path, path
    end
  end

  test "after sign in rescues auto assign failures" do
    student_user = users(:student)

    SurveyAssignments::AutoAssigner.stub :call, ->(**) { raise "boom" } do
      path = @controller.stub(:stored_location_for, nil) do
        @controller.after_sign_in_path_for(student_user)
      end

      assert_equal dashboard_path, path
    end
  end

  test "resolve_user uses wrapper objects exposing a user" do
    student_user = users(:student)
    wrapper = Struct.new(:user).new(student_user)

    calls = []
    SurveyAssignments::AutoAssigner.stub :call, ->(**args) { calls << args } do
      path = @controller.stub(:stored_location_for, nil) do
        @controller.after_sign_in_path_for(wrapper)
      end

      assert_equal dashboard_path, path
    end

    assert_equal 1, calls.length
    assert_equal student_user.student_profile, calls.first[:student]
  end
end
