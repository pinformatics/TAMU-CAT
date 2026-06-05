require "test_helper"

class GradeImportPendingRowTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @semester = program_semesters(:fall_2025)
    @batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: @semester,
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )
    @file = @batch.grade_import_files.create!(
      file_name: "pending.csv",
      file_checksum: "pending-#{SecureRandom.hex(4)}",
      content_type: "text/csv",
      status: "processed"
    )
  end

  test "matching_student returns none without identifiers and matches uin email or name" do
    blank_student = Student.new
    assert_equal 0, GradeImportPendingRow.matching_student(blank_student).count

    uin_row = create_pending_row!(
      suffix: "uin",
      identifier: @student.uin,
      identifier_type: "uin",
      student_uin: @student.uin
    )
    email_row = create_pending_row!(
      suffix: "email",
      identifier: @student.user.email,
      identifier_type: "email",
      student_email: @student.user.email.upcase
    )
    name_row = create_pending_row!(
      suffix: "name",
      identifier: @student.user.name,
      identifier_type: "student_name",
      student_name: @student.user.name.upcase
    )
    reconciled_row = create_pending_row!(
      suffix: "reconciled",
      identifier: @student.uin,
      identifier_type: "uin",
      student_uin: @student.uin,
      status: "reconciled"
    )

    matches = GradeImportPendingRow.matching_student(@student)

    assert_includes matches, uin_row
    assert_includes matches, email_row
    assert_includes matches, name_row
    refute_includes matches, reconciled_row
  end

  test "pending row syncs competency and course offering references when available" do
    domain = Domain.find_or_create_by!(name: "Management Skills")
    competency = Competency.find_or_create_by!(title: "Communication") do |record|
      record.domain = domain
      record.position = 1
    end

    row = create_pending_row!(
      suffix: "refs",
      identifier: "999888777",
      identifier_type: "uin",
      student_uin: "999888777",
      competency_title: competency.title,
      course_code: "PHPM-633-700"
    )

    assert_equal competency, row.competency
    assert row.course_offering.present?
    assert_equal @semester, row.course_offering.program_semester
  end

  test "pending row sync skips blank fields and tolerates missing import context" do
    blank_row = @batch.grade_import_pending_rows.build(
      grade_import_file: @file,
      status: "pending_student_match",
      student_identifier: "999888777",
      student_identifier_type: "uin",
      student_uin: "999888777",
      competency_title: "",
      course_code: "",
      assignment_name: "Assignment blank context",
      raw_grade: 95,
      mapped_level: 4,
      row_number: 3,
      source_key: "pending-blank-context",
      import_fingerprint: "pending-blank-context"
    )

    refute blank_row.valid?
    assert_nil blank_row.competency
    assert_nil blank_row.course_offering

    row = GradeImportPendingRow.new(
      grade_import_batch: nil,
      grade_import_file: nil,
      status: "pending_student_match",
      student_identifier: "999888776",
      student_identifier_type: "uin",
      student_uin: "999888776",
      competency_title: "Unmatched Pending Competency",
      course_code: "PHPM-606",
      assignment_name: "Assignment missing context",
      raw_grade: 95,
      mapped_level: 4,
      row_number: 3,
      source_key: "pending-missing-context",
      import_fingerprint: "pending-missing-context"
    )

    refute row.valid?
    assert_equal "PHPM-606", row.course_offering&.display_code
    assert_nil row.course_offering&.program_semester
  end

  private

  def create_pending_row!(suffix:, identifier:, identifier_type:, student_uin: nil, student_email: nil, student_name: nil, status: "pending_student_match", competency_title: "Policy Analysis", course_code: "PHPM-601")
    @batch.grade_import_pending_rows.create!(
      grade_import_file: @file,
      status: status,
      student_identifier: identifier,
      student_identifier_type: identifier_type,
      student_uin: student_uin,
      student_email: student_email,
      student_name: student_name,
      competency_title: competency_title,
      course_code: course_code,
      assignment_name: "Assignment #{suffix}",
      raw_grade: 95,
      mapped_level: 4,
      row_number: 2,
      source_key: "pending-source-#{suffix}",
      import_fingerprint: "pending-fingerprint-#{suffix}"
    )
  end
end
