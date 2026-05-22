require "test_helper"
require "csv"

class StudentCompetencyHistoryExporterTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
  end

  test "csv includes course evidence and derived rating history" do
    create_import_history

    csv = CSV.parse(StudentCompetencyHistoryExporter.new(student: @student).csv, headers: true)

    assert_equal 2, csv.length
    assert_equal "Course evidence", csv.first["Source Type"]
    assert_equal "Fall 2025", csv.first["Semester"]
    assert_equal "PHPM-601", csv.first["Course"]
    assert_equal "Yes", csv.first["Target Met"]
    assert_equal "Derived course rating", csv[1]["Source Type"]
    assert_equal "Aggregated max", csv[1]["Assignment"]
  end

  private

  def create_import_history
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = GradeImportFile.create!(
      grade_import_batch: batch,
      file_name: "Outcomes-26S-PHPM-601.csv",
      file_checksum: "history-export-test",
      status: "processed"
    )
    GradeCompetencyEvidence.create!(
      grade_import_batch: batch,
      grade_import_file: file,
      student: @student,
      competency_title: competency_title,
      course_code: "PHPM-601",
      assignment_name: "Course outcome",
      raw_grade: 4,
      mapped_level: 4,
      course_target_level: 3,
      source_key: "history-export-test",
      import_fingerprint: "history-export-test"
    )
    GradeCompetencyRating.create!(
      grade_import_batch: batch,
      student: @student,
      competency_title: competency_title,
      aggregated_level: 4,
      aggregation_rule: "max",
      evidence_count: 1
    )
  end
end
