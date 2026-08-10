class GradeCompetencyEvidence < ApplicationRecord
  belongs_to :grade_import_batch
  belongs_to :grade_import_file
  belongs_to :student, foreign_key: :student_id, primary_key: :student_id
  belongs_to :competency, optional: true
  belongs_to :course_offering, optional: true

  before_validation :sync_competency_reference
  before_validation :sync_course_offering_reference

  validates :competency_title, presence: true
  validates :raw_grade, presence: true
  validates :source_key, :import_fingerprint, presence: true
  validates :import_fingerprint, uniqueness: true
  validates :mapped_level, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }
  validates :course_target_level, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }, allow_nil: true

  private

  def sync_competency_reference
    return unless self.class.column_names.include?("competency_id")
    return if competency_title.blank?
    return if competency.present? && new_record?
    return if competency_id.present? && !will_save_change_to_competency_title?

    self.competency = Competency.find_by_normalized_title(competency_title)
  end

  def sync_course_offering_reference
    return unless self.class.column_names.include?("course_offering_id")
    return unless CourseOffering.table_exists?
    return if course_code.blank?
    return if course_offering.present? && new_record?
    return if course_offering_id.present? && !will_save_change_to_course_code? && !will_save_change_to_grade_import_batch_id?

    self.course_offering = CourseOffering.find_or_create_from_code!(
      course_code,
      program_semester: grade_import_batch&.program_semester,
      source_name: grade_import_file&.file_name
    )
  end
end
