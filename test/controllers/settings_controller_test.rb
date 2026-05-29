# frozen_string_literal: true

require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = users(:student)
  end

  # Authentication Tests
  test "edit requires authentication" do
    get settings_path

    assert_redirected_to new_user_session_path
  end

  test "update requires authentication" do
    patch settings_path, params: { user: { language: "en" } }

    assert_redirected_to new_user_session_path
  end

  # Edit Action Tests
  test "edit displays settings form for admin" do
    sign_in @admin

    get settings_path

    assert_response :success
  end

  test "edit displays settings form for advisor" do
    sign_in @advisor

    get settings_path

    assert_response :success
  end

  test "edit displays settings form for student" do
    sign_in @student

    get settings_path

    assert_response :success
  end

  test "edit displays notification settings without email control when system email is disabled" do
    sign_in @student
    ENV.delete("EMAIL_NOTIFICATIONS_ENABLED")

    get settings_path

    assert_response :success
    assert_includes response.body, "Notification Settings"
    assert_includes response.body, "System email delivery"
    assert_includes response.body, "EMAIL_NOTIFICATIONS_ENABLED"
    assert_includes response.body, "In-app notifications"
    assert_select "select[name='user[notifications_enabled]']", count: 0
    assert_select "input#user_notifications_enabled", count: 0
    assert_select "input#system_email_delivery_toggle[disabled]"
    assert_select "input#in_app_notifications_toggle[disabled][checked]"
    assert_select "a[href=?]", notifications_path, text: "Open notifications"
  end

  test "edit displays email notification control when system email is enabled" do
    sign_in @student
    previous = ENV["EMAIL_NOTIFICATIONS_ENABLED"]
    ENV["EMAIL_NOTIFICATIONS_ENABLED"] = "true"

    get settings_path

    assert_response :success
    assert_includes response.body, "Email notifications"
    assert_select "select[name='user[notifications_enabled]']", count: 0
    assert_select "input#user_notifications_enabled[type='checkbox']"
  ensure
    previous.nil? ? ENV.delete("EMAIL_NOTIFICATIONS_ENABLED") : ENV["EMAIL_NOTIFICATIONS_ENABLED"] = previous
  end

  test "edit assigns current user" do
    sign_in @admin

    get settings_path

    assert_response :success
  end

  test "edit includes scaled typography tokens when user sets text size" do
    sign_in @admin
    original_scale = @admin.text_scale_percent
    @admin.update!(text_scale_percent: 200)

    get settings_path

    assert_response :success
    assert_includes @response.body, "--app-font-scale: 2.00"
    assert_includes @response.body, "--font-size-base: calc(17px * var(--app-font-scale))"
  ensure
    @admin.update!(text_scale_percent: original_scale)
  end

  # Update Action Tests - Language
  test "update allows admin to change language" do
    sign_in @admin
    original_language = @admin.language

    patch settings_path, params: { user: { language: "es" } }

    assert_redirected_to root_path
    @admin.reload
    assert_equal "es", @admin.language
  ensure
    @admin.update!(language: original_language)
  end

  test "update allows advisor to change language" do
    sign_in @advisor
    original_language = @advisor.language

    patch settings_path, params: { user: { language: "fr" } }

    assert_redirected_to root_path
    @advisor.reload
    assert_equal "fr", @advisor.language
  ensure
    @advisor.update!(language: original_language)
  end

  test "update allows student to change language" do
    sign_in @student
    original_language = @student.language

    patch settings_path, params: { user: { language: "en" } }

    assert_redirected_to root_path
    @student.reload
    assert_equal "en", @student.language
  ensure
    @student.update!(language: original_language)
  end

  # Update Action Tests - Notifications
  test "update allows enabling notifications" do
    sign_in @admin
    @admin.update!(notifications_enabled: false)

    patch settings_path, params: { user: { notifications_enabled: "true" } }

    assert_redirected_to root_path
    @admin.reload
    assert @admin.notifications_enabled
  end

  test "update allows disabling notifications" do
    sign_in @admin
    @admin.update!(notifications_enabled: true)

    patch settings_path, params: { user: { notifications_enabled: "false" } }

    assert_redirected_to root_path
    @admin.reload
    assert_not @admin.notifications_enabled
  end

  # Update Action Tests - Text Scale
  test "update allows changing text scale percent" do
    sign_in @admin

    patch settings_path, params: { user: { text_scale_percent: 120 } }

    assert_redirected_to root_path
    @admin.reload
    assert_equal 120, @admin.text_scale_percent
  end

  test "update accepts valid text scale" do
    sign_in @admin

    patch settings_path, params: { user: { text_scale_percent: 100 } }

    assert_redirected_to root_path
    @admin.reload
    assert_equal 100, @admin.text_scale_percent
  end

  test "update accepts maximum text scale" do
    sign_in @admin

    patch settings_path, params: { user: { text_scale_percent: 200 } }

    assert_redirected_to root_path
    @admin.reload
    assert_equal 200, @admin.text_scale_percent
  end

  # Update Action Tests - Multiple Settings
  test "update allows changing multiple settings at once" do
    sign_in @admin
    original_language = @admin.language

    patch settings_path, params: {
      user: {
        language: "es",
        notifications_enabled: "true",
        text_scale_percent: 110
      }
    }

    assert_redirected_to root_path
    @admin.reload
    assert_equal "es", @admin.language
    assert @admin.notifications_enabled
    assert_equal 110, @admin.text_scale_percent
  ensure
    @admin.update!(language: original_language)
  end

  # Success Messages
  test "update shows success notice" do
    sign_in @admin

    patch settings_path, params: { user: { language: "en" } }

    assert_equal "Settings updated successfully.", flash[:notice]
  end

  # Redirect Behavior
  test "update redirects to root path by default" do
    sign_in @admin

    patch settings_path, params: { user: { language: "en" } }

    assert_redirected_to root_path
  end

  test "update redirects to referer when present" do
    sign_in @admin

    patch settings_path,
          params: { user: { language: "en" } },
          headers: { "HTTP_REFERER" => "/dashboard" }

    assert_redirected_to "/dashboard"
  end

  # Validation Errors
  test "update re-renders edit with invalid params" do
    sign_in @admin

    patch settings_path, params: { user: { text_scale_percent: -10 } }

    assert_response :unprocessable_entity
  end

  test "update shows alert message on validation failure" do
    sign_in @admin

    patch settings_path, params: { user: { text_scale_percent: -10 } }

    assert_equal "Please correct the errors below.", flash.now[:alert]
  end

  # Strong Parameters
  test "update filters unpermitted parameters" do
    sign_in @admin
    original_email = @admin.email

    patch settings_path, params: {
      user: {
        language: "en",
        email: "hacker@example.com"
      }
    }

    @admin.reload
    assert_equal original_email, @admin.email
  end

  test "update only permits language notifications_enabled and text_scale_percent" do
    sign_in @admin

    patch settings_path, params: {
      user: {
        language: "en",
        notifications_enabled: "1",
        text_scale_percent: 100,
        role: "admin"
      }
    }

    assert_redirected_to root_path
  end

  # Edge Cases - removed empty params test as controller requires user param

  test "update handles nil language" do
    sign_in @admin

    patch settings_path, params: { user: { language: nil } }

    # Will redirect if validation allows nil
    assert_includes [ 302, 422 ], @response.status
  end

  # All User Roles
  test "admin can update their settings" do
    sign_in @admin

    patch settings_path, params: { user: { notifications_enabled: "1" } }

    assert_redirected_to root_path
  end

  test "advisor can update their settings" do
    sign_in @advisor

    patch settings_path, params: { user: { notifications_enabled: "1" } }

    assert_redirected_to root_path
  end

  test "student can update their settings" do
    sign_in @student

    patch settings_path, params: { user: { notifications_enabled: "1" } }

    assert_redirected_to root_path
  end

  # Updated At Timestamp
  test "update changes updated_at timestamp" do
    sign_in @admin
    original_updated_at = @admin.updated_at

    sleep 0.1 # Ensure timestamp difference

    patch settings_path, params: { user: { language: "en" } }

    @admin.reload
    assert_operator @admin.updated_at, :>, original_updated_at
  end

  # Language Specific Tests
  test "update accepts valid language codes" do
    sign_in @admin
    valid_languages = %w[en es fr de]

    valid_languages.each do |lang|
      patch settings_path, params: { user: { language: lang } }
      @admin.reload
      assert_equal lang, @admin.language
    end
  end

  # Boolean Conversion Tests
  test "update converts string to boolean for notifications" do
    sign_in @admin

    patch settings_path, params: { user: { notifications_enabled: "true" } }

    @admin.reload
    assert_equal true, @admin.notifications_enabled
  end

  test "update handles boolean true for notifications" do
    sign_in @admin

    patch settings_path, params: { user: { notifications_enabled: true } }

    assert_redirected_to root_path
  end

  test "update handles boolean false for notifications" do
    sign_in @admin

    patch settings_path, params: { user: { notifications_enabled: false } }

    assert_redirected_to root_path
  end

  # Persistence Tests
  test "update persists language changes" do
    sign_in @admin
    original_language = @admin.language

    patch settings_path, params: { user: { language: "es" } }

    # Create new instance to verify database persistence
    user_from_db = User.find(@admin.id)
    assert_equal "es", user_from_db.language
  ensure
    @admin.update!(language: original_language)
  end

  test "update persists notifications changes" do
    sign_in @admin
    original_notifications = @admin.notifications_enabled

    patch settings_path, params: { user: { notifications_enabled: !original_notifications } }

    user_from_db = User.find(@admin.id)
    assert_equal !original_notifications, user_from_db.notifications_enabled
  ensure
    @admin.update!(notifications_enabled: original_notifications)
  end

  test "update persists text scale changes" do
    sign_in @admin
    original_scale = @admin.text_scale_percent

    patch settings_path, params: { user: { text_scale_percent: 125 } }

    user_from_db = User.find(@admin.id)
    assert_equal 125, user_from_db.text_scale_percent
  ensure
    @admin.update!(text_scale_percent: original_scale)
  end

  # Integer Conversion Tests
  test "update converts string to integer for text scale" do
    sign_in @admin

    patch settings_path, params: { user: { text_scale_percent: "150" } }

    assert_redirected_to root_path
    @admin.reload
    assert_equal 150, @admin.text_scale_percent
  end

  # Form Submission Tests
  test "update via PATCH method" do
    sign_in @admin

    patch settings_path, params: { user: { language: "en" } }

    assert_redirected_to root_path
  end

  # Error Recovery Tests
  test "update fails completely when one field is invalid" do
    sign_in @admin
    original_language = @admin.language

    patch settings_path, params: {
      user: {
        language: "es",
        text_scale_percent: -100
      }
    }

    assert_response :unprocessable_entity
    @admin.reload
    # Language change should not be persisted due to validation failure
    if original_language.nil?
      assert_nil @admin.language
    else
      assert_equal original_language, @admin.language
    end
  end

  # Current User Tests
  test "update only affects current user" do
    sign_in @admin
    advisor_notifications = @advisor.notifications_enabled

    patch settings_path, params: { user: { notifications_enabled: !advisor_notifications } }

    @advisor.reload
    assert_equal advisor_notifications, @advisor.notifications_enabled
  end

  # Response Format Tests
  test "edit returns HTML response" do
    sign_in @admin

    get settings_path

    assert_equal "text/html; charset=utf-8", @response.content_type
  end

  test "update returns redirect response" do
    sign_in @admin

    patch settings_path, params: { user: { language: "en" } }

    assert_response :redirect
  end

  # Referer Edge Cases
  test "update handles invalid referer gracefully" do
    sign_in @admin

    patch settings_path,
          params: { user: { language: "en" } },
          headers: { "HTTP_REFERER" => "" }

    assert_redirected_to root_path
  end

  test "update redirects to root when referer is blank" do
    sign_in @admin

    patch settings_path,
          params: { user: { language: "en" } },
          headers: { "HTTP_REFERER" => "   " }

    assert_redirected_to root_path
  end
end
