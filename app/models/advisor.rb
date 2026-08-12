# Profile for users serving as advisors, including relationships to advisees and
# delegated user attributes.
class Advisor < ApplicationRecord
  self.primary_key = :advisor_id

  belongs_to :user, foreign_key: :advisor_id, primary_key: :id, inverse_of: :advisor_profile
  has_many :advisees, class_name: "Student", foreign_key: :advisor_id, dependent: :destroy
  has_many :student_advisor_assignments, foreign_key: :advisor_id, primary_key: :advisor_id, dependent: :nullify, inverse_of: :advisor
  has_many :student_questions, foreign_key: :advisor_id, dependent: :nullify
  has_many :feedbacks, foreign_key: :advisor_id
  has_many :survey_assignments, foreign_key: :advisor_id, primary_key: :advisor_id, dependent: :nullify
  has_many :advisor_meeting_recaps, foreign_key: :advisor_id, primary_key: :advisor_id, dependent: :destroy
  delegate :email, :email=, :name, :name=, :avatar_url, :avatar_url=, to: :user

  # @return [String] a friendly name with email fallback
  def display_name
    name.presence || email
  end

  # @return [String] the role stored on the associated user
  def role
    user.role
  end

  # Saves the advisor and any pending changes on the associated user.
  #
  # @return [Boolean]
  def save(*args, &block)
    user.save! if user&.changed?
    super
  end

  # Saves the advisor and user, raising on failure.
  #
  # @return [Boolean]
  def save!(*args, &block)
    user.save! if user&.changed?
    super
  end
end
