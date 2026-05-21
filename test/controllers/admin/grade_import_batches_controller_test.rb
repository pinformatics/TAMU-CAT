require "test_helper"
require "csv"
require "fileutils"
require "rack/test"
require "tempfile"

class Admin::GradeImportBatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = students(:student)
    @temp_paths = []
    sign_in @admin
  end

  teardown do
    @temp_paths.each { |path| FileUtils.rm_f(path) }
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

  test "show displays import notes, correction link, review prompt, and mapping preview" do
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
          "pending_student_count" => 1,
          "pending_row_count" => 1,
          "duplicate_warning_count" => 0
        }
      }
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Import notes:"
    assert_includes response.body, "Canvas export from PHPM 631"
    assert_includes response.body, "Correction file"
    assert_includes response.body, "Admin approval required:"
    refute_includes response.body, "Preview validation:"
    assert_includes response.body, "Import Review"
    assert_includes response.body, "Detected format"
    assert_includes response.body, "Course detected"
    assert_includes response.body, "Student rows scanned"
    assert_includes response.body, "Students matched"
    assert_includes response.body, "Students needing match"
    assert_includes response.body, "Competency values needing match"
    assert_includes response.body, "Final Project"
    assert_includes response.body, "Policy Analysis"
    assert_includes response.body, "Unknown competency_title"
  end

  test "sample action downloads guided import examples" do
    get sample_admin_grade_import_batches_path(kind: "success")

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Policy Analysis result"
    assert_includes response.body, "Policy Analysis mastery points"

    get sample_admin_grade_import_batches_path(kind: "pending_match")

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Unmatched Canvas Student"

    get sample_admin_grade_import_batches_path(kind: "bad_mapping")

    assert_response :success
    assert_equal "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", response.media_type
    assert response.body.bytes.first(2).pack("C*") == "PK"
  end

  test "missing uploaded course targets require approval before commit" do
    competency_title = "Policy Analysis"
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "target-warning.csv",
      file_checksum: "checksum-target-warning",
      status: "processed",
      imported_rows: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: "PHPM-631-600",
      competency_title: competency_title,
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: nil,
      row_number: 2,
      source_key: "source-target-warning",
      import_fingerprint: "fingerprint-target-warning"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Target Warnings Before Commit"
    assert_includes response.body, "Missing Uploaded Course Targets"
    refute_includes response.body, "Imported Target Mismatches"
    refute_includes response.body, "Configured Target"

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.dry_run?
    assert_match "target-warning", flash[:alert]

    post approve_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.admin_approved?

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.reportable?
  end

  test "uploaded course targets do not require configured target records" do
    competency_title = "Policy Analysis"
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "uploaded-target.csv",
      file_checksum: "checksum-uploaded-target",
      status: "processed",
      imported_rows: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: "PHPM-631-600",
      competency_title: competency_title,
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: 5,
      row_number: 2,
      source_key: "source-uploaded-target",
      import_fingerprint: "fingerprint-uploaded-target"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    refute_includes response.body, "Target Warnings Before Commit"
    refute_includes response.body, "Admin approval required:"

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.reportable?
  end

  test "show renders pending student matches with manual correction controls" do
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
    assert_includes response.body, "Pending Student Matches"
    assert_includes response.body, "Missing Student"
    assert_includes response.body, "123456789"
    assert_includes response.body, "Hidden Assignment"
    assert_includes response.body, "PHPM-701-001"
    assert_includes response.body, "Match all rows to student"
    assert_includes response.body, "Processed values"
    assert_includes response.body, "Save grouped correction"
    assert_includes response.body, pending_row_group_admin_grade_import_batch_path(batch)
  end

  test "show groups repeated pending rows for the same imported student" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "pending-students-grouped.xlsx",
      file_checksum: "checksum-pending-students-grouped",
      status: "processed"
    )

    %w[Policy\ Analysis Communication].each_with_index do |competency_title, index|
      batch.grade_import_pending_rows.create!(
        grade_import_file: file,
        student_identifier: "Missing Student",
        student_identifier_type: "student_name",
        student_name: "Missing Student",
        student_uin: "123456789",
        assignment_name: "Hidden Assignment",
        course_code: "PHPM-701-001",
        competency_title: competency_title,
        raw_grade: 88 + index,
        mapped_level: 3,
        course_target_level: 4,
        row_number: 7 + index,
        source_key: "source-pending-grouped-#{index}",
        import_fingerprint: "fingerprint-pending-grouped-#{index}"
      )
    end

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_select "summary.c-accordion__summary .c-accordion__title", text: "Missing Student", count: 1
    assert_includes response.body, "2 pending rows"
    assert_includes response.body, "Policy Analysis"
    assert_includes response.body, "Communication"
  end

  test "pending row correction can match a student and rebuild ratings" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "pending-correction.xlsx",
      file_checksum: "checksum-pending-correction",
      status: "processed",
      pending_rows: 1
    )
    row = batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "Missing Student",
      student_identifier_type: "student_name",
      student_name: "Missing Student",
      student_uin: "000000000",
      assignment_name: "Hidden Assignment",
      course_code: "PHPM-701-001",
      competency_title: "Performance Improvement",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 7,
      source_key: "source-pending-correction",
      import_fingerprint: "fingerprint-pending-correction"
    )

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      patch pending_row_admin_grade_import_batch_path(batch, row), params: {
        grade_import_pending_row: {
          matched_student_id: @student.student_id,
          student_identifier: "123456789",
          student_identifier_type: "uin",
          student_name: @student.user.name,
          student_uin: @student.uin,
          student_email: @student.user.email,
          assignment_name: "Corrected Assignment",
          course_code: "PHPM-701-001",
          competency_title: "Performance Improvement",
          raw_grade: 92,
          mapped_level: 5,
          course_target_level: 4
        }
      }
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal "reconciled", row.reload.status
    assert_equal @student.student_id, row.matched_student_id
    assert_not_nil row.reconciled_at

    evidence = GradeCompetencyEvidence.find_by!(source_key: "source-pending-correction")
    assert_equal @student.student_id, evidence.student_id
    assert_equal "Corrected Assignment", evidence.assignment_name
    assert_equal 5, evidence.mapped_level

    rating = batch.grade_competency_ratings.find_by!(student: @student, competency_title: "Performance Improvement")
    assert_equal 5, rating.aggregated_level.to_i
    assert_equal 1, rating.evidence_count
    assert_equal 1, file.reload.imported_rows
    assert_equal 0, file.pending_rows
    assert_equal 0, batch.reload.pending_count
  end

  test "pending row group correction can match all rows for one imported student" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "pending-group-correction.xlsx",
      file_checksum: "checksum-pending-group-correction",
      status: "processed",
      pending_rows: 2
    )
    first_row = batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "Missing Student",
      student_identifier_type: "student_name",
      student_name: "Missing Student",
      student_uin: "000000000",
      assignment_name: "Hidden Assignment 1",
      course_code: "PHPM-701-001",
      competency_title: "Performance Improvement",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 7,
      source_key: "source-pending-group-correction-1",
      import_fingerprint: "fingerprint-pending-group-correction-1"
    )
    second_row = batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "Missing Student",
      student_identifier_type: "student_name",
      student_name: "Missing Student",
      student_uin: "000000000",
      assignment_name: "Hidden Assignment 2",
      course_code: "PHPM-701-001",
      competency_title: "Communication",
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: 5,
      row_number: 8,
      source_key: "source-pending-group-correction-2",
      import_fingerprint: "fingerprint-pending-group-correction-2"
    )

    assert_difference -> { GradeCompetencyEvidence.count }, 2 do
      patch pending_row_group_admin_grade_import_batch_path(batch), params: {
        pending_row_ids: [ first_row.id, second_row.id ],
        grade_import_pending_row_group: {
          matched_student_id: @student.student_id,
          student_identifier: @student.uin,
          student_identifier_type: "uin",
          student_name: @student.user.name,
          student_uin: @student.uin,
          student_email: @student.user.email
        },
        pending_rows: {
          first_row.id => {
            assignment_name: "Corrected Assignment 1",
            course_code: "PHPM-701-001",
            competency_title: "Performance Improvement",
            raw_grade: 92,
            mapped_level: 5,
            course_target_level: 4
          },
          second_row.id => {
            assignment_name: "Corrected Assignment 2",
            course_code: "PHPM-701-001",
            competency_title: "Communication",
            raw_grade: 94,
            mapped_level: 5,
            course_target_level: 5
          }
        }
      }
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal "reconciled", first_row.reload.status
    assert_equal "reconciled", second_row.reload.status
    assert_equal 2, file.reload.imported_rows
    assert_equal 0, file.pending_rows
    assert_equal 0, batch.reload.pending_count
    assert_equal 2, batch.grade_competency_ratings.count
    assert_match "Matched 2 pending rows", flash[:notice]
  end

  test "rebuild ratings action recalculates derived competency ratings" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "rebuild.xlsx",
      file_checksum: "checksum-rebuild",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Rebuild Assignment",
      course_code: "PHPM-701-001",
      competency_title: "Performance Improvement",
      raw_grade: 82,
      mapped_level: 2,
      course_target_level: 4,
      row_number: 7,
      source_key: "source-rebuild",
      import_fingerprint: "fingerprint-rebuild"
    )
    stale_rating = batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: "Performance Improvement",
      aggregated_level: 5,
      aggregation_rule: "max",
      evidence_count: 99
    )

    post rebuild_ratings_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    refute GradeCompetencyRating.exists?(stale_rating.id)
    rating = batch.grade_competency_ratings.find_by!(student: @student, competency_title: "Performance Improvement")
    assert_equal 2, rating.aggregated_level.to_i
    assert_equal 1, rating.evidence_count
    assert_equal @admin.email, batch.reload.summary["ratings_rebuilt_by"]
  end

  test "evidence correction rebuilds ratings from edited row values" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "evidence-correction.xlsx",
      file_checksum: "checksum-evidence-correction",
      status: "processed"
    )
    evidence = batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Original Assignment",
      course_code: "PHPM-701-001",
      competency_title: "Performance Improvement",
      raw_grade: 82,
      mapped_level: 2,
      course_target_level: 4,
      row_number: 7,
      source_key: "source-evidence-correction",
      import_fingerprint: "fingerprint-evidence-correction"
    )
    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: "Performance Improvement",
      aggregated_level: 2,
      aggregation_rule: "max",
      evidence_count: 1
    )

    patch evidence_admin_grade_import_batch_path(batch, evidence), params: {
      grade_competency_evidence: {
        assignment_name: "Corrected Assignment",
        course_code: "PHPM-701-002",
        competency_title: "Performance Improvement",
        raw_grade: 93,
        mapped_level: 5,
        course_target_level: 5
      }
    }

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal "Corrected Assignment", evidence.reload.assignment_name
    assert_equal "PHPM-701-002", evidence.course_code
    assert_equal 5, evidence.mapped_level
    assert_equal 5, evidence.course_target_level
    rating = batch.grade_competency_ratings.find_by!(student: @student, competency_title: "Performance Improvement")
    assert_equal 5, rating.aggregated_level.to_i
    assert_equal @admin.email, batch.reload.summary["ratings_rebuilt_by"]
  end

  test "reupload corrected file replaces matching preview file and clears approval" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed_with_errors",
      summary: {
        "dry_run" => true,
        "admin_approved_at" => 1.hour.ago.iso8601,
        "admin_approved_by" => @admin.email
      }
    )
    old_file = batch.grade_import_files.create!(
      file_name: "corrected_outcomes.csv",
      file_checksum: "checksum-reupload-old",
      status: "processed",
      imported_rows: 1,
      error_rows: 1,
      parse_errors: [ { "type" => "invalid_value", "row" => 2, "message" => "Communication result target must be an integer between 1 and 5" } ]
    )
    old_evidence = batch.grade_competency_evidences.create!(
      grade_import_file: old_file,
      student: @student,
      assignment_name: "",
      course_code: "PHPM-633-700",
      competency_title: "Policy Analysis",
      raw_grade: 4,
      mapped_level: 4,
      course_target_level: 3,
      row_number: 2,
      source_key: "source-reupload-old",
      import_fingerprint: "fingerprint-reupload-old"
    )
    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: "Policy Analysis",
      aggregated_level: 4,
      aggregation_rule: "max",
      evidence_count: 1
    )

    upload = direct_competency_csv_upload(
      "corrected_outcomes.csv",
      [
        [ @student.user.name, @student.student_id, @student.uin, 4, 3, 5, 4 ]
      ]
    )

    assert_no_difference "GradeImportFile.count" do
      post reupload_admin_grade_import_batch_path(batch), params: { files: [ upload ] }
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_match "re-uploaded", flash[:notice]

    batch.reload
    file = batch.grade_import_files.first

    assert_equal "completed", batch.status
    assert batch.dry_run?
    refute batch.admin_approved?
    assert_equal @admin.email, batch.summary["last_reuploaded_by"]
    assert_equal [ "corrected_outcomes.csv" ], batch.summary["last_reuploaded_file_names"]
    refute GradeImportFile.exists?(old_file.id)
    refute GradeCompetencyEvidence.exists?(old_evidence.id)
    assert_equal "corrected_outcomes.csv", file.file_name
    assert_equal 2, file.imported_rows
    assert_equal 0, file.error_rows
    assert_equal 2, batch.grade_competency_evidences.count
    assert_equal 2, batch.grade_competency_ratings.count
  end

  test "finalize locks batch review actions" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "finalize.xlsx",
      file_checksum: "checksum-finalize",
      status: "processed"
    )
    evidence = batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Finalized Assignment",
      course_code: "PHPM-701-001",
      competency_title: "Performance Improvement",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 7,
      source_key: "source-finalize",
      import_fingerprint: "fingerprint-finalize"
    )

    post finalize_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.finalized?
    assert_equal @admin.email, batch.summary["finalized_by"]

    patch semester_admin_grade_import_batch_path(batch), params: {
      program_semester_id: program_semesters(:fall_2025).id
    }
    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_nil batch.reload.program_semester_id
    assert_match "finalized", flash[:alert]

    patch evidence_admin_grade_import_batch_path(batch, evidence), params: {
      grade_competency_evidence: {
        assignment_name: "Should Not Change",
        course_code: "PHPM-701-001",
        competency_title: "Performance Improvement",
        raw_grade: 88,
        mapped_level: 5,
        course_target_level: 4
      }
    }
    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal 3, evidence.reload.mapped_level

    post rollback_admin_grade_import_batch_path(batch)
    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal "completed", batch.reload.status

    assert_no_difference "GradeImportBatch.count" do
      delete admin_grade_import_batch_path(batch)
    end
    assert_redirected_to admin_grade_import_batch_path(batch)
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

  private

  def direct_competency_csv_upload(filename, rows)
    headers = [
      "Student name",
      "Student ID",
      "Student SIS ID",
      "EMHA Competencies > Health Care Environment and Community > Policy Analysis result",
      "EMHA Competencies > Health Care Environment and Community > Policy Analysis mastery points",
      "EMHA Competencies > Management Skills > Communication result",
      "EMHA Competencies > Management Skills > Communication mastery points"
    ]

    file = Tempfile.new([ "corrected_outcomes", ".csv" ])
    path = file.path
    file.close!
    @temp_paths << path

    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |row| csv << row }
    end

    Rack::Test::UploadedFile.new(path, "text/csv", true, original_filename: filename)
  end
end
