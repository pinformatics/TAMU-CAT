# Async wrapper for survey workflow notification events.
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
    dispatcher.perform(
      event: event,
      survey_assignment_id: survey_assignment_id,
      feedback_id: feedback_id,
      survey_id: survey_id,
      question_id: question_id,
      user_id: user_id,
      metadata: metadata
    )
  end

  private

  def dispatcher
    Notifications::SurveyEventDispatcher.new(assignment_scope: assignment_scope)
  end

  def participant_users_for_survey(survey_id)
    dispatcher.send(:participant_users_for_survey, survey_id)
  end
end
