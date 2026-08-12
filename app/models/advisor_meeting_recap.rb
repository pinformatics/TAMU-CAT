# An advisor's recap of a single advising meeting with a student for a given
# program semester (initial/midpoint/final). Advisor-authored and
# advisor/admin-only -- never shown to students. Standalone from the
# Survey/Question engine since its content is fixed, not admin-configured.
class AdvisorMeetingRecap < ApplicationRecord
  MEETING_TYPES = %w[initial midpoint final].freeze
  MEETING_TYPE_LABELS = {
    "initial" => "Initial",
    "midpoint" => "Midpoint",
    "final" => "Final"
  }.freeze

  belongs_to :student, foreign_key: :student_id, primary_key: :student_id
  belongs_to :advisor, foreign_key: :advisor_id, primary_key: :advisor_id
  belongs_to :program_semester

  validates :meeting_type, inclusion: { in: MEETING_TYPES }
  validates :meeting_type, uniqueness: { scope: %i[student_id program_semester_id] }
  validate :at_least_one_note_present

  def meeting_type_label
    MEETING_TYPE_LABELS.fetch(meeting_type, meeting_type.to_s.titleize)
  end

  private

  def at_least_one_note_present
    return if academic_advising_notes.present? || career_advising_notes.present? || general_notes.present?

    errors.add(:base, "Enter notes in at least one field before saving.")
  end
end
