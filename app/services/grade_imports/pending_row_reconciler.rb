require "set"

module GradeImports
  class PendingRowReconciler
    def self.call(student:)
      new(student: student).call
    end

    def initialize(student:)
      @student = student
    end

    def call
      return 0 if student.blank?

      reconciled_count = 0
      affected_batch_ids = Set.new

      GradeImportPendingRow.matching_student(student).find_each do |pending_row|
        pending_row.with_lock do
          next unless pending_row.status == "pending_student_match"

          evidence = pending_row.grade_import_batch.grade_competency_evidences.find_or_initialize_by(
            source_key: pending_row.source_key
          )

          if evidence.new_record?
            attrs = {
              grade_import_file: pending_row.grade_import_file,
              student_id: student.student_id,
              competency_title: pending_row.competency_title,
              course_code: pending_row.course_code,
              assignment_name: pending_row.assignment_name,
              raw_grade: pending_row.raw_grade,
              mapped_level: pending_row.mapped_level,
              course_target_level: pending_row.course_target_level,
              row_number: pending_row.row_number,
              import_fingerprint: pending_row.import_fingerprint,
              metadata: pending_row.metadata.merge(
                "student_uin" => pending_row.student_uin,
                "student_email" => pending_row.student_email,
                "student_name" => pending_row.student_name,
                "student_identifier" => pending_row.student_identifier,
                "student_identifier_type" => pending_row.student_identifier_type,
                "pending_row_id" => pending_row.id,
                "reconciled_at" => Time.current.iso8601
              )
            }
            attrs[:competency] = pending_row.competency if GradeCompetencyEvidence.column_names.include?("competency_id")
            attrs[:course_offering] = pending_row.course_offering if GradeCompetencyEvidence.column_names.include?("course_offering_id")

            evidence.assign_attributes(attrs)
            evidence.save!
          end

          pending_row.update!(
            status: "reconciled",
            matched_student_id: student.student_id,
            reconciled_at: Time.current
          )

          affected_batch_ids << pending_row.grade_import_batch_id
          reconciled_count += 1
        end
      end

      affected_batch_ids.each do |batch_id|
        batch = GradeImportBatch.find_by(id: batch_id)
        next unless batch

        BatchRatingRebuilder.call(batch: batch)
        batch.update!(
          evidence_count: batch.grade_competency_evidences.count,
          rating_count: batch.grade_competency_ratings.count,
          pending_count: batch.grade_import_pending_rows.pending_student_match.count
        )
      end

      reconciled_count
    end

    private

    attr_reader :student
  end
end
