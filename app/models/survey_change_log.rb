# Change history entries capturing moderator actions on surveys.
class SurveyChangeLog < ApplicationRecord
  # Permitted action identifiers stored with each log entry.
  ACTIONS = %w[create update assign archive activate delete preview copy].freeze

  belongs_to :survey, optional: true
  belongs_to :admin, class_name: "User"

  validates :action, presence: true, inclusion: { in: ACTIONS }

  # @return [ActiveRecord::Relation<SurveyChangeLog>] logs newest first
  scope :recent, -> { order(created_at: :desc) }
end
