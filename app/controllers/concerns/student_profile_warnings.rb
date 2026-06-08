# frozen_string_literal: true

# Flags students missing profile fields (track, class year, advisor, UIN) that
# are relied on for advisor assignment, reports, grade imports, and notifications.
module StudentProfileWarnings
  extend ActiveSupport::Concern

  private

  def build_student_profile_warnings(students)
    warning_definitions = [
      [ :missing_track, "Missing track", ->(student) { student.track_key.blank? } ],
      [ :missing_class_year, "Missing class year", ->(student) { student.program_year.blank? } ],
      [ :missing_advisor, "Unassigned advisor", ->(student) { student.advisor_id.blank? } ],
      [ :missing_uin, "Missing UIN", ->(student) { student.uin.blank? } ]
    ]

    warning_definitions.filter_map do |key, label, predicate|
      affected_students = Array(students).select { |student| predicate.call(student) }
      next if affected_students.blank?

      {
        key: key,
        label: label,
        count: affected_students.size,
        students: affected_students.first(4).map { |student| student_profile_warning_label(student) }
      }
    end
  end

  def student_profile_warning_label(student)
    student.user&.name.presence || student.user&.email.presence || "Student ##{student.student_id}"
  end
end
