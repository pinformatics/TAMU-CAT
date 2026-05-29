# frozen_string_literal: true

require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = users(:student)
  end

  # About page tests
  test "about page is accessible without authentication" do
    get about_path

    assert_response :success
  end

  test "about page renders successfully" do
    get about_path

    assert_response :success
    assert_not_nil @response.body
  end

  test "about page accessible by admin" do
    sign_in @admin

    get about_path

    assert_response :success
  end

  test "about page accessible by advisor" do
    sign_in @advisor

    get about_path

    assert_response :success
  end

  test "about page accessible by student" do
    sign_in @student

    get about_path

    assert_response :success
  end

  test "about page returns HTML content" do
    get about_path

    assert_response :success
    assert_equal "text/html; charset=utf-8", @response.content_type
  end

  test "about page does not redirect" do
    get about_path

    assert_response :success
    assert_not @response.redirect?
  end

  test "about action exists and is callable" do
    assert_nothing_raised do
      get about_path
    end
  end

  # FAQ page tests
  test "faq page is accessible without authentication" do
    get faq_path

    assert_response :success
  end

  test "faq page renders successfully" do
    get faq_path

    assert_response :success
    assert_not_nil @response.body
  end

  test "faq page accessible by admin" do
    sign_in @admin

    get faq_path

    assert_response :success
  end

  test "faq page accessible by advisor" do
    sign_in @advisor

    get faq_path

    assert_response :success
  end

  test "faq page accessible by student" do
    sign_in @student

    get faq_path

    assert_response :success
  end

  test "faq page returns HTML content" do
    get faq_path

    assert_response :success
    assert_equal "text/html; charset=utf-8", @response.content_type
  end

  test "faq page does not redirect" do
    get faq_path

    assert_response :success
    assert_not @response.redirect?
  end

  test "faq page includes workflow and export guidance" do
    get faq_path

    assert_response :success
    assert_includes response.body, "How do notifications work?"
    assert_includes response.body, "What should advisors use first?"
    assert_includes response.body, "What is the Reports page for?"
    assert_includes response.body, "Why might program targets differ by semester?"
    assert_includes response.body, "Which exports contain student-level data?"
    assert_includes response.body, "What should I do if a Google Translate box gets stuck loading?"
  end

  # Maintenance page tests
  test "maintenance page returns service unavailable" do
    get maintenance_path

    assert_response :service_unavailable
  end

  test "faq action exists and is callable" do
    assert_nothing_raised do
      get faq_path
    end
  end

  # Authentication bypass tests
  test "about page skips authentication requirement" do
    # Verify page loads without being redirected to sign-in
    get about_path

    assert_response :success
    # Should successfully render the page, not redirect
    assert_not @response.redirect?
  end

  test "faq page skips authentication requirement" do
    # Verify page loads without being redirected to sign-in
    get faq_path

    assert_response :success
    # Should successfully render the page, not redirect
    assert_not @response.redirect?
  end

  # Cross-role access verification
  test "all roles can access about page" do
    # Unauthenticated
    get about_path
    assert_response :success

    # Student
    sign_in @student
    get about_path
    assert_response :success
    sign_out @student

    # Advisor
    sign_in @advisor
    get about_path
    assert_response :success
    sign_out @advisor

    # Admin
    sign_in @admin
    get about_path
    assert_response :success
  end

  test "all roles can access faq page" do
    # Unauthenticated
    get faq_path
    assert_response :success

    # Student
    sign_in @student
    get faq_path
    assert_response :success
    sign_out @student

    # Advisor
    sign_in @advisor
    get faq_path
    assert_response :success
    sign_out @advisor

    # Admin
    sign_in @admin
    get faq_path
    assert_response :success
  end

  # HTTP method tests
  test "about responds to GET request" do
    get about_path

    assert_response :success
  end

  test "faq responds to GET request" do
    get faq_path

    assert_response :success
  end

  # Response body tests
  test "about page has content" do
    get about_path

    assert_response :success
    assert @response.body.length > 0, "About page should have content"
  end

  test "faq page has content" do
    get faq_path

    assert_response :success
    assert @response.body.length > 0, "FAQ page should have content"
  end

  # Multiple request tests
  test "about page can be requested multiple times" do
    3.times do
      get about_path
      assert_response :success
    end
  end

  test "faq page can be requested multiple times" do
    3.times do
      get faq_path
      assert_response :success
    end
  end

  # Authentication state persistence tests
  test "about page does not require session" do
    get about_path

    assert_response :success
       # Page should work without any session data
  end

  test "faq page does not require session" do
    get faq_path

    assert_response :success
       # Page should work without any session data
  end

  # Edge case tests
  test "about page works after sign out" do
    sign_in @student
    sign_out @student

    get about_path

    assert_response :success
  end

  test "faq page works after sign out" do
    sign_in @student
    sign_out @student

    get faq_path

    assert_response :success
  end

  test "about page accessible from different user transitions" do
    # Access as unauthenticated
    get about_path
    assert_response :success

    # Sign in as student
    sign_in @student
    get about_path
    assert_response :success

    # Switch to admin
    sign_out @student
    sign_in @admin
    get about_path
    assert_response :success
  end

  test "faq page accessible from different user transitions" do
    # Access as unauthenticated
    get faq_path
    assert_response :success

    # Sign in as advisor
    sign_in @advisor
    get faq_path
    assert_response :success

    # Switch to student
    sign_out @advisor
    sign_in @student
    get faq_path
    assert_response :success
  end

  # Controller action tests
  test "about action does not raise errors" do
    assert_nothing_raised do
      get about_path
    end
  end

  test "faq action does not raise errors" do
    assert_nothing_raised do
      get faq_path
    end
  end

  # Status code verification
  test "about returns 200 status code" do
    get about_path

    assert_equal 200, @response.status
  end

  test "faq returns 200 status code" do
    get faq_path

    assert_equal 200, @response.status
  end

  # Template rendering tests (implicit)
  test "about action renders without error" do
    get about_path

    assert_response :success
       # If template is missing, would get 500 or error
  end

  test "faq action renders without error" do
    get faq_path

    assert_response :success
       # If template is missing, would get 500 or error
  end

  # Public access verification
  test "about is publicly accessible" do
    # Ensure no authentication cookies
    reset!

    get about_path

    assert_response :success
  end

  test "faq is publicly accessible" do
    # Ensure no authentication cookies
    reset!

    get faq_path

    assert_response :success
  end

  # Content type tests
  test "about serves HTML content type" do
    get about_path

    assert_match(/text\/html/, @response.content_type)
  end

  test "faq serves HTML content type" do
    get faq_path

    assert_match(/text\/html/, @response.content_type)
  end

  # No authentication redirect tests
  test "about does not redirect to sign in" do
    get about_path

    assert_response :success
    assert_not_equal new_user_session_path, @response.redirect_url
  end

  test "faq does not redirect to sign in" do
    get faq_path

    assert_response :success
    assert_not_equal new_user_session_path, @response.redirect_url
  end

  # Concurrent access tests (simulated)
  test "about handles sequential requests from different users" do
    get about_path
    assert_response :success

    sign_in @student
    get about_path
    assert_response :success

    sign_out @student
    get about_path
    assert_response :success
  end

  test "faq handles sequential requests from different users" do
    get faq_path
    assert_response :success

    sign_in @admin
    get faq_path
    assert_response :success

    sign_out @admin
    get faq_path
    assert_response :success
  end

  # Response validation tests
  test "about response is valid" do
    get about_path

    assert_response :success
    assert @response.body.present?
    assert_equal "text/html; charset=utf-8", @response.content_type
  end

  test "faq response is valid" do
    get faq_path

    assert_response :success
    assert @response.body.present?
    assert_equal "text/html; charset=utf-8", @response.content_type
  end
end
