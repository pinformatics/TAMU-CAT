require "test_helper"
require "securerandom"

class GradeImports::MissingAssessmentsAnalyzerTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @other_student = students(:other_student)
    @semester = program_semesters(:fall_2025)
  end

  test "flags students missing a competency other students in the same course received" do
    batch = create_batch
    file = create_file(batch)
    create_evidence!(batch: batch, file: file, student: @student, course_code: "PHPM-601-700", competency_title: "Communication", fingerprint: "assessed-comm")
    create_evidence!(batch: batch, file: file, student: @student, course_code: "PHPM-601-700", competency_title: "Systems Thinking", fingerprint: "assessed-systems")
    create_evidence!(batch: batch, file: file, student: @other_student, course_code: "PHPM-601-700", competency_title: "Systems Thinking", fingerprint: "assessed-systems-other")

    summary = GradeImports::MissingAssessmentsAnalyzer.call(batch: batch)

    assert summary[:requires_review]
    group = summary[:groups].find { |g| g[:competency_title] == "Communication" }
    assert_equal "PHPM-601-700", group[:course_code]
    assert_equal 1, group[:missing_count]
    assert_equal 2, group[:roster_count]
    assert_equal 1, group[:assessed_count]
    assert_equal @other_student.user.name, group[:missing_students].first[:name]
  end

  test "does not flag a competency every roster student was assessed on" do
    batch = create_batch
    file = create_file(batch)
    create_evidence!(batch: batch, file: file, student: @student, course_code: "PHPM-602-700", competency_title: "Communication", fingerprint: "full-comm-1")
    create_evidence!(batch: batch, file: file, student: @other_student, course_code: "PHPM-602-700", competency_title: "Communication", fingerprint: "full-comm-2")

    summary = GradeImports::MissingAssessmentsAnalyzer.call(batch: batch)

    refute summary[:requires_review]
    assert_empty summary[:groups]
  end

  test "counts summarize affected students and courses" do
    batch = create_batch
    file = create_file(batch)
    create_evidence!(batch: batch, file: file, student: @student, course_code: "PHPM-603-700", competency_title: "Communication", fingerprint: "counts-comm")
    create_evidence!(batch: batch, file: file, student: @student, course_code: "PHPM-603-700", competency_title: "Ethics", fingerprint: "counts-ethics")
    create_evidence!(batch: batch, file: file, student: @other_student, course_code: "PHPM-603-700", competency_title: "Ethics", fingerprint: "counts-ethics-other")

    summary = GradeImports::MissingAssessmentsAnalyzer.call(batch: batch)

    assert_equal 1, summary.dig(:counts, :courses_affected)
    assert_equal 1, summary.dig(:counts, :groups)
    assert_equal 1, summary.dig(:counts, :students_affected)
  end

  private

  def create_batch
    GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: @semester,
      status: "completed",
      summary: { "dry_run" => true }
    )
  end

  def create_file(batch)
    batch.grade_import_files.create!(
      file_name: "missing-assessments.csv",
      file_checksum: "checksum-#{SecureRandom.hex(8)}",
      status: "processed",
      imported_rows: 1
    )
  end

  def create_evidence!(batch:, file:, student:, course_code:, competency_title:, fingerprint:)
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: student,
      assignment_name: "Final Project",
      course_code: course_code,
      competency_title: competency_title,
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: 3,
      row_number: 2,
      source_key: "source-#{fingerprint}",
      import_fingerprint: fingerprint
    )
  end
end
