# frozen_string_literal: true

module GradeImports
  class TargetWarningAnalyzer
    MAX_EXAMPLES = 25

    def self.call(batch:)
      new(batch: batch).call
    end

    def initialize(batch:)
      @batch = batch
    end

    def call
      rows = warning_rows
      configured_targets_available = CourseCompetencyTarget.data_source_ready?
      apply_configured_course_targets!(rows) if configured_targets_available
      course_code_issue_rows = rows.select { |row| row[:course_code_issues].present? }
      missing_course_targets = rows.select { |row| row[:course_target_level].blank? }
      mismatched_configured_course_targets = rows.select do |row|
        row[:course_target_level].present? &&
          row[:configured_course_target_level].present? &&
          row[:course_target_level].to_i != row[:configured_course_target_level].to_i
      end
      grouped_course_code_issues = grouped_examples_for(course_code_issue_rows, group_by: :course)
      grouped_missing_course_targets = grouped_examples_for(missing_course_targets, group_by: :course_competency_target)
      grouped_mismatched_configured_course_targets = grouped_examples_for(mismatched_configured_course_targets, group_by: :course_competency_target)

      {
        requires_review: course_code_issue_rows.any? || missing_course_targets.any? || mismatched_configured_course_targets.any?,
        course_code_issues: grouped_course_code_issues,
        missing_course_targets: grouped_missing_course_targets,
        mismatched_configured_course_targets: grouped_mismatched_configured_course_targets,
        configured_course_targets_available: configured_targets_available,
        configured_course_targets_note: configured_course_targets_note(configured_targets_available),
        target_coverage: coverage_for(rows),
        counts: {
          rows_checked: rows.size,
          course_code_issues: course_code_issue_rows.size,
          course_code_issue_groups: grouped_course_code_issues.size,
          missing_course_targets: missing_course_targets.size,
          missing_course_target_groups: grouped_missing_course_targets.size,
          mismatched_configured_course_targets: mismatched_configured_course_targets.size,
          mismatched_configured_course_target_groups: grouped_mismatched_configured_course_targets.size
        }
      }
    end

    private

    attr_reader :batch

    def warning_rows
      evidence_rows + pending_rows
    end

    def evidence_rows
      batch.grade_competency_evidences.includes(:competency, :course_offering, student: :user).map do |evidence|
        student = evidence.student
        build_row(
          row_type: "imported",
          student: student,
          student_label: student_label(student),
          course_code: evidence.course_code,
          course_offering_id: evidence.course_offering_id,
          competency_id: evidence.competency_id,
          competency_title: evidence.competency_title,
          course_target_level: evidence.course_target_level,
          row_number: evidence.row_number
        )
      end
    end

    def pending_rows
      batch.grade_import_pending_rows.pending_student_match.includes(:competency, :course_offering, matched_student: :user).map do |row|
        student = row.matched_student
        build_row(
          row_type: "pending",
          student: student,
          student_label: student_label(student).presence || row.student_name.presence || row.student_identifier.presence || "Unmatched student",
          course_code: row.course_code,
          course_offering_id: row.course_offering_id,
          competency_id: row.competency_id,
          competency_title: row.competency_title,
          course_target_level: row.course_target_level,
          row_number: row.row_number
        )
      end
    end

    def build_row(row_type:, student:, student_label:, course_code:, course_offering_id:, competency_id:, competency_title:, course_target_level:, row_number:)
      {
        row_type: row_type,
        student_label: student_label,
        track: student&.track,
        class_of: student&.program_year,
        course_code: course_code.presence || "No course code",
        course_code_issues: course_code_issues_for(course_code),
        course_offering_id: course_offering_id,
        competency_id: competency_id,
        competency_title: competency_title,
        course_target_level: course_target_level,
        row_number: row_number
      }
    end

    def apply_configured_course_targets!(rows)
      target_lookup = configured_course_target_lookup(rows)

      rows.each do |row|
        row[:configured_course_target_level] = target_lookup[[ row[:course_offering_id], row[:competency_id] ]]
      end
    end

    def configured_course_target_lookup(rows)
      pairs = rows.filter_map do |row|
        course_offering_id = row[:course_offering_id]
        competency_id = row[:competency_id]
        [ course_offering_id, competency_id ] if course_offering_id.present? && competency_id.present?
      end.uniq
      return {} if pairs.blank?

      course_offering_ids = pairs.map(&:first).uniq
      competency_ids = pairs.map(&:last).uniq

      CourseCompetencyTarget
        .where(course_offering_id: course_offering_ids, competency_id: competency_ids)
        .pluck(:course_offering_id, :competency_id, :target_level)
        .each_with_object({}) do |(course_offering_id, competency_id, target_level), lookup|
          lookup[[ course_offering_id, competency_id ]] = target_level
        end
    end

    def configured_course_targets_note(available)
      return if available

      "Configured course target comparison is unavailable until the V6 course target tables are present. Uploaded target checks still run."
    end

    def grouped_examples_for(rows, group_by:)
      rows.group_by { |row| grouped_warning_key(row, group_by) }.values.first(MAX_EXAMPLES).map do |group|
        row = group.first
        students = group.map { |entry| entry[:student_label] }.compact_blank.uniq.sort
        tracks = group.map { |entry| entry[:track] }.compact_blank.uniq.sort
        classes = group.map { |entry| entry[:class_of] }.compact_blank.uniq.sort
        competencies = group.map { |entry| entry[:competency_title] }.compact_blank.uniq.sort

        {
          student: affected_student_label(students, group.size),
          students: students,
          student_count: students.size,
          affected_count: group.size,
          affected_label: affected_label(students.size, group.size),
          course_code: row[:course_code],
          competency: competency_label(competencies),
          competencies: competencies,
          course_code_issue: course_code_issue_label(group),
          course_target: row[:course_target_level],
          configured_course_target: row[:configured_course_target_level],
          track: tracks.to_sentence,
          class_of: classes.to_sentence,
          row_type: row_type_label(group),
          row_number: group.map { |entry| entry[:row_number] }.compact.min
        }
      end
    end

    def grouped_warning_key(row, group_by)
      case group_by
      when :course
        [ row[:course_code] ]
      else
        [
          row[:course_code],
          row[:competency_title],
          row[:course_target_level],
          row[:configured_course_target_level]
        ]
      end
    end

    def course_code_issues_for(course_code)
      token = course_code.to_s.strip
      return [ "missing 4-letter department code, 3-digit course number, and 3-digit section number" ] if token.blank? || token == "No course code"

      parsed = CourseOffering.parse_source_code(course_code)
      return [ "must include a 4-letter department code, 3-digit course number, and 3-digit section number" ] if parsed.blank?

      issues = []
      issues << "department code must be 4 letters" unless parsed[:department_code].to_s.match?(/\A[A-Z]{4}\z/)
      issues << "course number must be 3 digits" unless parsed[:course_number].to_s.match?(/\A\d{3}\z/)
      issues << "section number must be 3 digits" unless parsed[:section_number].to_s.match?(/\A\d{3}\z/)
      issues
    end

    def course_code_issue_label(group)
      group.flat_map { |entry| Array(entry[:course_code_issues]) }.compact_blank.uniq.to_sentence
    end

    def affected_student_label(students, affected_count)
      return students.first if students.one?
      return "#{students.size} students" if students.any?

      "#{affected_count} rows"
    end

    def affected_label(student_count, affected_count)
      return "#{student_count} #{'student'.pluralize(student_count)} / #{affected_count} #{'row'.pluralize(affected_count)}" if student_count.positive?

      "#{affected_count} #{'row'.pluralize(affected_count)}"
    end

    def competency_label(competencies)
      return competencies.first if competencies.one?
      return "No competency" if competencies.blank?

      "#{competencies.size} competencies"
    end

    def row_type_label(group)
      row_types = group.map { |entry| entry[:row_type] }.compact_blank.uniq.sort
      row_types.one? ? row_types.first : "mixed"
    end

    def coverage_for(rows)
      rows.group_by { |row| [ row[:course_code], row[:competency_title] ] }.map do |(course_code, competency), group|
        present_count = group.count { |row| row[:course_target_level].present? }
        total_count = group.size

        {
          course_code: course_code,
          competency: competency,
          present_count: present_count,
          total_count: total_count,
          missing_count: total_count - present_count
        }
      end.sort_by { |entry| [ entry[:course_code].to_s, entry[:competency].to_s ] }
    end

    def student_label(student)
      return if student.blank?

      student.user&.display_name || student.user&.email || student.student_id
    end
  end
end
