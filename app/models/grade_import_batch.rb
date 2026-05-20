class GradeImportBatch < ApplicationRecord
  STATUSES = %w[pending processing completed completed_with_errors failed rolled_back].freeze

  belongs_to :uploaded_by, class_name: "User"
  belongs_to :program_semester, optional: true
  has_many :grade_import_files, dependent: :destroy
  has_many :grade_competency_evidences, dependent: :destroy
  has_many :grade_competency_ratings, dependent: :destroy
  has_many :grade_import_pending_rows, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  scope :completed_states, -> { where(status: %w[completed completed_with_errors]) }
  scope :explicitly_not_dry_run, -> { where("COALESCE(summary ->> 'dry_run', 'true') = 'false'") }
  scope :reportable, -> { completed_states.explicitly_not_dry_run.where.not(status: "rolled_back") }

  def completed?
    status == "completed"
  end

  def completed_with_errors?
    status == "completed_with_errors"
  end

  def failed?
    status == "failed"
  end

  def rolled_back?
    status == "rolled_back"
  end

  def finalized?
    summary["finalized_at"].present?
  end

  def dry_run?
    ActiveModel::Type::Boolean.new.cast(summary["dry_run"])
  end

  def reportable?
    !dry_run? && !rolled_back? && (completed? || completed_with_errors?)
  end

  def admin_approved?
    summary["admin_approved_at"].present?
  end

  def needs_admin_approval?
    return false unless dry_run? && !rolled_back? && (completed? || completed_with_errors?)
    return true if completed_with_errors?

    grade_import_pending_rows.exists? ||
      grade_import_files.where("error_rows > 0 OR pending_rows > 0").exists? ||
      grade_import_files.any? { |file| Array(file.parse_errors).any? }
  end

  def committable_dry_run?
    dry_run? && !rolled_back? && (completed? || completed_with_errors?) &&
      (!needs_admin_approval? || admin_approved?)
  end

  def recommittable_rollback?
    return false unless rolled_back?
    return false if dry_run?

    previous_status = summary["previous_status"].to_s
    %w[completed completed_with_errors].include?(previous_status) &&
      (grade_competency_evidences.exists? || grade_competency_ratings.exists? || grade_import_pending_rows.exists?)
  end

  def finalizable?
    reportable? && !finalized?
  end
end
