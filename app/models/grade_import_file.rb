class GradeImportFile < ApplicationRecord
  STATUSES = %w[pending processed failed].freeze

  belongs_to :grade_import_batch
  belongs_to :course_offering, optional: true
  has_many :grade_competency_evidences, dependent: :destroy
  has_many :grade_import_pending_rows, dependent: :destroy

  validates :file_name, :file_checksum, presence: true
  validates :status, inclusion: { in: STATUSES }
end
