class GradeCompetencyRating < ApplicationRecord
  belongs_to :grade_import_batch
  belongs_to :student, foreign_key: :student_id, primary_key: :student_id
  belongs_to :competency, optional: true

  before_validation :sync_competency_reference

  validates :competency_title, presence: true
  validates :aggregated_level, presence: true, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }
  validates :aggregation_rule, presence: true
  validates :evidence_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  private

  def sync_competency_reference
    return unless self.class.column_names.include?("competency_id")
    return if competency_title.blank?
    return if competency_id.present? && !will_save_change_to_competency_title?

    self.competency = Competency.find_by_normalized_title(competency_title)
  end
end
