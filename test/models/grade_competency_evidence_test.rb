require "test_helper"

class GradeCompetencyEvidenceTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @semester = program_semesters(:fall_2025)
    @batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: @semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    @file = @batch.grade_import_files.create!(
      file_name: "evidence-model.csv",
      file_checksum: "evidence-model-checksum",
      status: "processed"
    )
  end

  test "syncs competency and course offering references when source fields are present" do
    competency = create_competency!("Evidence Sync Competency")

    evidence = GradeCompetencyEvidence.create!(
      grade_import_batch: @batch,
      grade_import_file: @file,
      student: @student,
      competency_title: competency.title,
      course_code: "PHPM-633-700",
      assignment_name: "Outcome",
      raw_grade: 4,
      mapped_level: 4,
      course_target_level: 3,
      source_key: "evidence-sync",
      import_fingerprint: "evidence-sync"
    )

    assert_equal competency, evidence.competency
    assert_equal "PHPM-633-700", evidence.course_offering.display_code
    assert_equal @semester, evidence.course_offering.program_semester
  end

  test "sync callbacks skip blank titles blank course codes and unchanged references" do
    evidence = GradeCompetencyEvidence.new(
      grade_import_batch: @batch,
      grade_import_file: @file,
      student: @student,
      competency_title: "",
      course_code: "",
      assignment_name: "Outcome",
      raw_grade: 4,
      mapped_level: 4,
      source_key: "evidence-blank",
      import_fingerprint: "evidence-blank"
    )

    evidence.valid?
    assert_nil evidence.competency
    assert_nil evidence.course_offering

    competency = create_competency!("Evidence Existing Competency")
    offering = CourseOffering.find_or_create_from_code!("PHPM-601", program_semester: @semester)
    evidence.competency = competency
    evidence.course_offering = offering
    evidence.competency_title = competency.title
    evidence.course_code = offering.display_code
    evidence.save!

    evidence.assignment_name = "Updated outcome"
    assert evidence.valid?
    assert_equal competency, evidence.competency
    assert_equal offering, evidence.course_offering
  end

  test "course offering sync tolerates missing batch semester and source file" do
    evidence = GradeCompetencyEvidence.new(
      grade_import_batch: nil,
      grade_import_file: nil,
      student: @student,
      competency_title: "Unmatched Evidence Competency",
      course_code: "PHPM-602",
      assignment_name: "Outcome",
      raw_grade: 4,
      mapped_level: 4,
      source_key: "evidence-missing-context",
      import_fingerprint: "evidence-missing-context"
    )

    refute evidence.valid?
    assert_equal "PHPM-602", evidence.course_offering&.display_code
    assert_nil evidence.course_offering&.program_semester
  end

  private

  def create_competency!(title)
    domain = Domain.find_or_create_by!(name: "Evidence Sync Domain") { |record| record.position = 300 }
    Competency.find_or_create_by!(title: title) do |record|
      record.domain = domain
      record.position = 300
    end
  end
end
