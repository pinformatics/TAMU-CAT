# frozen_string_literal: true

class CompetencyTargetLevel < ApplicationRecord
  belongs_to :program_semester
  belongs_to :competency, optional: true

  before_validation :sync_competency_reference

  validates :program_semester_id, presence: true
  validates :track, presence: true
  validates :competency_title, presence: true
  validates :target_level, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }

  validates :track, inclusion: { in: ->(_record) { ProgramTrack.names } }, allow_blank: true

  validates :class_of, numericality: { only_integer: true, greater_than_or_equal_to: 2026, less_than_or_equal_to: 3000 }, allow_nil: true
  validates :competency_title, uniqueness: { scope: %i[program_semester_id track class_of program_year] }

  private

  def sync_competency_reference
    return unless self.class.column_names.include?("competency_id")
    return if competency_title.blank?
    return if competency_id.present? && !will_save_change_to_competency_title?

    self.competency = Competency.find_by_normalized_title(competency_title)
  end
end
