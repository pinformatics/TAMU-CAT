# Utility class for enqueuing notification jobs related to survey assignments.
class SurveyAssignmentNotifier
  CLOSING_SOON_WINDOW = 3.days

  class << self
    # Enqueues notifications for assignments closing soon or already closed.
    #
    # @param reference_time [Time] point-in-time used for calculations
    # @return [void]
    def run_closing_checks!(reference_time: Time.current)
      scope = SurveyAssignment.incomplete.where.not(available_until: nil)

      closing_soon_scope = scope.where(available_until: reference_time..(reference_time + CLOSING_SOON_WINDOW))
      closing_soon_scope.find_each do |assignment|
        SurveyNotificationJob.perform_later(event: :due_soon, survey_assignment_id: assignment.id)
      end

      closed_scope = scope.where("available_until < ?", reference_time)
      closed_scope.find_each do |assignment|
        SurveyNotificationJob.perform_later(event: :past_due, survey_assignment_id: assignment.id)
      end
    end

    # Sends a single notification immediately without background work.
    #
    # @param assignment [SurveyAssignment]
    # @param title [String]
    # @param message [String]
    # @return [Notification, nil]
    def notify_now!(assignment:, title:, message:, event_key: "survey.assignment.notice")
      user = assignment.recipient_user
      return unless user

      Notification.deliver!(
        user: user,
        title: title,
        message: message,
        notifiable: assignment,
        event_key: event_key,
        dedupe_key: "#{event_key}:survey_assignment:#{assignment.id}:title:#{title.to_s.parameterize.presence || 'notice'}",
        metadata: {
          survey_assignment_id: assignment.id,
          survey_id: assignment.survey_id,
          student_id: assignment.student_id,
          advisor_id: assignment.advisor_id
        }
      )
    end
  end
end
