class StudentAdvisorAssignment < ApplicationRecord
  belongs_to :student, foreign_key: :student_id, primary_key: :student_id, inverse_of: :advisor_assignments
  belongs_to :advisor, foreign_key: :advisor_id, primary_key: :advisor_id, optional: true, inverse_of: :student_advisor_assignments
  belongs_to :assigned_by, class_name: "User", optional: true

  validates :starts_on, presence: true
  validate :ends_on_not_before_starts_on

  scope :primary_assignments, -> { where(primary_assignment: true) }
  scope :current, -> { primary_assignments.where(ends_on: nil) }
  scope :historical, -> { where.not(ends_on: nil) }
  scope :ordered, -> { order(starts_on: :desc, id: :desc) }

  def self.record_advisor_change!(student:, advisor_id:, previous_advisor_id: nil, assigned_by: nil, starts_on: Date.current)
    normalized_advisor_id = advisor_id.presence&.to_i
    normalized_previous_id = previous_advisor_id.presence&.to_i
    effective_start = starts_on || Date.current

    transaction do
      current_assignment = current.where(student_id: student.student_id).ordered.first
      return current_assignment if current_assignment&.advisor_id == normalized_advisor_id

      close_assignment!(current_assignment, effective_start) if current_assignment

      if current_assignment.blank? && normalized_previous_id.present? && normalized_previous_id != normalized_advisor_id
        create!(
          student: student,
          advisor_id: normalized_previous_id,
          starts_on: student.created_at&.to_date || effective_start,
          ends_on: effective_start,
          primary_assignment: true
        )
      end

      next if normalized_advisor_id.blank?

      create!(
        student: student,
        advisor_id: normalized_advisor_id,
        starts_on: effective_start,
        primary_assignment: true,
        assigned_by: assigned_by
      )
    end
  end

  def current?
    primary_assignment? && ends_on.blank?
  end

  private_class_method def self.close_assignment!(assignment, ended_on)
    assignment.update!(ends_on: [ assignment.starts_on, ended_on ].compact.max)
  end

  private

  def ends_on_not_before_starts_on
    return if starts_on.blank? || ends_on.blank?
    return if ends_on >= starts_on

    errors.add(:ends_on, "cannot be before the start date")
  end
end
