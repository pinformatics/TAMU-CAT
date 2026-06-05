# Stores immutable snapshots of a student's survey answers at a point in time.
class SurveyResponseVersion < ApplicationRecord
  DRAFT_EVENTS = %w[edited].freeze

  belongs_to :student, foreign_key: :student_id, primary_key: :student_id
  belongs_to :survey
  belongs_to :survey_assignment, optional: true

  validates :student_id, presence: true
  validates :survey_id, presence: true
  validates :event, presence: true
  # Allow empty hashes (e.g., snapshot before any answers exist), but disallow nil.
  validates :answers, exclusion: { in: [ nil ], message: "can't be nil" }

  scope :for_pair, ->(student_id:, survey_id:) { where(student_id: student_id, survey_id: survey_id) }
  scope :chronological, -> { order(created_at: :asc, id: :asc) }

  class << self
    # Returns a normalized hash of the current persisted StudentQuestion answers
    # for the given student/survey pair.
    #
    # @param student [Student]
    # @param survey [Survey]
    # @return [Hash{String => Object}]
    def current_answers_for(student:, survey:)
      question_ids = survey.questions.select(:id)
      responses = StudentQuestion
                    .where(student_id: student.student_id, question_id: question_ids)
                    .select(:question_id, :response_value, :updated_at, :created_at)

      responses.each_with_object({}) do |record, memo|
        memo[record.question_id.to_s] = record.answer
      end
    end

    # Captures a snapshot of the current persisted StudentQuestion answers for
    # the given student/survey pair.
    #
    # @param student [Student]
    # @param survey [Survey]
    # @param assignment [SurveyAssignment, nil]
    # @param actor_user [User, nil]
    # @param event [String, Symbol]
    # @param skip_if_unchanged [Boolean] when true, avoids creating a new version when answers are unchanged
    # @return [SurveyResponseVersion]
    def capture_current!(student:, survey:, assignment: nil, actor_user: nil, event:, skip_if_unchanged: false)
      answers = current_answers_for(student: student, survey: survey)

      if skip_if_unchanged
        previous = where(
          student_id: student.student_id,
          survey_id: survey.id,
          survey_assignment_id: assignment&.id
        ).where.not(event: DRAFT_EVENTS).order(created_at: :desc, id: :desc).first

        return previous if previous&.answers == answers
      end

      create!(
        student_id: student.student_id,
        survey_id: survey.id,
        advisor_id: student.advisor_id,
        survey_assignment_id: assignment&.id,
        actor_user_id: actor_user&.id,
        actor_role: actor_user&.role,
        event: event.to_s,
        answers: answers
      )
    end
  end
end
