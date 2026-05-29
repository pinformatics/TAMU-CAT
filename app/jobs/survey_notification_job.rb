# Dispatches notification events related to survey assignments and lifecycle changes.
class SurveyNotificationJob < ApplicationJob
  queue_as :default
  class_attribute :assignment_scope, default: SurveyAssignment

  rescue_from ActiveRecord::RecordNotFound do |error|
    Rails.logger.warn("SurveyNotificationJob skipped: #{error.message}")
  end

  # @param event [Symbol, String]
  # @param survey_assignment_id [Integer, nil]
  # @param feedback_id [Integer, nil]
  # @param survey_id [Integer, nil]
  # @param question_id [Integer, nil]
  # @param user_id [Integer, nil]
  # @param metadata [Hash]
  # @return [void]
  def perform(event:, survey_assignment_id: nil, feedback_id: nil, survey_id: nil, question_id: nil, user_id: nil, metadata: {})
    event_key = event.to_sym
    metadata = metadata.present? ? metadata.with_indifferent_access : {}

    case event_key
    when :assigned
      handle_assigned_notification(survey_assignment_id)
    when :due_soon
      handle_due_soon_notification(survey_assignment_id)
    when :past_due
      handle_past_due_notification(survey_assignment_id)
    when :response_submitted
      handle_response_submitted_notification(survey_assignment_id, metadata)
    when :feedback_received
      handle_feedback_received_notification(feedback_id)
    when :student_revised_after_feedback
      handle_student_revised_after_feedback_notification(survey_assignment_id)
    when :survey_updated
      handle_survey_updated_notification(survey_id, metadata)
    when :survey_archived
      handle_survey_archived_notification(survey_id)
    when :question_updated
      handle_question_updated_notification(question_id, metadata)
    when :custom
      handle_custom_notification(user_id, metadata)
    else
      Rails.logger.info("SurveyNotificationJob received unknown event: #{event_key}")
    end
  end

  private

  def handle_assigned_notification(survey_assignment_id)
    assignment = assignment_scope.includes(:survey, student: :user, advisor: :user).find(survey_assignment_id)

    Notification.deliver!(
      user: assignment.recipient_user,
      title: "New Competency Survey Assigned",
      message: "You were assigned the competency survey '#{assignment.survey.title}'.",
      notifiable: assignment
    )
  end

  def handle_due_soon_notification(survey_assignment_id)
    assignment = assignment_scope.includes(:survey, student: :user).find(survey_assignment_id)
    return if assignment.completed_at?
    return unless assignment.available_until

    closes_in = ActionController::Base.helpers.distance_of_time_in_words(Time.current, assignment.available_until)

    notification = Notification.deliver!(
      user: assignment.recipient_user,
      title: "Competency Survey Closing Soon",
      message: "Your competency survey '#{assignment.survey.title}' closes in #{closes_in}. Please complete it before it closes.",
      notifiable: assignment
    )
    enqueue_notification_email(notification)
  end

  def handle_past_due_notification(survey_assignment_id)
    assignment = assignment_scope.includes(:survey, student: :user).find(survey_assignment_id)
    return if assignment.completed_at?
    return unless assignment.available_until

    Notification.deliver!(
      user: assignment.recipient_user,
      title: "Competency Survey Closed",
      message: "The competency survey '#{assignment.survey.title}' is now closed.",
      notifiable: assignment
    )
  end

  def handle_response_submitted_notification(survey_assignment_id, metadata = {})
    assignment = assignment_scope.includes(:survey, student: :user, advisor: :user).find(survey_assignment_id)
    student_user = assignment.recipient_user
    revision = ActiveModel::Type::Boolean.new.cast(metadata[:revision])

    if student_user
      Notification.deliver!(
        user: student_user,
        title: "Competency Survey Submitted",
        message: student_submission_message(assignment, revision: revision),
        notifiable: assignment
      )
    end

    notify_advisor_of_student_response(assignment, revision: revision)
  end

  def handle_feedback_received_notification(feedback_id)
    return if feedback_id.blank?

    feedback = Feedback.includes(:survey, student: :user, advisor: :user).find(feedback_id)
    submission = AdvisorFeedbackSubmission.submitted.find_by(
      student_id: feedback.student_id,
      survey_id: feedback.survey_id,
      advisor_id: feedback.advisor_id
    )
    return unless submission

    assignment = assignment_scope.find_by(student_id: feedback.student_id, survey_id: feedback.survey_id)
    return unless assignment

    student_user = assignment.recipient_user
    return unless student_user

    advisor_name = feedback.advisor&.user&.display_name || "Your advisor"

    Notification.deliver!(
      user: student_user,
      title: "Advisor Feedback Received",
      message: "#{advisor_name} left feedback on '#{feedback.survey.title}'.",
      notifiable: assignment
    )
  end

  def handle_student_revised_after_feedback_notification(survey_assignment_id)
    assignment = assignment_scope.includes(:survey, advisor: :user, student: :user).find(survey_assignment_id)
    return unless Feedback.exists?(student_id: assignment.student_id, survey_id: assignment.survey_id)

    recipients = {}
    collect_user(recipients, assignment.advisor_user)
    User.admins.find_each { |admin_user| collect_user(recipients, admin_user) }

    recipients.values.each do |user|
      Notification.deliver!(
        user: user,
        title: "Competency Survey Updated After Feedback",
        message: "#{assignment.student.full_name} updated '#{assignment.survey.title}' after feedback was provided.",
        notifiable: assignment
      )
    end
  end

  def handle_survey_updated_notification(survey_id, metadata)
    survey = Survey.find(survey_id)
    advisor_ids = assignment_scope.where(survey_id: survey_id).distinct.pluck(:advisor_id).compact

    User.where(id: advisor_ids).find_each do |advisor_user|
      summary = metadata[:summary].to_s.strip
      message = "The competency survey '#{survey.title}' was updated."
      message = "#{message} #{summary}" if summary.present?

      Notification.deliver!(
        user: advisor_user,
        title: "Competency Survey Updated",
        message: message,
        notifiable: survey
      )
    end
  end

  def handle_survey_archived_notification(survey_id)
    survey = Survey.find(survey_id)
    student_ids = assignment_scope.where(survey_id: survey_id).distinct.pluck(:student_id)

    Student.includes(:user).where(student_id: student_ids).find_each do |student|
      Notification.deliver!(
        user: student.user,
        title: "Competency Survey Archived",
        message: "The competency survey '#{survey.title}' is no longer active.",
        notifiable: survey
      )
    end
  end

  def handle_question_updated_notification(question_id, metadata)
    question = Question.includes(category: :survey).find(question_id)
    survey = question.category&.survey
    return unless survey

    editor_name = metadata[:editor_name].presence || "An administrator"
    message = "#{editor_name} updated the question '#{question.question_text}' in the '#{survey.title}' competency survey. Review the latest instructions before proceeding."

    participant_users_for_survey(survey.id).each do |user|
      Notification.deliver!(
        user: user,
        title: "Competency Question Updated",
        message: message,
        notifiable: question
      )
    end
  end

  def handle_custom_notification(user_id, metadata)
    return if user_id.blank?

    user = User.find(user_id)
    title = metadata[:title] || "Notification"
    message = metadata[:message] || "You have a new notification."
    Notification.deliver!(user: user, title: title, message: message)
  end

  def student_submission_message(assignment, revision:)
    if revision
      "Thanks! Your updated responses for '#{assignment.survey.title}' were received."
    else
      "Thanks! Your responses for '#{assignment.survey.title}' were received."
    end
  end

  def notify_advisor_of_student_response(assignment, revision:)
    advisor_user = if assignment.respond_to?(:advisor_user)
      assignment.advisor_user
    else
      assignment.advisor&.user
    end
    return unless advisor_user

    student_name = assignment.student&.full_name.presence || "An advisee"
    title = revision ? "Advisee Survey Edited" : "Advisee Survey Submitted"
    verb = revision ? "updated" : "submitted"

    Notification.deliver!(
      user: advisor_user,
      title: title,
      message: "#{student_name} #{verb} '#{assignment.survey.title}'.",
      notifiable: assignment
    )
  end

  def participant_users_for_survey(survey_id)
    assignments = assignment_scope.includes(student: :user, advisor: :user).where(survey_id: survey_id)
    unique_users = {}

    assignments.find_each do |assignment|
      collect_user(unique_users, assignment.student&.user)
      collect_user(unique_users, assignment.advisor&.user)
    end

    unique_users.values
  end

  def collect_user(bucket, user)
    return unless user&.id

    bucket[user.id] = user
  end

  def enqueue_notification_email(notification)
    NotificationEmailDeliveryJob.perform_later(notification_id: notification.id)
  end
end
