require "test_helper"
require "securerandom"

class GradeImports::TargetWarningAnalyzerTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @semester = program_semesters(:fall_2025)
  end

  test "matching configured course target does not require review" do
    competency = create_competency!("Configured Target Match")
    create_configured_target!("PHPM-640-700", competency, 4)
    batch = create_batch
    file = create_file(batch)
    create_evidence!(
      batch: batch,
      file: file,
      course_code: "PHPM-640-700",
      competency_title: competency.title,
      course_target_level: 4,
      fingerprint: "fingerprint-configured-target-match"
    )

    summary = GradeImports::TargetWarningAnalyzer.call(batch: batch)

    refute summary[:requires_review]
    assert_equal 0, summary.dig(:counts, :mismatched_configured_course_targets)
    assert_empty summary[:mismatched_configured_course_targets]
  end

  test "different configured course target requires review" do
    competency = create_competency!("Configured Target Mismatch")
    create_configured_target!("PHPM-641-700", competency, 3)
    batch = create_batch
    file = create_file(batch)
    create_evidence!(
      batch: batch,
      file: file,
      course_code: "PHPM-641-700",
      competency_title: competency.title,
      course_target_level: 5,
      fingerprint: "fingerprint-configured-target-mismatch"
    )

    summary = GradeImports::TargetWarningAnalyzer.call(batch: batch)
    mismatch = summary[:mismatched_configured_course_targets].first

    assert summary[:requires_review]
    assert_equal 1, summary.dig(:counts, :mismatched_configured_course_targets)
    assert_equal "PHPM-641-700", mismatch[:course_code]
    assert_equal competency.title, mismatch[:competency]
    assert_equal 5, mismatch[:course_target]
    assert_equal 3, mismatch[:configured_course_target]
  end

  test "pending matched rows are compared to configured course targets" do
    competency = create_competency!("Configured Pending Target")
    create_configured_target!("PHPM-642-700", competency, 2)
    batch = create_batch
    file = create_file(batch)

    batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      matched_student: @student,
      student_identifier: @student.uin,
      student_identifier_type: "uin",
      student_name: @student.user.name,
      student_uin: @student.uin,
      assignment_name: "Final Project",
      course_code: "PHPM-642-700",
      competency_title: competency.title,
      raw_grade: 88,
      mapped_level: 4,
      course_target_level: 4,
      row_number: 6,
      source_key: "source-pending-target-mismatch",
      import_fingerprint: "fingerprint-pending-target-mismatch"
    )

    summary = GradeImports::TargetWarningAnalyzer.call(batch: batch)
    mismatch = summary[:mismatched_configured_course_targets].first

    assert summary[:requires_review]
    assert_equal "pending", mismatch[:row_type]
    assert_equal 4, mismatch[:course_target]
    assert_equal 2, mismatch[:configured_course_target]
  end

  test "missing configured target table does not crash warning analysis" do
    competency = create_competency!("Configured Target Missing Table")
    batch = create_batch
    file = create_file(batch)
    create_evidence!(
      batch: batch,
      file: file,
      course_code: "PHPM-643-700",
      competency_title: competency.title,
      course_target_level: 4,
      fingerprint: "fingerprint-configured-target-table-missing"
    )

    connection = ActiveRecord::Base.connection
    original_data_source_exists = connection.method(:data_source_exists?)

    connection.stub(:data_source_exists?, ->(table_name) {
      table_name.to_s == "course_competency_targets" ? false : original_data_source_exists.call(table_name)
    }) do
      summary = GradeImports::TargetWarningAnalyzer.call(batch: batch)

      refute summary[:requires_review]
      assert_equal 0, summary.dig(:counts, :mismatched_configured_course_targets)
      assert_empty summary[:mismatched_configured_course_targets]
    end
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
      file_name: "configured-target-warning.csv",
      file_checksum: "checksum-#{SecureRandom.hex(8)}",
      status: "processed",
      imported_rows: 1
    )
  end

  def create_evidence!(batch:, file:, course_code:, competency_title:, course_target_level:, fingerprint:)
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: course_code,
      competency_title: competency_title,
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: course_target_level,
      row_number: 2,
      source_key: "source-#{fingerprint}",
      import_fingerprint: fingerprint
    )
  end

  def create_configured_target!(course_code, competency, target_level)
    offering = CourseOffering.find_or_create_from_code!(course_code, program_semester: @semester)
    CourseCompetencyTarget.create!(
      course_offering: offering,
      competency: competency,
      target_level: target_level
    )
  end

  def create_competency!(title)
    domain = Domain.find_or_create_by!(name: "Configured Target Test Domain") do |record|
      record.position = 210
    end

    Competency.find_or_create_by!(title: title) do |record|
      record.domain = domain
      record.position = 210
    end
  end
end
