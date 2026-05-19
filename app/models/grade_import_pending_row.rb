class GradeImportPendingRow < ApplicationRecord
  STATUSES = %w[pending_student_match reconciled].freeze

  belongs_to :grade_import_batch
  belongs_to :grade_import_file
  belongs_to :matched_student, class_name: "Student", foreign_key: :matched_student_id, primary_key: :student_id, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :competency_title, :raw_grade, :mapped_level, :source_key, :import_fingerprint, presence: true
  validates :import_fingerprint, uniqueness: true
  validates :course_target_level, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }, allow_nil: true

  scope :pending_student_match, -> { where(status: "pending_student_match") }
  scope :reconciled, -> { where(status: "reconciled") }

  def self.matching_student(student)
    scope = pending_student_match

    clauses = []
    values = {}

    if student.uin.present?
      clauses << "student_uin = :uin"
      values[:uin] = student.uin
    end

    if student.user&.email.present?
      clauses << "LOWER(student_email) = :email"
      values[:email] = student.user.email.downcase
    end

    if student.user&.name.present?
      clauses << "(student_identifier_type = 'student_name' AND LOWER(student_name) = :student_name)"
      values[:student_name] = student.user.name.downcase
    end

    return none if clauses.empty?

    scope.where(clauses.join(" OR "), values)
  end
end
