require "test_helper"
require "securerandom"
require "set"

class SurveyNotificationJobTest < ActiveJob::TestCase
  setup do
    SurveyNotificationJob.assignment_scope = SurveyAssignment
    @assignment = survey_assignments(:residential_assignment)
    @survey = surveys(:fall_2025)
    @question = questions(:fall_q1)
    @student = students(:student)
    @advisor = advisors(:advisor)
  end

  teardown do
    SurveyNotificationJob.assignment_scope = SurveyAssignment
  end

  # Test :assigned event
  test "assigned event delivers notification to student" do
    assert_difference -> { Notification.count }, 1 do
      SurveyNotificationJob.perform_now(event: :assigned, survey_assignment_id: @assignment.id)
    end

    notification = Notification.last
    assert_equal @assignment.student.user, notification.user
    assert_equal "New Competency Survey Assigned", notification.title
    assert_equal "You were assigned the competency survey '#{@assignment.survey.title}'.", notification.message
  end

  test "assigned event does not include advisor name in message" do
    SurveyNotificationJob.perform_now(event: :assigned, survey_assignment_id: @assignment.id)

    notification = Notification.last
    advisor_name = @assignment.advisor.user.display_name
    refute_match advisor_name, notification.message
  end

  test "assigned event handles missing advisor gracefully" do
    assignment_without_advisor = create_assignment_for(
      survey: @survey,
      advisor: nil,
      assigned_at: 2.days.ago,
      available_until: 3.days.from_now
    )

    assert_difference -> { Notification.count }, 1 do
      SurveyNotificationJob.perform_now(event: :assigned, survey_assignment_id: assignment_without_advisor.id)
    end

    notification = Notification.last
    assert_equal "You were assigned the competency survey '#{assignment_without_advisor.survey.title}'.", notification.message
  end

  # Test :response_submitted event
  test "response submitted event thanks student" do
    assert_difference -> { Notification.count }, 1 do
      SurveyNotificationJob.perform_now(event: :response_submitted, survey_assignment_id: @assignment.id)
    end

    notification = Notification.last
    assert_equal @assignment.student.user, notification.user
    assert_equal "Competency Survey Submitted", notification.title
    assert_match @assignment.survey.title, notification.message
  end

  test "response submitted event does not notify if no student user" do
    fake_assignment = FakeAssignmentRecord.new(
      @assignment.id,
      @assignment.survey,
      @assignment.survey_id,
      nil,
      nil,
      nil,
      nil
    )

    with_assignment_scope([ fake_assignment ]) do
      assert_no_difference -> { Notification.count } do
        SurveyNotificationJob.perform_now(event: :response_submitted, survey_assignment_id: @assignment.id)
      end
    end
  end

  # Test :feedback_received event
  test "feedback received event notifies student" do
    feedback = feedbacks(:advisor_feedback)

    assert_difference -> { Notification.count }, 1 do
      SurveyNotificationJob.perform_now(event: :feedback_received, feedback_id: feedback.id)
    end

    notification = Notification.last
    assert_equal @assignment.student.user, notification.user
    assert_equal "Advisor Feedback Received", notification.title
    assert_match @assignment.survey.title, notification.message
    assert_match @assignment.advisor.user.display_name, notification.message
  end

  test "feedback received event skips when assignment missing" do
    feedback = feedbacks(:advisor_feedback)
    SurveyAssignment.where(student_id: feedback.student_id, survey_id: feedback.survey_id).delete_all

    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: :feedback_received, feedback_id: feedback.id)
    end
  end

  test "feedback received event skips when feedback is draft" do
    feedback = feedbacks(:advisor_feedback)
    AdvisorFeedbackSubmission.where(
      student_id: feedback.student_id,
      survey_id: feedback.survey_id,
      advisor_id: feedback.advisor_id
    ).delete_all

    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: :feedback_received, feedback_id: feedback.id)
    end
  end

  # Test :student_revised_after_feedback event
  test "student revised after feedback notifies advisor and admins" do
    assert User.admins.exists?

    expected_recipients = 1 + User.admins.count

    assert_difference -> { Notification.count }, expected_recipients do
      SurveyNotificationJob.perform_now(event: :student_revised_after_feedback, survey_assignment_id: @assignment.id)
    end

    notifications = Notification.last(expected_recipients)
    recipients = notifications.map(&:user)

    assert_includes recipients, @assignment.advisor.user
    User.admins.find_each { |admin_user| assert_includes recipients, admin_user }

    notifications.each do |notification|
      assert_equal "Competency Survey Updated After Feedback", notification.title
      assert_match @assignment.student.full_name, notification.message
      assert_match @assignment.survey.title, notification.message
    end
  end

  test "student revised after feedback skips when no feedback exists" do
    Feedback.where(student_id: @assignment.student_id, survey_id: @assignment.survey_id).delete_all

    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: :student_revised_after_feedback, survey_assignment_id: @assignment.id)
    end
  end

  # Test :due_soon event
  test "due soon event notifies student about upcoming deadline" do
    @assignment.update!(available_until: 3.days.from_now)

    assert_difference -> { Notification.count }, 1 do
      assert_enqueued_jobs 1, only: NotificationEmailDeliveryJob do
        SurveyNotificationJob.perform_now(event: :due_soon, survey_assignment_id: @assignment.id)
      end
    end

    notification = Notification.last
    assert_equal @assignment.student.user, notification.user
    assert_equal "Competency Survey Closing Soon", notification.title
    assert_match @assignment.survey.title, notification.message
    assert_match /closes in/, notification.message
  end

  test "due soon event skips completed assignments" do
    @assignment.update!(available_until: 3.days.from_now, completed_at: Time.current)

    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: :due_soon, survey_assignment_id: @assignment.id)
    end
  end

  test "due soon event skips assignments without a closing time" do
    @assignment.update!(available_until: nil)

    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: :due_soon, survey_assignment_id: @assignment.id)
    end
  end

  # Test :past_due event
  test "past due event notifies student when survey closes" do
    @assignment.update!(available_until: 2.days.ago)

    assert_difference -> { Notification.count }, 1 do
      SurveyNotificationJob.perform_now(event: :past_due, survey_assignment_id: @assignment.id)
    end

    notification = Notification.last
    assert_equal @assignment.student.user, notification.user
    assert_equal "Competency Survey Closed", notification.title
    assert_match @assignment.survey.title, notification.message
    assert_match /now closed/i, notification.message
  end

  test "past due event skips completed assignments" do
    @assignment.update!(available_until: 2.days.ago, completed_at: Time.current)

    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: :past_due, survey_assignment_id: @assignment.id)
    end
  end

  test "past due event skips assignments without a closing time" do
    @assignment.update!(available_until: nil)

    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: :past_due, survey_assignment_id: @assignment.id)
    end
  end

  # Test :survey_updated event
  test "survey updated event notifies all advisors with assignments" do
    other_advisor = advisors(:other_advisor)
    expected_notifications = distinct_advisor_ids_for(@survey.id).size
    assert expected_notifications >= 2

    assert_difference -> { Notification.count }, expected_notifications do
      SurveyNotificationJob.perform_now(
        event: :survey_updated,
        survey_id: @survey.id,
        metadata: { summary: "Questions updated." }
      )
    end

    notifications = Notification.last(expected_notifications)
    recipients = notifications.map(&:user)
    assert_includes recipients, @advisor.user
    assert_includes recipients, other_advisor.user
    assert_equal "Competency Survey Updated", notifications.first.title
    assert_match "Questions updated.", notifications.first.message
  end

  test "survey updated event includes metadata summary" do
    SurveyNotificationJob.perform_now(
      event: :survey_updated,
      survey_id: @survey.id,
      metadata: { summary: "New questions added" }
    )

    notification = Notification.last
    assert_match "New questions added", notification.message
    assert_match @survey.title, notification.message
  end

  test "survey updated event handles empty metadata" do
    expected_notifications = distinct_advisor_ids_for(@survey.id).size
    assert expected_notifications >= 1

    assert_difference -> { Notification.count }, expected_notifications do
      SurveyNotificationJob.perform_now(
        event: :survey_updated,
        survey_id: @survey.id,
        metadata: {}
      )
    end

    Notification.last(expected_notifications).each do |notification|
      assert_equal "Competency Survey Updated", notification.title
    end
  end

  # Test :survey_archived event
  test "survey archived event notifies all students with assignments" do
    expected_notifications = distinct_student_ids_for(@survey.id).size
    assert expected_notifications >= 2

    assert_difference -> { Notification.count }, expected_notifications do
      SurveyNotificationJob.perform_now(event: :survey_archived, survey_id: @survey.id)
    end

    notifications = Notification.last(expected_notifications)
    recipients = notifications.map(&:user)

    expected_student_ids = distinct_student_ids_for(@survey.id)
    expected_student_users = Student.includes(:user).where(student_id: expected_student_ids).map(&:user)
    expected_student_users.each do |expected_user|
      assert_includes recipients, expected_user
    end

    assert_equal "Competency Survey Archived", notifications.first.title
    assert_match @survey.title, notifications.first.message
  end

  test "survey archived event message indicates survey is no longer active" do
    SurveyNotificationJob.perform_now(event: :survey_archived, survey_id: @survey.id)

    notification = Notification.last
    assert_match /no longer active/, notification.message
  end

  # Test :question_updated event
  test "question updated event notifies survey participants" do
    expected_recipients = SurveyNotificationJob.new.send(:participant_users_for_survey, @survey.id)
    expected_count = expected_recipients.size
    assert expected_count >= 2

    assert_difference -> { Notification.count }, expected_count do
      SurveyNotificationJob.perform_now(
        event: :question_updated,
        question_id: @question.id,
        metadata: { editor_name: "Admin" }
      )
    end

    recipients = Notification.last(expected_count).map(&:user)
    expected_recipients.each do |user|
      assert_includes recipients, user
    end
    assert_equal "Competency Question Updated", Notification.last.title
  end

  test "question updated event includes editor name in message" do
    SurveyNotificationJob.perform_now(
      event: :question_updated,
      question_id: @question.id,
      metadata: { editor_name: "Dr. Smith" }
    )

    notification = Notification.last
    assert_match "Dr. Smith", notification.message
    assert_match @question.question_text, notification.message
  end

  test "question updated event uses default editor name if not provided" do
    SurveyNotificationJob.perform_now(
      event: :question_updated,
      question_id: @question.id,
      metadata: {}
    )

    notification = Notification.last
    assert_match "An administrator", notification.message
  end

  test "question updated event skips if question has no survey" do
    orphan_question = Question.new(
      category: categories(:clinical_skills),
      question_text: "Placeholder",
      question_order: 99,
      question_type: "short_answer",
      is_required: false
    )
    orphan_question.save!(validate: false)
    orphan_question.update_column(:category_id, nil)

    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(
        event: :question_updated,
        question_id: orphan_question.id,
        metadata: {}
      )
    end
  end

  # Test :custom event
  test "custom event delivers notification with provided details" do
    user = users(:student)

    assert_difference -> { Notification.count }, 1 do
      SurveyNotificationJob.perform_now(
        event: :custom,
        user_id: user.id,
        metadata: { title: "Custom Title", message: "Custom message content" }
      )
    end

    notification = Notification.last
    assert_equal user, notification.user
    assert_equal "Custom Title", notification.title
    assert_equal "Custom message content", notification.message
  end

  test "custom event uses default title and message if not provided" do
    user = users(:student)

    SurveyNotificationJob.perform_now(event: :custom, user_id: user.id, metadata: {})

    notification = Notification.last
    assert_equal "Notification", notification.title
    assert_equal "You have a new notification.", notification.message
  end

  test "custom event does not deliver if user_id is blank" do
    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(
        event: :custom,
        user_id: nil,
        metadata: { title: "Test", message: "Test message" }
      )
    end
  end

  # Test unknown events
  test "unknown event logs info message and does nothing" do
    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: :unknown_event, survey_assignment_id: @assignment.id)
    end
  end

  test "unknown event handles string events" do
    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: "invalid_event", survey_assignment_id: @assignment.id)
    end
  end

  # Test error handling
  test "rescues ActiveRecord::RecordNotFound for missing assignment" do
    assert_nothing_raised do
      SurveyNotificationJob.perform_now(event: :assigned, survey_assignment_id: 999_999)
    end

    assert_no_difference -> { Notification.count } do
      SurveyNotificationJob.perform_now(event: :assigned, survey_assignment_id: 999_999)
    end
  end

  test "rescues ActiveRecord::RecordNotFound for missing survey" do
    assert_nothing_raised do
      SurveyNotificationJob.perform_now(event: :survey_updated, survey_id: 999_999)
    end
  end

  test "rescues ActiveRecord::RecordNotFound for missing question" do
    assert_nothing_raised do
      SurveyNotificationJob.perform_now(event: :question_updated, question_id: 999_999)
    end
  end

  test "rescues ActiveRecord::RecordNotFound for missing user in custom event" do
    assert_nothing_raised do
      SurveyNotificationJob.perform_now(event: :custom, user_id: 999_999, metadata: { title: "Test" })
    end
  end

  # Test metadata handling
  test "handles string metadata keys" do
    SurveyNotificationJob.perform_now(
      event: :survey_updated,
      survey_id: @survey.id,
      metadata: { "summary" => "String key test" }
    )

    notification = Notification.last
    assert_match "String key test", notification.message
  end

  test "handles symbol metadata keys" do
    SurveyNotificationJob.perform_now(
      event: :survey_updated,
      survey_id: @survey.id,
      metadata: { summary: "Symbol key test" }
    )

    notification = Notification.last
    assert_match "Symbol key test", notification.message
  end

  test "handles nil metadata gracefully" do
    assert_difference -> { Notification.count }, 1 do
      SurveyNotificationJob.perform_now(event: :assigned, survey_assignment_id: @assignment.id, metadata: nil)
    end
  end

  # Test participant collection
  test "participant_users_for_survey deduplicates users" do
    # This test verifies that the participant collection doesn't crash with duplicate users
    # The fixture already has an assignment with student + advisor
    assert_nothing_raised do
      SurveyNotificationJob.perform_now(
        event: :question_updated,
        question_id: @question.id,
        metadata: {}
      )
    end

    # Should have notified participants
    assert Notification.count >= 2
  end

  test "handles assignment with nil student gracefully" do
    orphan_assignment = FakeAssignmentRecord.new(
      999,
      @survey,
      @survey.id,
      nil,
      @advisor,
      nil,
      @advisor.advisor_id
    )

    with_assignment_scope([ orphan_assignment ]) do
      assert_nothing_raised do
        SurveyNotificationJob.perform_now(
          event: :question_updated,
          question_id: @question.id,
          metadata: {}
        )
      end
    end
  end

  test "handles assignment with nil advisor gracefully" do
    create_assignment_for(
      student: nil,
      advisor: nil,
      assigned_at: 1.week.ago,
      available_until: 1.week.from_now
    )

    assert_nothing_raised do
      SurveyNotificationJob.perform_now(
        event: :question_updated,
        question_id: @question.id,
        metadata: {}
      )
    end
  end

  private

  def create_assignment_for(student: nil, survey: @survey, advisor: advisors(:advisor), assigned_at: 1.day.ago, available_until: 1.week.from_now)
    student ||= build_temp_student(advisor: advisor)

    SurveyAssignment.create!(
      survey: survey,
      student: student,
      advisor: advisor,
      assigned_at: assigned_at,
      available_until: available_until
    )
  end

  def distinct_advisor_ids_for(survey_id)
    SurveyAssignment.where(survey_id: survey_id).where.not(advisor_id: nil).distinct.pluck(:advisor_id)
  end

  def distinct_student_ids_for(survey_id)
    SurveyAssignment.where(survey_id: survey_id).where.not(student_id: nil).distinct.pluck(:student_id)
  end

  def build_temp_student(advisor: nil)
    user = User.create!(
      email: "student-#{SecureRandom.hex(4)}@example.test",
      name: "Temp Student #{SecureRandom.hex(2)}",
      role: "student",
      uid: SecureRandom.uuid
    )

    student = user.student_profile || user.create_student_profile!
    student.update!(advisor: advisor)
    student
  end
end

FakeAssignmentRecord = Struct.new(
  :id,
  :survey,
  :survey_id,
  :student,
  :advisor,
  :recipient_user,
  :advisor_id,
  keyword_init: false
)

class FakeAssignmentScope
  def initialize(records)
    @records = Array(records)
    @index = @records.index_by(&:id)
  end

  def includes(*)
    self
  end

  def find(id)
    record = @index[id]
    raise ActiveRecord::RecordNotFound, "Assignment #{id} not found" unless record

    record
  end

  def where(conditions = {})
    filtered = filter_records(@records, conditions)
    FakeAssignmentRelation.new(filtered)
  end

  private

  def filter_records(records, conditions)
    return records if conditions.blank?

    records.select do |record|
      conditions.all? do |key, value|
        record.respond_to?(key) && record.public_send(key) == value
      end
    end
  end
end

class FakeAssignmentRelation
  def initialize(records)
    @records = Array(records)
  end

  def includes(*)
    self
  end

  def where(conditions = {})
    filtered = filter_records(@records, conditions)
    FakeAssignmentRelation.new(filtered)
  end

  def distinct
    self
  end

  def pluck(attribute)
    @records.map { |record| record.public_send(attribute) }
  end

  def find_each(&block)
    @records.each(&block)
  end

  private

  def filter_records(records, conditions)
    return records if conditions.blank?

    records.select do |record|
      conditions.all? do |key, value|
        record.respond_to?(key) && record.public_send(key) == value
      end
    end
  end
end

private

def with_assignment_scope(records)
  original_scope = SurveyNotificationJob.assignment_scope
  SurveyNotificationJob.assignment_scope = FakeAssignmentScope.new(records)
  yield
ensure
  SurveyNotificationJob.assignment_scope = original_scope
end
