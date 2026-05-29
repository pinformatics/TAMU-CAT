require "test_helper"

class NotificationEmailDeliveryJobTest < ActiveJob::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
    @user = users(:student)
    @notification = Notification.deliver!(
      user: @user,
      title: "Email Delivery Test",
      message: "This is a notification email test."
    )
  end

  teardown do
    ActionMailer::Base.deliveries.clear
    ENV.delete("EMAIL_NOTIFICATIONS_ENABLED")
  end

  test "delivers notification email when user notifications are enabled" do
    with_email_notifications_enabled do
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        NotificationEmailDeliveryJob.perform_now(notification_id: @notification.id)
      end

      email = ActionMailer::Base.deliveries.last
      assert_equal [ @user.email ], email.to
      assert_equal "Email Delivery Test", email.subject
      assert_match "This is a notification email test.", email.text_part.body.to_s
    end
  end

  test "skips email when app email notification flag is disabled" do
    ENV.delete("EMAIL_NOTIFICATIONS_ENABLED")

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      NotificationEmailDeliveryJob.perform_now(notification_id: @notification.id)
    end
  end

  test "skips email when user notifications are disabled" do
    @user.update!(notifications_enabled: false)

    with_email_notifications_enabled do
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        NotificationEmailDeliveryJob.perform_now(notification_id: @notification.id)
      end
    end
  end

  private

  def with_email_notifications_enabled
    previous = ENV["EMAIL_NOTIFICATIONS_ENABLED"]
    ENV["EMAIL_NOTIFICATIONS_ENABLED"] = "true"
    yield
  ensure
    previous.nil? ? ENV.delete("EMAIL_NOTIFICATIONS_ENABLED") : ENV["EMAIL_NOTIFICATIONS_ENABLED"] = previous
  end
end
