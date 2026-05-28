require "test_helper"

class NotificationTest < ActiveSupport::TestCase
  include Rails.application.routes.url_helpers
  test "deliver! creates a single notification per user and notifiable" do
    user = users(:student)
    assignment = survey_assignments(:residential_assignment)

    first = Notification.deliver!(
      user: user,
      title: "New Survey Assigned",
      message: "Hello!",
      notifiable: assignment
    )

    second = Notification.deliver!(
      user: user,
      title: "New Survey Assigned",
      message: "Different message",
      notifiable: assignment
    )

    assert_equal first.id, second.id
    assert_equal "Different message", second.reload.message
  end

  test "mark_read! timestamps the record" do
    user = users(:student)
    notification = Notification.create!(
      user: user,
      title: "Reminder",
      message: "Complete your survey"
    )

    notification.mark_read!
    assert_not_nil notification.read_at
  end

  test "deliver! deduplicates by user and title when notifiable is missing" do
    user = users(:student)

    first = Notification.deliver!(user: user, title: "System", message: "Update")
    second = Notification.deliver!(user: user, title: "System", message: "Updated content")

    assert_equal first.id, second.id
    assert_equal "Updated content", user.notifications.find_by(title: "System").message
  end

  test "target_path_for returns survey response for completed student assignments" do
    user = users(:student)
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current)
    notification = Notification.create!(user: user, title: "Reminder", message: "Review", notifiable: assignment)

    expected_response = SurveyResponse.build(student: assignment.student, survey: assignment.survey)
    assert_equal survey_response_path(expected_response), notification.target_path_for(user)
  end

  test "target_path_for routes survey notifications by viewer role" do
    survey = surveys(:fall_2025)
    student = users(:student)
    advisor = users(:advisor)
    admin = users(:admin)
    notification = Notification.create!(user: student, title: "Survey Updated", message: "Review changes", notifiable: survey)

    assert_equal survey_path(survey), notification.target_path_for(student)
    assert_equal assignments_survey_path(survey), notification.target_path_for(advisor)
    assert_equal assignments_survey_path(survey), notification.target_path_for(admin)
  end

  test "target_path_for hides incomplete expired survey assignments from students" do
    user = users(:student)
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(available_until: 1.day.ago, completed_at: nil)
    notification = Notification.create!(user: user, title: "Survey Reminder", message: "Review", notifiable: assignment)

    assert_nil notification.target_path_for(user)
  end

  test "target_path_for still opens active incomplete survey assignments for students" do
    user = users(:student)
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(available_until: 1.day.from_now, completed_at: nil)
    notification = Notification.create!(user: user, title: "Survey Reminder", message: "Review", notifiable: assignment)

    assert_equal survey_path(assignment.survey), notification.target_path_for(user)
  end

  test "display_message hides assigner names for assigned survey notifications" do
    notification = Notification.new(
      title: "New Competency Survey Assigned",
      message: "Jack Buckley assigned the competency survey 'EMHA Final Competency Survey' to you."
    )

    assert_equal "You were assigned the competency survey 'EMHA Final Competency Survey'.", notification.display_message
    refute_includes notification.display_message, "Jack Buckley"
  end

  test "display_message hides remover names for unassigned survey notifications" do
    notification = Notification.new(
      title: "Survey Unassigned",
      message: "Tee Li removed 'RMHA Mid-point Competency Survey' from your assignments."
    )

    assert_equal "The survey 'RMHA Mid-point Competency Survey' was removed from your assignments.", notification.display_message
    refute_includes notification.display_message, "Tee Li"
  end

  test "display_message clarifies legacy survey update change logs" do
    notification = Notification.new(
      title: "Competency Survey Updated",
      message: "The competency survey 'RMHA Final Competency Survey' has been updated. Available until changed from '2026-01-01 00:00' to '2026-02-01 00:00'; No structural changes detected"
    )

    assert_includes notification.display_message, "The competency survey 'RMHA Final Competency Survey' was updated."
    assert_includes notification.display_message, "Due date changed from"
    assert_includes notification.display_message, "No question or structure changes were detected."
    refute_includes notification.display_message, "Available until"
  end
end
