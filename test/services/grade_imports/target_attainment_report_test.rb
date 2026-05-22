require "test_helper"

class GradeImports::TargetAttainmentReportTest < ActiveSupport::TestCase
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
      file_name: "target-report.csv",
      file_checksum: "checksum-target-report",
      status: "processed"
    )
  end

  test "labels target attainment statuses" do
    assert_equal :met, GradeImports::TargetAttainmentReport.status_for(4, 4)
    assert_equal :below_target, GradeImports::TargetAttainmentReport.status_for(3, 4)
    assert_equal :no_target, GradeImports::TargetAttainmentReport.status_for(3, nil)
    assert_equal "No - below target", GradeImports::TargetAttainmentReport.export_label(3, 4)
    assert_equal "Met", GradeImports::TargetAttainmentReport.ui_label(5, 4)
  end

  test "summarizes by course and competency" do
    create_evidence!("met", course_code: "PHPM-601", competency_title: "Policy Analysis", mapped_level: 5, course_target_level: 4)
    create_evidence!("below", course_code: "PHPM-601", competency_title: "Policy Analysis", mapped_level: 2, course_target_level: 4)
    create_evidence!("missing", course_code: "PHPM-601", competency_title: "Policy Analysis", mapped_level: 3, course_target_level: nil)

    summary = GradeImports::TargetAttainmentReport.new(@batch.grade_competency_evidences).by_course_and_competency.first

    assert_equal "PHPM-601", summary[:course_code]
    assert_equal "Policy Analysis", summary[:competency_title]
    assert_equal 3, summary[:total_count]
    assert_equal 1, summary[:met_count]
    assert_equal 1, summary[:below_count]
    assert_equal 1, summary[:no_target_count]
    assert_equal 50.0, summary[:met_rate]
    assert_equal 3.33, summary[:assessed_average]
    assert_equal 4.0, summary[:course_target_average]
  end

  test "summarizes reportable rows by semester course and competency" do
    create_evidence!("reportable", course_code: "PHPM-602", competency_title: "Systems Thinking", mapped_level: 4, course_target_level: 4)
    preview = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: @semester,
      status: "completed",
      summary: { "dry_run" => true }
    )
    preview_file = preview.grade_import_files.create!(
      file_name: "preview-target-report.csv",
      file_checksum: "checksum-preview-target-report",
      status: "processed"
    )
    preview.grade_competency_evidences.create!(
      grade_import_file: preview_file,
      student: @student,
      assignment_name: "Preview",
      course_code: "PHPM-602",
      competency_title: "Systems Thinking",
      raw_grade: 2,
      mapped_level: 2,
      course_target_level: 4,
      source_key: "preview-target-report",
      import_fingerprint: "fingerprint-preview-target-report"
    )

    reportable_scope = GradeCompetencyEvidence.where(grade_import_batch_id: GradeImportBatch.reportable.select(:id))
    summary = GradeImports::TargetAttainmentReport.new(reportable_scope).by_semester_course_and_competency.find do |row|
      row[:course_code] == "PHPM-602" && row[:competency_title] == "Systems Thinking"
    end

    assert_equal @semester.name, summary[:semester_name]
    assert_equal 1, summary[:total_count]
    assert_equal 1, summary[:met_count]
    assert_equal 0, summary[:below_count]
  end

  private

  def create_evidence!(suffix, course_code:, competency_title:, mapped_level:, course_target_level:)
    @batch.grade_competency_evidences.create!(
      grade_import_file: @file,
      student: @student,
      assignment_name: "Assignment #{suffix}",
      course_code: course_code,
      competency_title: competency_title,
      raw_grade: mapped_level,
      mapped_level: mapped_level,
      course_target_level: course_target_level,
      source_key: "target-report-#{suffix}",
      import_fingerprint: "fingerprint-target-report-#{suffix}"
    )
  end
end
