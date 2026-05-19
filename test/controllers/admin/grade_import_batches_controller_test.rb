require "test_helper"
require "csv"

class Admin::GradeImportBatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = students(:student)
    sign_in @admin
  end

  test "requires admin role for index" do
    sign_out @admin
    sign_in @advisor

    get admin_grade_import_batches_path

    assert_redirected_to dashboard_path
    assert_match(/access denied/i, flash[:alert].to_s)
  end

  test "commit flips a completed dry run into a reportable batch" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => true }
    )

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.reportable?
    assert_equal false, ActiveModel::Type::Boolean.new.cast(batch.summary["dry_run"])
    assert_equal @admin.email, batch.summary["committed_by"]
  end

  test "preview with failed or pending rows must be approved before commit" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )
    batch.grade_import_files.create!(
      file_name: "needs-approval.csv",
      file_checksum: "checksum-needs-approval",
      status: "processed",
      imported_rows: 1,
      pending_rows: 1,
      error_rows: 1,
      parse_errors: [ { "row" => 2, "message" => "Missing student" } ]
    )

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.dry_run?
    assert_match "approve", flash[:alert].to_s.downcase

    post approve_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.admin_approved?
    assert_equal @admin.email, batch.summary["admin_approved_by"]

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.reportable?
    assert_equal @admin.email, batch.summary["committed_by"]
  end

  test "rollback hides a committed batch and recommit restores it" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "sample.xlsx",
      file_checksum: "checksum-1",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Case Study",
      course_code: "PHPM-700-001",
      competency_title: "Policy Analysis",
      raw_grade: 95,
      mapped_level: 5,
      row_number: 3,
      source_key: "source-1",
      import_fingerprint: "fingerprint-1"
    )

    post rollback_admin_grade_import_batch_path(batch)
    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.rolled_back?
    refute batch.reportable?

    post recommit_admin_grade_import_batch_path(batch)
    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal "completed", batch.reload.status
    assert batch.reportable?
    assert_equal @admin.email, batch.summary["recommitted_by"]
  end

  test "semester action assigns legacy batch to a program semester" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )

    patch semester_admin_grade_import_batch_path(batch), params: {
      program_semester_id: program_semesters(:fall_2025).id
    }

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal program_semesters(:fall_2025), batch.reload.program_semester
    assert_match "Batch semester updated", flash[:notice]
  end

  test "export ratings returns formatted csv only" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "sample.xlsx",
      file_checksum: "checksum-csv-format",
      status: "processed"
    )

    evidence = batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Case Study",
      course_code: "PHPM-700-001",
      competency_title: "Policy Analysis",
      raw_grade: 95,
      mapped_level: 5,
      row_number: 3,
      source_key: "source-csv-format",
      import_fingerprint: "fingerprint-csv-format"
    )

    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: "Policy Analysis",
      aggregated_level: 5,
      aggregation_rule: "max",
      evidence_count: 1
    )

    get export_ratings_admin_grade_import_batch_path(batch, format: :csv)

    assert_response :success
    parsed = CSV.parse(response.body, headers: true)
    assert_equal [
      "Student ID",
      "Student Name",
      "Student Email",
      "Competency",
      "Aggregated Level",
      "Aggregation Rule",
      "Contributing Grades",
      "Latest Evidence Updated At",
      "Course Codes",
      "Assignments",
      "Source Files",
      "Provenance Details"
    ], parsed.headers

    first_row = parsed.first
    assert_equal @student.student_id.to_s, first_row["Student ID"]
    assert_equal "Policy Analysis", first_row["Competency"]
    assert_equal "max", first_row["Aggregation Rule"]
    assert_equal "PHPM-700-001", first_row["Course Codes"]
    assert_equal "Case Study", first_row["Assignments"]
    assert_equal "sample.xlsx", first_row["Source Files"]
    assert_includes first_row["Provenance Details"], "raw=95.0"
    assert_equal evidence.updated_at.iso8601, first_row["Latest Evidence Updated At"]

    get export_ratings_admin_grade_import_batch_path(batch, format: :xlsx)
    assert_response :not_acceptable
  end

  test "show displays course target levels for evidence rows" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "target-sample.xlsx",
      file_checksum: "checksum-target-show",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Target Case",
      course_code: "PHPM-701-001",
      competency_title: "Performance Improvement",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 7,
      source_key: "source-target-show",
      import_fingerprint: "fingerprint-target-show"
    )
    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: "Performance Improvement",
      aggregated_level: 3,
      aggregation_rule: "max",
      evidence_count: 1
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Detected Format"
    assert_includes response.body, "Course Target"
    assert_includes response.body, "PHPM-701-001"
    assert_includes response.body, "UIN #{@student.uin}"
    refute_includes response.body, "ID #{@student.student_id}"
    assert_select ".c-score-pill--program", text: "4"
  end

  test "show explains semester scope and duplicate diagnostics" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )
    batch.grade_import_files.create!(
      file_name: "direct.xlsx",
      file_checksum: "checksum-guidance",
      status: "processed",
      parsed_content: {
        "mode" => "direct_competency",
        "grade_sheet_debug" => { "duplicate_warning_count" => 2 }
      }
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "reportable for"
    assert_includes response.body, "Fall 2025"
    assert_includes response.body, "Direct competency"
    assert_includes response.body, "Duplicate rows are suppressed"
  end

  test "show displays import notes, correction link, validation summary, and mapping preview" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: {
        "dry_run" => true,
        "import_notes" => "Canvas export from PHPM 631 after final grades."
      }
    )
    batch.grade_import_files.create!(
      file_name: "mapping-preview.xlsx",
      file_checksum: "checksum-mapping-preview",
      status: "processed",
      total_rows: 2,
      imported_rows: 1,
      pending_rows: 1,
      error_rows: 1,
      parse_errors: [ { "row" => 4, "message" => "Unknown competency_title 'Bad Competency'" } ],
      parsed_content: {
        "mode" => "canvas",
        "selected_grade_sheet" => "PHPM_631_600",
        "selected_mapping_sheet" => "mapping",
        "mapping_rows_preview" => [
          {
            "source_row_number" => 2,
            "assignment_match_type" => "exact",
            "assignment_match_value" => "Final Project",
            "course_code" => "PHPM-631-600",
            "competency_title" => "Policy Analysis",
            "score_basis" => "points",
            "min_grade" => 90,
            "max_grade" => 100,
            "competency_level" => 5
          }
        ],
        "grade_sheet_debug" => {
          "mode" => "canvas",
          "student_identifier_column" => 2,
          "assignment_columns_preview" => [ { "index" => 5, "name" => "Final Project" } ],
          "matched_student_count" => 1,
          "duplicate_warning_count" => 0
        }
      }
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Import notes:"
    assert_includes response.body, "Canvas export from PHPM 631"
    assert_includes response.body, "Correction file"
    assert_includes response.body, "Preview validation:"
    assert_includes response.body, "Column Mapping Preview"
    assert_includes response.body, "Final Project"
    assert_includes response.body, "Policy Analysis"
    assert_includes response.body, "Unknown competency_title"
  end

  test "show renders pending student matches as compact student list" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "pending-students.xlsx",
      file_checksum: "checksum-pending-students",
      status: "processed"
    )
    batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_name: "Missing Student",
      student_uin: "123456789",
      assignment_name: "Hidden Assignment",
      course_code: "PHPM-701-001",
      competency_title: "Performance Improvement",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 7,
      source_key: "source-pending-students",
      import_fingerprint: "fingerprint-pending-students"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Missing Student"
    assert_includes response.body, "123456789"
    refute_includes response.body, "Hidden Assignment"
    refute_includes response.body, "PHPM-701-001"
  end

  test "correction file includes failed parse errors and pending student rows" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "corrections.xlsx",
      file_checksum: "checksum-corrections",
      status: "processed",
      parse_errors: [ { "row" => 5, "message" => "grade is not numeric" } ],
      error_rows: 1
    )
    batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "999999999",
      student_identifier_type: "uin",
      student_name: "Missing Student",
      student_uin: "999999999",
      assignment_name: "Final Project",
      course_code: "PHPM-631-600",
      competency_title: "Policy Analysis",
      raw_grade: 88,
      mapped_level: 4,
      course_target_level: 5,
      row_number: 6,
      source_key: "source-corrections",
      import_fingerprint: "fingerprint-corrections"
    )

    get correction_file_admin_grade_import_batch_path(batch, format: :csv)

    assert_response :success
    parsed = CSV.parse(response.body, headers: true)

    assert_equal "failed", parsed[0]["Row Type"]
    assert_equal "grade is not numeric", parsed[0]["Message"]
    assert_equal "pending_student_match", parsed[1]["Row Type"]
    assert_equal "Missing Student", parsed[1]["Student Name"]
    assert_equal "PHPM-631-600", parsed[1]["Course Code"]
    assert_equal "5", parsed[1]["Course Target Level"]
  end

  test "destroy deletes batch import rows and frees duplicate fingerprints" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "duplicate-reset.xlsx",
      file_checksum: "checksum-duplicate-reset",
      status: "processed"
    )
    evidence = batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Duplicate Reset",
      course_code: "PHPM-701-001",
      competency_title: "Performance Improvement",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 7,
      source_key: "source-duplicate-reset",
      import_fingerprint: "fingerprint-duplicate-reset"
    )
    rating = batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: "Performance Improvement",
      aggregated_level: 3,
      aggregation_rule: "max",
      evidence_count: 1
    )

    assert_difference "GradeImportBatch.count", -1 do
      delete admin_grade_import_batch_path(batch)
    end

    assert_redirected_to admin_grade_import_batches_path
    refute GradeImportFile.exists?(file.id)
    refute GradeCompetencyEvidence.exists?(evidence.id)
    refute GradeCompetencyRating.exists?(rating.id)

    replacement_batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    replacement_file = replacement_batch.grade_import_files.create!(
      file_name: "duplicate-reset.xlsx",
      file_checksum: "checksum-duplicate-reset-2",
      status: "processed"
    )

    replacement = replacement_batch.grade_competency_evidences.create!(
      grade_import_file: replacement_file,
      student: @student,
      assignment_name: "Duplicate Reset",
      course_code: "PHPM-701-001",
      competency_title: "Performance Improvement",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 7,
      source_key: "source-duplicate-reset",
      import_fingerprint: "fingerprint-duplicate-reset"
    )

    assert replacement.persisted?
  end

  test "rollback and recommit toggle matrix visibility for batch-derived ratings" do
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )

    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: competency_title,
      aggregated_level: 4.0,
      aggregation_rule: "max",
      evidence_count: 1
    )

    visible_payload = Admin::CompetencyMatrix.new(params: {}, actor_user: @admin).call
    visible_row = visible_payload[:students].find { |row| row[:id] == @student.student_id }
    assert_in_delta 4.0, visible_row.dig(:ratings, competency_title, :course_rating), 0.001

    post rollback_admin_grade_import_batch_path(batch)
    assert_redirected_to admin_grade_import_batch_path(batch)

    hidden_payload = Admin::CompetencyMatrix.new(params: {}, actor_user: @admin).call
    hidden_row = hidden_payload[:students].find { |row| row[:id] == @student.student_id }
    assert_nil hidden_row.dig(:ratings, competency_title, :course_rating)

    post recommit_admin_grade_import_batch_path(batch)
    assert_redirected_to admin_grade_import_batch_path(batch)

    restored_payload = Admin::CompetencyMatrix.new(params: {}, actor_user: @admin).call
    restored_row = restored_payload[:students].find { |row| row[:id] == @student.student_id }
    assert_in_delta 4.0, restored_row.dig(:ratings, competency_title, :course_rating), 0.001
  end
end
