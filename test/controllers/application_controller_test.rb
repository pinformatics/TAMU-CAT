require "test_helper"

class ApplicationControllerTest < ActiveSupport::TestCase
  test "current_student memoizes the student's profile" do
    controller = ApplicationController.new
    user = users(:student)

    controller.singleton_class.define_method(:current_user) { user }
    first = controller.send(:current_student)
    second = controller.send(:current_student)

    assert_same first, second
    assert_equal students(:student), first
  ensure
    controller.singleton_class.send(:remove_method, :current_user)
  end

  test "current_advisor_profile memoizes advisor profile" do
    controller = ApplicationController.new
    user = users(:advisor)

    controller.singleton_class.define_method(:current_user) { user }
    first = controller.send(:current_advisor_profile)
    second = controller.send(:current_advisor_profile)

    assert_same first, second
    assert_equal advisors(:advisor), first
  ensure
    controller.singleton_class.send(:remove_method, :current_user)
  end

  test "load_notification_state sets unread counts and unread nav notifications" do
    controller = ApplicationController.new
    user = users(:student)
    Notification.create!(user: user, title: "Read nav item", message: "Should stay out of the nav menu.", read_at: Time.current)

    controller.singleton_class.define_method(:current_user) { user }
    controller.send(:load_notification_state)

    assert_equal user.notifications.unread.count, controller.instance_variable_get(:@unread_notification_count)
    recent_notifications = controller.instance_variable_get(:@recent_notifications)
    assert_equal ApplicationController::NAV_NOTIFICATION_LIMIT, recent_notifications.limit_value
    assert_equal ApplicationController::NAV_NOTIFICATION_LIMIT, controller.instance_variable_get(:@notification_menu_limit)
    assert recent_notifications.to_a.all? { |notification| !notification.read? }
  ensure
    controller.singleton_class.send(:remove_method, :current_user)
  end

  test "fallback semester label returns formatted timestamp" do
    controller = ApplicationController.new
    label = controller.send(:fallback_semester_label)

    assert_match(/\A[A-Z][a-z]+ \d{4}\z/, label)
  end
end
