require "test_helper"
require "nokogiri"

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:student)
    @advisor = users(:advisor)
    @student_notification = notifications(:student_unread)
    @advisor_notification = notifications(:advisor_notice)
  end

  test "index lists only current user's notifications" do
    sign_in @student
    assert_nil @student_notification.read_at

    get notifications_path

    assert_response :success
    assert_includes response.body, @student_notification.title
    refute_includes response.body, @advisor_notification.title
    assert_select "table.c-table"
    assert_select "th", text: "Notification"
    assert_select "th", text: "Received"
    assert_select "th", text: "Related", count: 0
    assert_not_nil @student_notification.reload.read_at
    assert_select ".c-status-badge", text: "Read"
  end

  test "index displays cleaned notification copy" do
    sign_in @student
    Notification.create!(
      user: @student,
      title: "New Competency Survey Assigned",
      message: "Jack Buckley assigned the competency survey 'EMHA Final Competency Survey' to you."
    )

    get notifications_path

    assert_response :success
    assert_includes response.body, "You were assigned the competency survey"
    assert_includes response.body, "EMHA Final Competency Survey"
    refute_includes response.body, "Jack Buckley assigned"
  end

  test "advisor can use the notification center" do
    sign_in @advisor

    get notifications_path

    assert_response :success
    assert_includes response.body, @advisor_notification.title
  end

  test "admin can use the notification center" do
    admin = users(:admin)
    Notification.create!(user: admin, title: "Admin notice", message: "A system workflow needs attention.")
    sign_in admin

    get notifications_path

    assert_response :success
    assert_includes response.body, "Admin notice"
  end

  test "navbar notification menu shows capped unread notifications only" do
    sign_in @student

    Notification.delete_all
    6.times do |index|
      Notification.create!(
        user: @student,
        title: "Unread nav #{index}",
        message: "Unread nav message #{index}.",
        created_at: index.minutes.ago
      )
    end
    Notification.create!(
      user: @student,
      title: "Read nav item",
      message: "This should not appear in the nav menu.",
      read_at: Time.current,
      created_at: Time.current
    )

    get student_dashboard_path

    assert_response :success
    menu = Nokogiri::HTML.parse(response.body).at_css(".notifications-menu.u-hover-dropdown")
    assert_not_nil menu
    assert_equal "true", menu["data-click-pins"]
    assert_equal "button", menu.at_css(".c-icon-button")&.name
    assert_equal ApplicationController::NAV_NOTIFICATION_LIMIT, menu.css(".c-menu__item-wrap").size
    assert_includes menu.text, "Unread Notifications"
    assert_includes menu.text, "Showing 5 of 6 unread."
    refute_includes menu.text, "Read nav item"
  end

  test "index renders open only for still-open survey notifications" do
    sign_in @student
    Notification.delete_all

    open_assignment = survey_assignments(:residential_assignment)
    open_assignment.update!(available_until: 2.days.from_now, completed_at: nil)
    expired_assignment = SurveyAssignment.create!(
      survey: surveys(:spring_2025),
      student: students(:student),
      advisor: advisors(:advisor),
      assigned_at: 3.days.ago,
      available_until: 1.day.ago
    )

    Notification.create!(
      user: @student,
      title: "Open survey notice",
      message: "This survey can still be completed.",
      notifiable: open_assignment
    )
    expired_notification = Notification.create!(
      user: @student,
      title: "Expired survey notice",
      message: "This survey has closed.",
      notifiable: expired_assignment
    )

    get notifications_path

    assert_response :success
    document = Nokogiri::HTML.parse(response.body)
    open_row = document.css("tbody tr").find { |row| row.text.include?("Open survey notice") }
    expired_row = document.css("tbody tr").find { |row| row.text.include?("Expired survey notice") }

    assert_not_nil open_row
    assert_not_nil expired_row
    assert_includes open_row.css("a").map(&:text).map(&:strip), "Open"
    refute_includes expired_row.css("a").map(&:text).map(&:strip), "Open"
    assert_includes expired_row.text, "Read"
    assert_not_nil expired_notification.reload.read_at
  end

  test "show marks the owner's notification as read" do
    sign_in @student
    assert_nil @student_notification.read_at

    get notification_path(@student_notification)
    expected_target = @student_notification.target_path_for(@student) || notifications_path
    assert_redirected_to expected_target
    assert_not_nil @student_notification.reload.read_at
  end

  test "show marks expired survey notifications read without opening the survey" do
    sign_in @student
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(available_until: 1.day.ago, completed_at: nil)
    notification = Notification.create!(
      user: @student,
      title: "Expired survey notice",
      message: "This survey has closed.",
      notifiable: assignment
    )

    get notification_path(notification)

    assert_redirected_to notifications_path
    assert_not_nil notification.reload.read_at
  end

  test "show responds 404 when accessing another user's notification" do
    sign_in @student

    get notification_path(@advisor_notification)
    assert_response :not_found
  end

  test "update marks notification as read and redirects back" do
    sign_in @student

    patch notification_path(@student_notification), headers: { "HTTP_REFERER" => notifications_url }
    assert_redirected_to notifications_path
    assert @student_notification.reload.read_at.present?, "expected notification to be marked read"
  end

  test "mark all read clears unread count" do
    sign_in @student

    patch mark_all_read_notifications_path, headers: { "HTTP_REFERER" => notifications_url }

    assert_redirected_to notifications_path
    assert_equal 0, @student.notifications.unread.count
  end
end
