# Polymorphic notifications delivered to end users.
class Notification < ApplicationRecord
  include Rails.application.routes.url_helpers

  belongs_to :user
  belongs_to :notifiable, polymorphic: true, optional: true

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  validates :title, presence: true
  validates :message, presence: true
  validates :user_id, uniqueness: { scope: %i[title notifiable_type notifiable_id] }

  # Creates or reuses an existing notification matching the uniqueness scope.
  #
  # @param user [User]
  # @param title [String]
  # @param message [String]
  # @param notifiable [ApplicationRecord, nil]
  # @return [Notification]
  def self.deliver!(user:, title:, message:, notifiable: nil)
    relation = where(user: user, title: title)
    relation = if notifiable
      relation.where(notifiable: notifiable)
    else
      relation.where(notifiable_type: nil, notifiable_id: nil)
    end

    record = relation.first_or_initialize
    record.message = message
    record.notifiable = notifiable
    record.save!
    record
  end

  # Marks the notification as read by setting the timestamp.
  #
  # @return [Boolean]
  def mark_read!
    update!(read_at: Time.current)
  end

  # @return [Boolean] true when read_at contains a timestamp
  def read?
    read_at.present?
  end

  # Computes a reasonable path for the notification recipient to visit.
  #
  # @param viewer [User, nil]
  # @return [String, nil]
  def target_path_for(viewer = nil)
    return unless notifiable

    case notifiable
    when Survey
      resolve_survey_path(notifiable, viewer)
    when SurveyAssignment
      resolve_assignment_path(notifiable, viewer)
    when Question
      question_path(notifiable)
    when Feedback
      feedback_path(notifiable)
    when ProgramSemester
      resolve_program_semester_path(viewer)
    else
      nil
    end
  end

  private

  def default_url_options
    Rails.application.config.action_controller.default_url_options || {}
  end

  def resolve_assignment_path(assignment, viewer)
    return survey_path(assignment.survey_id) unless viewer

    case viewer.role
    when "advisor"
      assignments_survey_path(assignment.survey_id)
    when "admin"
      assignments_survey_path(assignment.survey_id)
    else
      survey_response_path_for_assignment(assignment) || survey_path(assignment.survey_id)
    end
  end

  def resolve_survey_path(survey, viewer)
    return survey_path(survey) unless viewer

    case viewer.role
    when "advisor"
      assignments_survey_path(survey)
    when "admin"
      assignments_survey_path(survey)
    else
      survey_path(survey)
    end
  end

  def resolve_program_semester_path(viewer)
    return reports_path unless viewer

    case viewer.role
    when "student"
      student_competencies_path
    else
      reports_path
    end
  end

  def survey_response_path_for_assignment(assignment)
    return unless assignment.completed_at?

    student = assignment.student
    survey = assignment.survey
    return unless student && survey

    survey_response = SurveyResponse.build(student: student, survey: survey)
    survey_response_path(survey_response)
  end
end
