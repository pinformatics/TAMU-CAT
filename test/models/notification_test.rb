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

  test "deliver! deduplicates by stable dedupe key when present" do
    user = users(:student)
    assignment = survey_assignments(:residential_assignment)

    first = Notification.deliver!(
      user: user,
      event_key: "feedback.submitted",
      dedupe_key: "feedback:student:#{assignment.student_id}:survey:#{assignment.survey_id}",
      title: "Advisor Feedback Submitted",
      message: "Original",
      notifiable: assignment,
      metadata: { kind: "submitted", survey_id: assignment.survey_id }
    )

    second = Notification.deliver!(
      user: user,
      event_key: "feedback.revised",
      dedupe_key: "feedback:student:#{assignment.student_id}:survey:#{assignment.survey_id}",
      title: "Advisor Feedback Revised",
      message: "Updated",
      notifiable: assignment,
      metadata: { kind: "revised", survey_id: assignment.survey_id }
    )

    assert_equal first.id, second.id
    second.reload
    assert_equal "Advisor Feedback Revised", second.title
    assert_equal "feedback.revised", second.event_key
    assert_equal "Updated", second.message
    assert_equal "revised", second.metadata["kind"]
  end

  test "deliver! allows same title and notifiable when dedupe keys differ" do
    user = users(:student)
    assignment = survey_assignments(:residential_assignment)

    assert_difference -> { Notification.count }, 2 do
      Notification.deliver!(
        user: user,
        event_key: "qa.one",
        dedupe_key: "qa:one",
        title: "Shared Title",
        message: "First",
        notifiable: assignment
      )
      Notification.deliver!(
        user: user,
        event_key: "qa.two",
        dedupe_key: "qa:two",
        title: "Shared Title",
        message: "Second",
        notifiable: assignment
      )
    end
  end

  test "deliver! refreshes reused read notifications as unread and recent" do
    user = users(:student)
    survey = surveys(:fall_2025)
    notification = Notification.deliver!(
      user: user,
      title: "Survey Unassigned",
      message: "The survey '#{survey.title}' was removed from your assignments.",
      notifiable: survey
    )
    notification.update!(read_at: 2.days.ago, created_at: 2.days.ago, updated_at: 2.days.ago)

    assert_no_difference "Notification.count" do
      Notification.deliver!(
        user: user,
        title: "Survey Unassigned",
        message: "The survey '#{survey.title}' was removed from your assignments again.",
        notifiable: survey
      )
    end

    notification.reload
    assert_nil notification.read_at
    assert_equal "The survey '#{survey.title}' was removed from your assignments again.", notification.message
    assert_equal notification, user.notifications.recent.first
  end

  test "deliver! keeps notifications read when in app notifications are disabled" do
    user = users(:student)
    user.notifications.delete_all
    user.update!(in_app_notifications_enabled: false)

    notification = Notification.deliver!(
      user: user,
      title: "Muted notice",
      message: "This should not become an unread in-app alert."
    )

    assert notification.read?
    assert_equal 0, user.notifications.unread.count
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

  test "target_path_for routes assignment notifications to advisor and admin assignment pages" do
    assignment = survey_assignments(:residential_assignment)
    notification = Notification.create!(user: users(:advisor), title: "Survey", message: "Open", notifiable: assignment)

    assert_equal assignments_survey_path(assignment.survey_id), notification.target_path_for(users(:advisor))
    assert_equal assignments_survey_path(assignment.survey_id), notification.target_path_for(users(:admin))
  end

  test "display_message hides assigner names for assigned survey notifications" do
    notification = Notification.new(
      title: "New Competency Survey Assigned",
      message: "Jack Buckley assigned the competency survey 'EMHA Final Competency Survey' to you."
    )

    assert_equal "You were assigned the competency survey 'EMHA Final Competency Survey'.", notification.display_message
    refute_includes notification.display_message, "Jack Buckley"
  end

  test "display_message prefers notifiable survey titles when available" do
    survey = surveys(:fall_2025)
    assignment = survey_assignments(:residential_assignment)

    assigned = Notification.new(
      title: "New Competency Survey Assigned",
      message: "Someone assigned a survey.",
      notifiable: survey
    )
    unassigned = Notification.new(
      title: "Survey Unassigned",
      message: "Someone removed a survey.",
      notifiable: assignment
    )

    assert_equal "You were assigned the competency survey '#{survey.title}'.", assigned.display_message
    assert_equal "The survey '#{assignment.survey.title}' was removed from your assignments.", unassigned.display_message
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

  test "display_message normalizes active status and preserves finished update sentences" do
    notification = Notification.new(
      title: "Competency Survey Updated",
      message: "The competency survey 'RMHA Final Competency Survey' was updated. Is active changed from 'true' to 'false'; Review window changed."
    )

    assert_includes notification.display_message, "Status changed from active to archived."
    assert_includes notification.display_message, "Review window changed."
  end

  test "target_path_for routes program semester notifications by role" do
    semester = program_semesters(:fall_2025)
    notification = Notification.create!(user: users(:admin), title: "Semester", message: "Released", notifiable: semester)

    assert_equal reports_path, notification.target_path_for(nil)
    assert_equal student_competencies_path, notification.target_path_for(users(:student))
    assert_equal reports_path, notification.target_path_for(users(:advisor))
    assert_equal reports_path, notification.target_path_for(users(:admin))
  end

  test "target_path_for routes grade import batch notifications for staff only" do
    batch = GradeImportBatch.create!(
      uploaded_by: users(:admin),
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )
    notification = Notification.create!(user: users(:admin), title: "Import", message: "Ready", notifiable: batch)

    assert_nil notification.target_path_for(nil)
    assert_nil notification.target_path_for(users(:student))
    assert_equal reports_path(report_tab: "course_target", course_program_semester_id: batch.program_semester_id), notification.target_path_for(users(:advisor))
    assert_equal admin_grade_import_batch_path(batch), notification.target_path_for(users(:admin))
  end

  test "target_path_for routes question and feedback notifiables" do
    question = questions(:fall_q1)
    feedback = feedbacks(:advisor_feedback)

    question_notification = Notification.create!(user: users(:admin), title: "Question", message: "Updated", notifiable: question)
    feedback_notification = Notification.create!(user: users(:admin), title: "Feedback", message: "Updated", notifiable: feedback)

    assert_equal question_path(question), question_notification.target_path_for(users(:admin))
    assert_equal feedback_path(feedback), feedback_notification.target_path_for(users(:admin))
  end

  test "target_path_for returns nil for unknown notifiable and survey without viewer or assignment" do
    unknown = Notification.create!(
      user: users(:admin),
      title: "Unknown",
      message: "Unknown target",
      notifiable: users(:advisor)
    )
    assert_nil unknown.target_path_for(users(:admin))

    survey = surveys(:spring_2025)
    survey_notification = Notification.create!(
      user: users(:student),
      title: "Survey",
      message: "Open survey",
      notifiable: survey
    )

    assert_nil survey_notification.target_path_for(nil)
    assert_nil survey_notification.target_path_for(users(:student))
  end

  test "display_message falls back when survey title is missing" do
    assigned = Notification.new(title: "New Competency Survey Assigned", message: "Assigned without a title.")
    unassigned = Notification.new(title: "Survey Unassigned", message: "Removed without a title.")
    updated = Notification.new(title: "Competency Survey Updated", message: "No structural changes detected")

    assert_equal "You were assigned a competency survey.", assigned.display_message
    assert_equal "A survey was removed from your assignments.", unassigned.display_message
    assert_equal "A competency survey was updated. No question or structure changes were detected.", updated.display_message
  end

  test "display_message handles assignment without survey and blank update summaries" do
    assignment_without_survey = SurveyAssignment.new
    assigned = Notification.new(
      title: "New Competency Survey Assigned",
      message: "Assignment changed.",
      notifiable: assignment_without_survey
    )
    updated = Notification.new(
      title: "Competency Survey Updated",
      message: "The competency survey 'RMHA Final Competency Survey' was updated. "
    )

    assert_equal "You were assigned a competency survey.", assigned.display_message
    assert_equal "The competency survey 'RMHA Final Competency Survey' was updated.", updated.display_message
  end

  test "survey update segment normalization covers blank invalid dates and custom attributes" do
    notification = Notification.new(
      title: "Competency Survey Updated",
      message: "Available from changed from '' to 'bad-date'; Custom field changed from 'old' to 'new'; "
    )

    assert_nil notification.send(:normalize_update_segment, " ")
    assert_equal "Open date changed from not set to bad-date.", notification.send(:normalize_update_segment, "Available from changed from '' to 'bad-date'")
    assert_equal "Custom field changed from old to new.", notification.send(:normalize_update_segment, "Custom field changed from 'old' to 'new'")
    assert_equal "Already complete.", notification.send(:normalize_update_segment, "Already complete.")
    assert_equal "Needs punctuation.", notification.send(:normalize_update_segment, "Needs punctuation")
  end

  test "student assignment target path handles inactive missing and unavailable assignments" do
    notification = Notification.new
    inactive = survey_assignments(:residential_assignment)
    inactive.survey.update_column(:is_active, false)
    inactive.update!(completed_at: nil, available_until: 1.day.from_now)

    assert_nil notification.send(:student_assignment_target_path, inactive)
    assert_nil notification.send(:student_assignment_target_path, SurveyAssignment.new(completed_at: Time.current))
    assert_nil notification.send(:survey_response_path_for_assignment, SurveyAssignment.new(completed_at: Time.current))
  ensure
    inactive&.survey&.update_column(:is_active, true)
  end
end
