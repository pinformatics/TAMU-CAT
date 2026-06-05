require "test_helper"
require "securerandom"

class GradeImports::ScorebookAndReconcilerTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @semester = program_semesters(:fall_2025)
  end

  test "derived scorebook groups reportable evidence by student and competency" do
    batch = create_batch(dry_run: false)
    file = create_file(batch, "scorebook.csv")
    create_evidence!(
      batch: batch,
      file: file,
      competency_title: "Policy Analysis",
      course_code: "PHPM-601",
      assignment_name: "Midterm",
      mapped_level: 2,
      course_target_level: 3,
      fingerprint: "scorebook-low"
    )
    create_evidence!(
      batch: batch,
      file: file,
      competency_title: "Policy Analysis",
      course_code: "PHPM-602",
      assignment_name: "Final",
      mapped_level: 5,
      course_target_level: 4,
      fingerprint: "scorebook-high"
    )

    scorebook = GradeImports::DerivedScorebook.for_student(@student)
    entry = scorebook.fetch("Policy Analysis")

    assert_equal 5, entry[:aggregated_level]
    assert_equal 2, entry[:evidence_count]
    assert entry[:latest_updated_at].present?
    assert_equal [ "PHPM-601", "PHPM-602" ], entry[:provenance].map { |row| row[:course_code] }
    assert_equal "scorebook.csv", entry[:provenance].first[:import_file]
  end

  test "derived scorebook ignores dry run batches and empty student lists" do
    batch = create_batch(dry_run: true)
    file = create_file(batch, "dry-run.csv")
    create_evidence!(
      batch: batch,
      file: file,
      competency_title: "Communication",
      course_code: "PHPM-603",
      assignment_name: "Presentation",
      mapped_level: 5,
      course_target_level: 4,
      fingerprint: "scorebook-dry-run"
    )

    assert_empty GradeImports::DerivedScorebook.for_student(@student)
    assert_empty GradeImports::DerivedScorebook.for_students([])
  end

  test "pending row reconciler creates evidence, rebuilds ratings, and updates counts" do
    batch = create_batch(dry_run: true)
    file = create_file(batch, "pending.csv")
    competency = create_competency!("Pending Reconciler Competency")
    offering = CourseOffering.find_or_create_from_code!("PHPM-604-700", program_semester: @semester)
    pending = batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      matched_student: nil,
      student_identifier: @student.uin,
      student_identifier_type: "uin",
      student_name: @student.user.name,
      student_uin: @student.uin,
      student_email: @student.user.email,
      assignment_name: "Capstone",
      course_code: "PHPM-604-700",
      competency: competency,
      course_offering: offering,
      competency_title: competency.title,
      raw_grade: 88,
      mapped_level: 4,
      course_target_level: 3,
      row_number: 9,
      source_key: "pending-reconciler",
      import_fingerprint: "fingerprint-pending-reconciler"
    )

    assert_difference -> { batch.grade_competency_evidences.count }, 1 do
      assert_equal 1, GradeImports::PendingRowReconciler.call(student: @student)
    end

    pending.reload
    evidence = batch.grade_competency_evidences.find_by!(source_key: "pending-reconciler")

    assert_equal "reconciled", pending.status
    assert_equal @student.student_id, pending.matched_student_id
    assert_equal competency.id, evidence.competency_id
    assert_equal offering.id, evidence.course_offering_id
    assert_equal pending.id, evidence.metadata["pending_row_id"]
    assert_equal 1, batch.reload.evidence_count
    assert_equal 1, batch.rating_count
    assert_equal 0, batch.pending_count

    rating = batch.grade_competency_ratings.find_by!(student_id: @student.student_id, competency_title: competency.title)
    assert_equal 4, rating.aggregated_level
    assert_equal 1, rating.evidence_count
  end

  test "pending row reconciler returns zero for blank student" do
    assert_equal 0, GradeImports::PendingRowReconciler.call(student: nil)
  end

  private

  def create_batch(dry_run:)
    GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: @semester,
      status: "completed",
      summary: { "dry_run" => dry_run }
    )
  end

  def create_file(batch, name)
    batch.grade_import_files.create!(
      file_name: name,
      file_checksum: "checksum-#{name}-#{SecureRandom.hex(4)}",
      status: "processed"
    )
  end

  def create_evidence!(batch:, file:, competency_title:, course_code:, assignment_name:, mapped_level:, course_target_level:, fingerprint:)
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: assignment_name,
      course_code: course_code,
      competency_title: competency_title,
      raw_grade: mapped_level,
      mapped_level: mapped_level,
      course_target_level: course_target_level,
      row_number: 2,
      source_key: "source-#{fingerprint}",
      import_fingerprint: "fingerprint-#{fingerprint}"
    )
  end

  def create_competency!(title)
    domain = Domain.find_or_create_by!(name: "Reconciler Test Domain") do |record|
      record.position = 220
    end

    Competency.find_or_create_by!(title: title) do |record|
      record.domain = domain
      record.position = 220
    end
  end
end
