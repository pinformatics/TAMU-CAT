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
      apply_configured_course_targets!(rows)
      missing_course_targets = rows.select { |row| row[:course_target_level].blank? }
      mismatched_configured_course_targets = rows.select do |row|
        row[:course_target_level].present? &&
          row[:configured_course_target_level].present? &&
          row[:course_target_level].to_i != row[:configured_course_target_level].to_i
      end

      {
        requires_review: missing_course_targets.any? || mismatched_configured_course_targets.any?,
        missing_course_targets: examples_for(missing_course_targets),
        mismatched_configured_course_targets: examples_for(mismatched_configured_course_targets),
        target_coverage: coverage_for(rows),
        counts: {
          rows_checked: rows.size,
          missing_course_targets: missing_course_targets.size,
          mismatched_configured_course_targets: mismatched_configured_course_targets.size
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

    def examples_for(rows)
      rows.first(MAX_EXAMPLES).map do |row|
        {
          student: row[:student_label],
          course_code: row[:course_code],
          competency: row[:competency_title],
          course_target: row[:course_target_level],
          configured_course_target: row[:configured_course_target_level],
          track: row[:track],
          class_of: row[:class_of],
          row_type: row[:row_type],
          row_number: row[:row_number]
        }
      end
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
