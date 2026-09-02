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
    assert_equal ApplicationController::ADMIN_ONLY_MESSAGE, flash[:alert]
  end

  test "admin import and export endpoints require a non-expired session" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )

    get admin_grade_import_batches_path
    assert_response :success

    travel 31.minutes do
      get admin_grade_import_batches_path
      assert_response :redirect
      follow_redirect!
      assert_redirected_to new_user_session_path
      assert_equal I18n.t("devise.failure.timeout"), flash[:alert]
    end

    sign_in @admin
    get admin_grade_import_batches_path
    assert_response :success

    travel 31.minutes do
      get export_evidence_admin_grade_import_batch_path(batch, format: :csv)
      assert_response :unauthorized
      assert_includes response.body, I18n.t("devise.failure.timeout")
    end
  end

  test "index filters batch history by course semester uploader status and workflow" do
    semester = program_semesters(:fall_2025)
    matched_batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => false, "import_notes" => "PHPM 601 faculty template" }
    )
    matched_batch.grade_import_files.create!(
      file_name: "Outcomes-26S-PHPM-601.csv",
      file_checksum: "checksum-index-filter-match",
      status: "processed"
    )
    other_batch = GradeImportBatch.create!(
      uploaded_by: @advisor,
      status: "rolled_back",
      summary: { "dry_run" => false, "import_notes" => "Different upload" }
    )
    other_batch.grade_import_files.create!(
      file_name: "Outcomes-26S-PHPM-681.csv",
      file_checksum: "checksum-index-filter-other",
      status: "processed"
    )

    get admin_grade_import_batches_path(
      q: "PHPM-601",
      program_semester_id: semester.id,
      uploaded_by_id: @admin.id,
      status: "completed",
      workflow: "committed"
    )

    assert_response :success
    assert_includes response.body, "Course, file, or notes"
    assert_includes response.body, "Workflow"
    assert_includes response.body, "Uploader"
    assert_includes response.body, "Outcomes-26S-PHPM-601.csv"
    assert_includes response.body, "##{matched_batch.id}"
    refute_includes response.body, "##{other_batch.id}"
    refute_includes response.body, "Outcomes-26S-PHPM-681.csv"
  end

  test "index summarizes committed course semester target performance" do
    semester = program_semesters(:fall_2025)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => false, "import_notes" => "Target performance summary" }
    )
    file = batch.grade_import_files.create!(
      file_name: "target-performance.csv",
      file_checksum: "checksum-index-target-performance",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final",
      course_code: "PHPM-601-700",
      competency_title: "Policy Analysis",
      raw_grade: 5,
      mapped_level: 5,
      course_target_level: 4,
      source_key: "index-target-performance",
      import_fingerprint: "fingerprint-index-target-performance"
    )

    get admin_grade_import_batches_path(program_semester_id: semester.id)

    assert_response :success
    assert_includes response.body, "Course/Semester Target Performance"
    assert_includes response.body, semester.name
    assert_includes response.body, "PHPM-601"
    assert_includes response.body, "Policy Analysis"
    assert_includes response.body, "100.0%"
  end

  test "new page links current template files" do
    get new_admin_grade_import_batch_path

    assert_response :success
    assert_select "select[name='program_semester_id'][required]"
    assert_includes response.body, "Template files"
    assert_includes response.body, "Canvas grade template"
    assert_includes response.body, "Canvas competency template"
    assert_includes response.body, "Faculty competency template"
    assert_includes response.body, "Example%20Faculty%20Competency%20Export%2026S%20PHPM%20601.csv"
    assert_includes response.body, "[Competency Title] RESULT"
    assert_includes response.body, "[Competency Title] MASTERY POINTS"
    assert_includes response.body, "for each student's assessed competency level"
    assert_includes response.body, "for the course target"
    refute_includes response.body, "Sample import files"
    refute_includes response.body, "result` columns are also treated as the course target"
    refute_includes response.body, "mastery points` columns are also treated as the assessed level"
  end

  test "sample downloads support known kinds and reject unknown kinds" do
    get sample_admin_grade_import_batches_path(kind: "success")

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Policy Analysis COURSE TARGET"
    assert_includes response.body, "Communication ASSESSED LEVEL"

    get sample_admin_grade_import_batches_path(kind: "bad_mapping")

    assert_response :success
    assert_equal "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", response.media_type
    assert response.body.bytesize.positive?

    get sample_admin_grade_import_batches_path(kind: "missing")

    assert_redirected_to new_admin_grade_import_batch_path
    assert_match "Unknown sample import file", flash[:alert]
  end

  test "create rejects missing or unsupported upload files" do
    assert_no_difference "GradeImportBatch.count" do
      post admin_grade_import_batches_path
    end

    assert_redirected_to new_admin_grade_import_batch_path
    assert_match "Please choose", flash[:alert]

    unsupported = uploaded_text_file("notes.txt", "not a grade import")

    assert_no_difference "GradeImportBatch.count" do
      post admin_grade_import_batches_path, params: { files: [ unsupported ] }
    end

    assert_redirected_to new_admin_grade_import_batch_path
    assert_match "Please choose", flash[:alert]
  end

  test "create requires a program semester before processing files" do
    upload = direct_competency_csv_upload(
      "missing-semester-upload.csv",
      [
        [ @student.user.name, @student.student_id, @student.uin, 4, 3, 5, 4 ]
      ]
    )

    assert_no_difference "GradeImportBatch.count" do
      post admin_grade_import_batches_path, params: {
        dry_run: "1",
        files: [ upload ]
      }
    end

    assert_redirected_to new_admin_grade_import_batch_path
    assert_match "program semester", flash[:alert]
  end

  test "upload enqueues the import job with the batch and redirects immediately without processing synchronously" do
    upload = direct_competency_csv_upload(
      "audit-upload.csv",
      [
        [ @student.user.name, @student.student_id, @student.uin, 4, 3, 5, 4 ]
      ]
    )

    assert_difference -> { SolidQueue::Job.where(class_name: "GradeImports::BatchImportJob").count }, 1 do
      assert_no_difference -> { GradeCompetencyEvidence.count } do
        post admin_grade_import_batches_path, params: {
          dry_run: "1",
          program_semester_id: program_semesters(:fall_2025).id,
          import_notes: "Audit upload test",
          files: [ upload ]
        }
      end
    end

    batch = GradeImportBatch.order(created_at: :desc).first
    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal "pending", batch.status

    enqueued_job = SolidQueue::Job.where(class_name: "GradeImports::BatchImportJob").order(:id).last
    arguments = enqueued_job.arguments["arguments"].first
    grade_files = batch.grade_import_files.order(:id)

    assert_equal batch.id, arguments["batch_id"]
    assert_equal @admin.id, arguments["uploaded_by_id"]
    assert_equal true, arguments["dry_run"]
    assert_equal [ "audit-upload.csv" ], grade_files.map(&:file_name)
    assert_equal grade_files.map(&:id), arguments["grade_import_file_ids"]
    assert grade_files.first.source_file.attached?
    refute arguments.key?("files_payload")
  end

  test "upload job processing records grade import audit activity" do
    upload = direct_competency_csv_upload(
      "audit-upload.csv",
      [
        [ @student.user.name, @student.student_id, @student.uin, 4, 3, 5, 4 ]
      ]
    )

    post admin_grade_import_batches_path, params: {
      dry_run: "1",
      program_semester_id: program_semesters(:fall_2025).id,
      import_notes: "Audit upload test",
      files: [ upload ]
    }

    batch = GradeImportBatch.order(created_at: :desc).first
    enqueued_job = SolidQueue::Job.where(class_name: "GradeImports::BatchImportJob").order(:id).last
    arguments = enqueued_job.arguments["arguments"].first

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      GradeImports::BatchImportJob.perform_now(
        batch_id: arguments["batch_id"],
        uploaded_by_id: arguments["uploaded_by_id"],
        dry_run: arguments["dry_run"],
        grade_import_file_ids: arguments["grade_import_file_ids"]
      )
    end

    activity = AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first
    assert_equal "upload", activity.metadata["import_action"]
    assert_equal batch, activity.subject
    assert_equal [ "audit-upload.csv" ], activity.metadata["file_names"]
    assert_equal true, activity.metadata["dry_run"]
    assert_equal "completed", batch.reload.status
  end

  test "show renders processing progress while background import is running" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "processing",
      total_files: 1,
      summary: { "dry_run" => true }
    )
    batch.grade_import_files.create!(
      file_name: "SP26 EMHA Outcomes.xlsx",
      file_checksum: "checksum-processing-progress",
      status: "processing",
      imported_rows: 200,
      pending_rows: 25,
      parsed_content: {
        "mode" => "canvas_outcomes",
        "grade_sheet_debug" => {
          "mode" => "canvas_outcomes",
          "rows_scanned" => 240
        }
      }
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Import processing"
    assert_includes response.body, "Reading and matching rows"
    assert_includes response.body, "The worker is scanning the workbook"
    assert_includes response.body, "Estimated phase progress"
    assert_includes response.body, "Rows Scanned"
    assert_includes response.body, "240"
    refute_includes response.body, "Batch actions"
    refute_includes response.body, "Batch semester"
    refute_includes response.body, "1. File Summary and Diagnostics"
    refute_includes response.body, "Commit preview"
    refute_includes response.body, "Approve preview"
  end

  test "show stays in processing mode until every file reaches a terminal status" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      total_files: 2,
      summary: { "dry_run" => true }
    )
    batch.grade_import_files.create!(
      file_name: "done.csv",
      file_checksum: "checksum-terminal-file",
      status: "processed"
    )
    batch.grade_import_files.create!(
      file_name: "waiting.csv",
      file_checksum: "checksum-pending-file",
      status: "pending"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Import processing"
    assert_includes response.body, "Queued for background worker"
    assert_includes response.body, "The upload is saved"
    assert_includes response.body, "Rows scanned will stay at 0"
    refute_includes response.body, "1. File Summary and Diagnostics"
  end

  test "commit flips a completed dry run into a reportable batch" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => true }
    )

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      post commit_admin_grade_import_batch_path(batch)
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.reportable?
    assert_equal false, ActiveModel::Type::Boolean.new.cast(batch.summary["dry_run"])
    assert_equal @admin.email, batch.summary["committed_by"]
    activity = AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first
    assert_equal @admin, activity.admin
    assert_equal batch, activity.subject
    assert_equal "commit", activity.metadata["import_action"]
    assert_equal batch.id, activity.metadata["batch_id"]
  end

  test "commit reupload and recommit require a program semester" do
    preview = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => true }
    )

    post commit_admin_grade_import_batch_path(preview)

    assert_redirected_to admin_grade_import_batch_path(preview)
    assert_match "Assign a program semester", flash[:alert]

    reuploadable = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )

    post reupload_admin_grade_import_batch_path(reuploadable)

    assert_redirected_to admin_grade_import_batch_path(reuploadable)
    assert_match "Assign a program semester", flash[:alert]

    rolled_back = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "rolled_back",
      summary: { "dry_run" => false }
    )

    post recommit_admin_grade_import_batch_path(rolled_back)

    assert_redirected_to admin_grade_import_batch_path(rolled_back)
    assert_match "Assign a program semester", flash[:alert]
  end

  test "approval and commit reject batches in the wrong workflow state" do
    committed_batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    clean_preview = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => true }
    )
    failed_batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "failed",
      summary: { "dry_run" => true }
    )

    post approve_admin_grade_import_batch_path(committed_batch)
    assert_redirected_to admin_grade_import_batch_path(committed_batch)
    assert_match "Only previews", flash[:alert]

    post approve_admin_grade_import_batch_path(clean_preview)
    assert_redirected_to admin_grade_import_batch_path(clean_preview)
    assert_match "Only previews with failed", flash[:alert]
    refute clean_preview.reload.admin_approved?

    post commit_admin_grade_import_batch_path(failed_batch)
    assert_redirected_to admin_grade_import_batch_path(failed_batch)
    assert_match "Only completed previews", flash[:alert]
    assert failed_batch.reload.dry_run?
  end

  test "commit notifies advisors when advisee course competency data becomes reportable" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "advisor-notification.csv",
      file_checksum: "checksum-advisor-notification",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final",
      course_code: "PHPM-601-700",
      competency_title: "Policy Analysis",
      raw_grade: 5,
      mapped_level: 5,
      course_target_level: 4,
      source_key: "advisor-notification",
      import_fingerprint: "fingerprint-advisor-notification"
    )

    assert_difference -> { Notification.where(user: @advisor, title: "Advisee Course Competency Data Updated").count }, 1 do
      assert_enqueued_jobs 1, only: NotificationEmailDeliveryJob do
        post commit_admin_grade_import_batch_path(batch)
      end
    end

    notification = Notification.where(user: @advisor, title: "Advisee Course Competency Data Updated").order(created_at: :desc).first
    assert_equal batch, notification.notifiable
    assert_match "published", notification.message
    assert_match "1 advisee", notification.message
    assert_equal "advisee.course_data.updated", notification.event_key
    assert_equal "advisee.course_data.updated:batch:#{batch.id}:advisor:#{@advisor.id}:action:published", notification.dedupe_key
    assert_equal batch.id, notification.metadata["batch_id"]
    assert_equal @advisor.id, notification.metadata["advisor_id"]
    assert_equal 1, notification.metadata["advisee_count"]
  end

  test "preview with failed or pending rows must be approved before commit" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
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

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      post approve_admin_grade_import_batch_path(batch)
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.admin_approved?
    assert_equal @admin.email, batch.summary["admin_approved_by"]
    assert_equal "approve", AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first.metadata["import_action"]

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      post commit_admin_grade_import_batch_path(batch)
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.reportable?
    assert_equal @admin.email, batch.summary["committed_by"]
  end

  test "reupload rejects locked committed and blank preview batches" do
    finalized = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false, "finalized_at" => Time.current.iso8601 }
    )
    committed = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    preview = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )

    post reupload_admin_grade_import_batch_path(finalized)
    assert_redirected_to admin_grade_import_batch_path(finalized)
    assert_match "finalized", flash[:alert]

    post reupload_admin_grade_import_batch_path(committed)
    assert_redirected_to admin_grade_import_batch_path(committed)
    assert_match "Only preview", flash[:alert]

    post reupload_admin_grade_import_batch_path(preview)
    assert_redirected_to admin_grade_import_batch_path(preview)
    assert_match "Please choose", flash[:alert]
  end

  test "rollback recommit rebuild and finalize guard invalid workflow states" do
    finalized = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false, "finalized_at" => Time.current.iso8601 }
    )
    rolled_back = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "rolled_back",
      summary: { "dry_run" => false }
    )
    preview = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => true }
    )

    post rollback_admin_grade_import_batch_path(finalized)
    assert_redirected_to admin_grade_import_batch_path(finalized)
    assert_match "finalized", flash[:alert]
    assert_equal "completed", finalized.reload.status

    post rollback_admin_grade_import_batch_path(rolled_back)
    assert_redirected_to admin_grade_import_batch_path(rolled_back)
    assert_match "already", flash[:alert]

    post recommit_admin_grade_import_batch_path(preview)
    assert_redirected_to admin_grade_import_batch_path(preview)
    assert_match "Only rolled-back", flash[:alert]

    post rebuild_ratings_admin_grade_import_batch_path(finalized)
    assert_redirected_to admin_grade_import_batch_path(finalized)
    assert_match "finalized", flash[:alert]

    post finalize_admin_grade_import_batch_path(preview)
    assert_redirected_to admin_grade_import_batch_path(preview)
    assert_match "Only committed", flash[:alert]
    refute preview.reload.finalized?
  end

  test "rollback hides a committed batch and recommit restores it" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
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

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      post rollback_admin_grade_import_batch_path(batch)
    end
    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.rolled_back?
    refute batch.reportable?
    assert_equal "rollback", AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first.metadata["import_action"]

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      post recommit_admin_grade_import_batch_path(batch)
    end
    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal "completed", batch.reload.status
    assert batch.reportable?
    assert_equal @admin.email, batch.summary["recommitted_by"]
    assert_equal "recommit", AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first.metadata["import_action"]
  end

  test "semester action assigns legacy batch to a program semester" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => true }
    )

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      patch semester_admin_grade_import_batch_path(batch), params: {
        program_semester_id: program_semesters(:fall_2025).id
      }
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal program_semesters(:fall_2025), batch.reload.program_semester
    assert_match "Batch semester updated", flash[:notice]
    activity = AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first
    assert_equal "semester_change", activity.metadata["import_action"]
    assert_equal program_semesters(:fall_2025).id, activity.metadata["new_program_semester_id"]
  end

  test "semester action rejects clearing a batch semester" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )

    patch semester_admin_grade_import_batch_path(batch), params: { program_semester_id: "" }

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal program_semesters(:fall_2025), batch.reload.program_semester
    assert_match "Choose a program semester", flash[:alert]
  end

  test "error report export includes parse diagnostics" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )
    batch.grade_import_files.create!(
      file_name: "bad-values.csv",
      file_checksum: "checksum-error-report",
      status: "failed",
      parse_errors: [
        {
          "type" => "invalid_level",
          "row" => 4,
          "column" => "Communication ASSESSED LEVEL",
          "value" => "six",
          "expected" => "1-5",
          "received" => "six",
          "message" => "Assessed level must be 1 through 5.",
          "correction_hint" => "Enter a whole number from 1 to 5."
        }
      ]
    )

    get error_report_admin_grade_import_batch_path(batch, format: :csv)

    assert_response :success
    parsed = CSV.parse(response.body, headers: true)
    assert_equal "bad-values.csv", parsed.first["file_name"]
    assert_equal "invalid_level", parsed.first["type"]
    assert_equal "Communication ASSESSED LEVEL", parsed.first["column"]
    assert_equal "Enter a whole number from 1 to 5.", parsed.first["correction_hint"]
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
      course_target_level: 4,
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
      "Course Target Levels",
      "Target Met Status",
      "Provenance Details"
    ], parsed.headers

    first_row = parsed.first
    assert_equal @student.student_id.to_s, first_row["Student ID"]
    assert_equal "Policy Analysis", first_row["Competency"]
    assert_equal "max", first_row["Aggregation Rule"]
    assert_equal "PHPM-700-001", first_row["Course Codes"]
    assert_equal "Case Study", first_row["Assignments"]
    assert_equal "sample.xlsx", first_row["Source Files"]
    assert_equal "4", first_row["Course Target Levels"]
    assert_equal "Met", first_row["Target Met Status"]
    assert_includes first_row["Provenance Details"], "raw=95.0"
    assert_includes first_row["Provenance Details"], "target=4"
    assert_includes first_row["Provenance Details"], "target_status=Met"
    assert_equal evidence.updated_at.iso8601, first_row["Latest Evidence Updated At"]

    get export_ratings_admin_grade_import_batch_path(batch, format: :xlsx)
    assert_response :not_acceptable
  end

  test "export evidence rows includes course target attainment status" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "row-export.csv",
      file_checksum: "checksum-row-export",
      status: "processed"
    )
    evidence = batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: "PHPM-601-700",
      competency_title: "Policy Analysis",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 9,
      source_key: "source-row-export",
      import_fingerprint: "fingerprint-row-export"
    )

    get export_evidence_admin_grade_import_batch_path(batch, format: :csv)

    assert_response :success
    parsed = CSV.parse(response.body, headers: true)
    assert_equal [
      "Student Name",
      "Student UIN",
      "Student ID",
      "Student Email",
      "Course Code",
      "Competency",
      "Assessed Level",
      "Course Target Level",
      "Target Met?",
      "Raw Score",
      "Assignment",
      "Source File",
      "Source Row",
      "Last Updated"
    ], parsed.headers

    first_row = parsed.first
    assert_equal @student.uin, first_row["Student UIN"]
    assert_equal @student.student_id.to_s, first_row["Student ID"]
    assert_equal "PHPM-601-700", first_row["Course Code"]
    assert_equal "Policy Analysis", first_row["Competency"]
    assert_equal "3", first_row["Assessed Level"]
    assert_equal "4", first_row["Course Target Level"]
    assert_equal "No - below target", first_row["Target Met?"]
    assert_equal "88.0", first_row["Raw Score"]
    assert_equal "Final Project", first_row["Assignment"]
    assert_equal "row-export.csv", first_row["Source File"]
    assert_equal "9", first_row["Source Row"]
    assert_equal evidence.updated_at.strftime("%Y-%m-%d %H:%M:%S"), first_row["Last Updated"]
  end

  test "evidence export handles rows without optional course target values" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "optional-export.csv",
      file_checksum: "checksum-optional-export",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: nil,
      course_code: "PHPM-601",
      competency_title: "Policy Analysis",
      raw_grade: 3,
      mapped_level: 3,
      course_target_level: nil,
      row_number: nil,
      source_key: "source-evidence-export-optional",
      import_fingerprint: "fingerprint-evidence-export-optional"
    )

    get export_evidence_admin_grade_import_batch_path(batch, format: :csv)

    assert_response :success
    parsed = CSV.parse(response.body, headers: true)
    assert_equal @student.user.name, parsed.first["Student Name"]
    assert_equal @student.uin, parsed.first["Student UIN"]
    assert_equal "PHPM-601", parsed.first["Course Code"]
    assert_equal "No target", parsed.first["Target Met?"]
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
    assert_includes response.body, "Format"
    assert_includes response.body, "Imported Values"
    assert_includes response.body, "Needs Attention"
    assert_includes response.body, "3. Student Processed"
    assert_includes response.body, "Processed student row tools"
    assert_includes response.body, "Imported rows"
    assert_select ".c-import-review-panel", minimum: 2
    assert_select ".c-import-review-panel__header", text: /Edit imported values/
    assert_select ".c-import-review-panel__header", text: /Read-only values/
    assert_includes response.body, "Assessed level"
    assert_includes response.body, "Course target"
    assert_includes response.body, "Target status"
    assert_includes response.body, "Below target"
    assert_includes response.body, "Export rows CSV"
    assert_includes response.body, "Correction file"
    assert_select ".c-ferpa-export-notice", text: /Row-level student competency exports/
    assert_select "a[data-turbo='false'][data-turbo-confirm*='FERPA reminder']", text: "Export rows CSV"
    assert_select "a[data-turbo='false'][data-turbo-confirm*='FERPA reminder']", text: "Correction file"
    refute_includes response.body, ">Export CSV<"
    refute_includes response.body, ">Error report<"
    assert_includes response.body, "PHPM-701-001"
    assert_includes response.body, "UIN #{@student.uin}"
    refute_includes response.body, "ID #{@student.student_id}"
    assert_select ".c-score-pill--program", text: "4"
  end

  test "show summarizes target attainment by course" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "target-attainment.csv",
      file_checksum: "checksum-target-attainment",
      status: "processed"
    )
    [
      [ "source-target-met", 5, 4 ],
      [ "source-target-below", 2, 4 ],
      [ "source-target-missing", 3, nil ]
    ].each_with_index do |(source_key, level, target), index|
      batch.grade_competency_evidences.create!(
        grade_import_file: file,
        student: @student,
        assignment_name: "Target Attainment #{index}",
        course_code: "PHPM-701-001",
        competency_title: "Performance Improvement",
        raw_grade: 80 + index,
        mapped_level: level,
        course_target_level: target,
        row_number: index + 2,
        source_key: source_key,
        import_fingerprint: "fingerprint-#{source_key}"
      )
    end

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Target Performance by Course"
    assert_includes response.body, "Actual vs Course Target by Competency"
    assert_includes response.body, "PHPM-701-001"
    assert_includes response.body, "Performance Improvement"
    assert_includes response.body, "Actual avg"
    assert_includes response.body, "Course target avg"
    assert_includes response.body, "Processed rows"
    assert_includes response.body, "Below target"
    assert_includes response.body, "No Course Target Configured"
    assert_includes response.body, "50.0%"
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
        "duplicate_file_upload_count" => 1,
        "duplicate_file_uploads" => [
          { "batch_id" => 12, "file_name" => "direct.xlsx" }
        ],
        "grade_sheet_debug" => {
          "duplicate_warning_count" => 2,
          "duplicate_warnings_preview" => [
            { "row" => 4, "message" => "Duplicate import suppressed for Policy Analysis" }
          ]
        }
      }
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "reportable for"
    assert_includes response.body, "Fall 2025"
    assert_includes response.body, "Direct competency"
    assert_includes response.body, "skipped instead of imported again"
    assert_includes response.body, "Duplicate file upload"
    assert_includes response.body, "Duplicate import suppressed for Policy Analysis"
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
    file = batch.grade_import_files.create!(
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
    batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      status: "pending_student_match",
      student_identifier_type: "student_name",
      student_identifier: "Missing Student",
      student_name: "Missing Student",
      student_uin: "555666777",
      course_code: "PHPM-631-600",
      assignment_name: "Final Project",
      competency_title: "Policy Analysis",
      raw_grade: 91,
      mapped_level: 4,
      row_number: 4,
      source_key: "source-mapping-preview-pending",
      import_fingerprint: "fingerprint-mapping-preview-pending"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Import notes:"
    assert_includes response.body, "Canvas export from PHPM 631"
    assert_includes response.body, "Correction file"
    assert_includes response.body, "Admin review required:"
    refute_includes response.body, "Preview validation:"
    refute_includes response.body, "Import review checklist"
    refute_includes response.body, "Review in this order"
    assert_includes response.body, "1. File Summary and Diagnostics"
    assert_includes response.body, "File Diagnostics"
    assert_includes response.body, "Detected format"
    assert_includes response.body, "Course detected"
    assert_includes response.body, "Student rows scanned"
    assert_includes response.body, "Students matched"
    assert_includes response.body, "Students needing match"
    assert_includes response.body, "Competency values needing match"
    assert_includes response.body, "Final Project"
    assert_includes response.body, "Policy Analysis"
    assert_includes response.body, "Review Items"
    assert_includes response.body, "Parsing issues"
    assert_includes response.body, "Unknown competency_title"
    assert_includes response.body, "Approve this preview?"
    assert_includes response.body, "Review every listed item before approving"
    assert_includes response.body, "mapping-preview.xlsx: Unknown competency_title"
    assert_includes response.body, 'data-controller="modal-confirm"'
    assert_includes response.body, "modal-confirm-message-value"
    assert_includes response.body, "modal-confirm-sections-value"
    assert_includes response.body, "Failed Values"
    assert_includes response.body, "2. Pending Student Matching"
    assert_includes response.body, "3. Student Processed"
    assert_includes response.body, "Missing Student (UIN 555666777) | 1 pending row | PHPM-631-600 | Policy Analysis"
    assert_includes response.body, "Why pending:"
    assert_includes response.body, "No student profile currently has UIN 555666777."
    refute_includes response.body, "&quot;overflow_message&quot;"
    refute_includes response.body, "&quot;collapsed&quot;:true"
    assert_includes response.body, "Keep reviewing"
  end

  test "approval modal includes every failed value without truncating" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => true }
    )
    errors = 25.times.map do |index|
      {
        "row" => index + 2,
        "column" => "Competency #{index + 1} ASSESSED LEVEL",
        "type" => "invalid_value",
        "message" => "Invalid test value #{index + 1}"
      }
    end
    batch.grade_import_files.create!(
      file_name: "many-errors.csv",
      file_checksum: "checksum-many-errors",
      status: "processed",
      error_rows: errors.size,
      parse_errors: errors
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "25"
    assert_includes response.body, "Invalid test value 1"
    assert_includes response.body, "Invalid test value 20"
    assert_includes response.body, "Invalid test value 21"
    assert_includes response.body, "Invalid test value 25"
    refute_includes response.body, "...and 5 more"
    refute_includes response.body, "&quot;overflow_message&quot;"
  end

  test "approval modal surfaces invalid uin values from pending rows" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "bad-uin.csv",
      file_checksum: "checksum-bad-uin",
      status: "processed",
      pending_rows: 1
    )
    batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "12345",
      student_identifier_type: "uin",
      student_name: "Bad UIN Student",
      student_uin: "12345",
      assignment_name: "Final Project",
      course_code: "PHPM-601-700",
      competency_title: "Policy Analysis",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 9,
      source_key: "source-bad-uin",
      import_fingerprint: "fingerprint-bad-uin"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "bad-uin.csv, column Student UIN"
    assert_includes response.body, "Invalid UIN"
    assert_includes response.body, "Student UIN must be exactly 9 digits; received 12345"
    assert_includes response.body, "Bad UIN Student"
  end

  test "approval modal normalizes old assessed level wording" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => true }
    )
    batch.grade_import_files.create!(
      file_name: "old-message.csv",
      file_checksum: "checksum-old-message",
      status: "processed",
      error_rows: 1,
      parse_errors: [
        {
          "type" => "invalid_value",
          "column" => "Systems Thinking ASSESSED LEVEL",
          "message" => "Systems Thinking mastery points must be an integer between 1 and 5; received blank"
        }
      ]
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Systems Thinking assessed level must be an integer between 1 and 5; received blank"
    refute_includes response.body, "Systems Thinking mastery points must be an integer"
  end

  test "sample action downloads guided import examples" do
    get sample_admin_grade_import_batches_path(kind: "success")

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Policy Analysis COURSE TARGET"
    assert_includes response.body, "Policy Analysis ASSESSED LEVEL"
    refute_includes response.body, "Unmatched Canvas Student"

    get sample_admin_grade_import_batches_path(kind: "pending_match")

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Unmatched Canvas Student"

    get sample_admin_grade_import_batches_path(kind: "bad_values")

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_includes response.body, "Invalid UIN Student"
    assert_includes response.body, "12345"
    assert_includes response.body, "two"

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
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: students(:other_student),
      assignment_name: "Final Project",
      course_code: "PHPM-631-600",
      competency_title: competency_title,
      raw_grade: 89,
      mapped_level: 3,
      course_target_level: nil,
      row_number: 3,
      source_key: "source-target-warning-other-student",
      import_fingerprint: "fingerprint-target-warning-other-student"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: "PHPM-631-600",
      competency_title: "Communication",
      raw_grade: 92,
      mapped_level: 4,
      course_target_level: 4,
      row_number: 4,
      source_key: "source-covered-target-warning",
      import_fingerprint: "fingerprint-covered-target-warning"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Target Warnings Before Commit"
    assert_includes response.body, "Missing Uploaded Course Targets"
    assert_includes response.body, "Missing Target Coverage"
    assert_includes response.body, "2 students / 2 rows"
    coverage_section = response.body[/<h3 class="c-h3 c-heading-inline">Missing Target Coverage<\/h3>.*?<\/section>/m]
    assert_includes coverage_section, competency_title
    refute_includes coverage_section, "Communication"
    refute_includes response.body, "Uploaded Targets Differ From Configured Targets"

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

  test "show lists students missing a competency assessment other students in the course received" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "missing-assessments.csv",
      file_checksum: "checksum-missing-assessments",
      status: "processed",
      imported_rows: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: "PHPM-651-700",
      competency_title: "Communication",
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: 4,
      row_number: 2,
      source_key: "source-missing-assessments-1",
      import_fingerprint: "fingerprint-missing-assessments-1"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: "PHPM-651-700",
      competency_title: "Ethics",
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: 4,
      row_number: 3,
      source_key: "source-missing-assessments-2",
      import_fingerprint: "fingerprint-missing-assessments-2"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: students(:other_student),
      assignment_name: "Final Project",
      course_code: "PHPM-651-700",
      competency_title: "Ethics",
      raw_grade: 88,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 4,
      source_key: "source-missing-assessments-3",
      import_fingerprint: "fingerprint-missing-assessments-3"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Students Missing a Competency Assessment"
    missing_section = response.body[/<h2 class="c-section-title">Students Missing a Competency Assessment<\/h2>.*?<\/details>/m]
    assert_includes missing_section, "PHPM-651-700"
    assert_includes missing_section, "Communication"
    assert_includes missing_section, students(:other_student).user.name
  end

  test "course code issues block approval and commit until fixed on evidence rows" do
    competency_title = "Policy Analysis"
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "missing-section.csv",
      file_checksum: "checksum-missing-section",
      status: "processed",
      imported_rows: 1
    )
    evidence = batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: "PHPM-631",
      competency_title: competency_title,
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: 5,
      row_number: 2,
      source_key: "source-missing-section",
      import_fingerprint: "fingerprint-missing-section"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Course Code Issues"
    assert_includes response.body, "4-letter department code"
    assert_includes response.body, "3-digit course number"
    assert_includes response.body, "3-digit section number"

    post approve_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    refute batch.reload.admin_approved?
    assert_match "course code issues", flash[:alert]

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.dry_run?
    assert_match "course code issues", flash[:alert]

    patch evidence_admin_grade_import_batch_path(batch, evidence_id: evidence.id), params: {
      grade_competency_evidence: {
        course_code: "PHPM-631-600",
        assignment_name: evidence.assignment_name,
        competency_title: evidence.competency_title,
        raw_grade: evidence.raw_grade,
        mapped_level: evidence.mapped_level,
        course_target_level: evidence.course_target_level
      }
    }

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal "PHPM-631-600", evidence.reload.course_code

    get admin_grade_import_batch_path(batch)

    assert_response :success
    refute_includes response.body, "Course Code Issues"
  end

  test "course code warning can repair missing section across imported rows" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => true }
    )
    old_offering = CourseOffering.find_or_create_from_code!("PHPM-603", program_semester: batch.program_semester)
    file = batch.grade_import_files.create!(
      file_name: "missing-section-603.csv",
      file_checksum: "checksum-missing-section-603",
      status: "processed",
      imported_rows: 1,
      pending_rows: 1,
      course_offering: old_offering,
      parsed_content: {
        "mode" => "direct_competency",
        "direct_course_code" => "PHPM-603",
        "grade_sheet_debug" => { "direct_course_code" => "PHPM-603" }
      }
    )
    evidence = batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Direct competency",
      course_code: "PHPM-603",
      competency_title: "Policy Analysis",
      raw_grade: 4,
      mapped_level: 4,
      course_target_level: 3,
      row_number: 2,
      source_key: "source-missing-section-603-evidence",
      import_fingerprint: "fingerprint-missing-section-603-evidence"
    )
    pending = batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "Missing Student",
      student_identifier_type: "student_name",
      student_name: "Missing Student",
      student_uin: "555666777",
      assignment_name: "Direct competency",
      course_code: "PHPM-603",
      competency_title: "Communication",
      raw_grade: 3,
      mapped_level: 3,
      course_target_level: 2,
      row_number: 3,
      source_key: "source-missing-section-603-pending",
      import_fingerprint: "fingerprint-missing-section-603-pending"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Course Code Issues"
    assert_includes response.body, "Full course code"
    assert_includes response.body, "PHPM-603-"
    assert_includes response.body, "Apply to"

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      patch course_code_admin_grade_import_batch_path(batch), params: {
        grade_import_course_code_repair: {
          old_course_code: "PHPM-603",
          new_course_code: "PHPM-603-601"
        }
      }
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_match "Updated 2 imported rows", flash[:notice]
    assert_equal "PHPM-603-601", evidence.reload.course_code
    assert_equal "PHPM-603-601", evidence.course_offering.display_code
    assert_equal "checksum-missing-section-603:phpm_603_601:2:direct_competency:policy_analysis", evidence.import_fingerprint
    assert_equal "PHPM-603-601", pending.reload.course_code
    assert_equal "PHPM-603-601", pending.course_offering.display_code
    assert_equal "PHPM-603-601", file.reload.parsed_content["direct_course_code"]
    assert_equal "PHPM-603-601", file.parsed_content.dig("grade_sheet_debug", "direct_course_code")
    assert_equal "PHPM-603-601", file.course_offering.display_code
    assert batch.grade_competency_ratings.exists?(student: @student, competency_title: "Policy Analysis")

    activity = AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first
    assert_equal "course_code_group_update", activity.metadata["import_action"]
    assert_equal "PHPM-603", activity.metadata["old_course_code"]
    assert_equal "PHPM-603-601", activity.metadata["new_course_code"]
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
    refute_includes response.body, "Admin review required:"

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.reportable?
  end

  test "uploaded course targets are not compared to program-wide targets" do
    competency_title = "Policy Analysis"
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => true }
    )
    CompetencyTargetLevel.create!(
      program_semester: program_semesters(:fall_2025),
      track: @student.track,
      class_of: @student.program_year,
      competency_title: competency_title,
      target_level: 4
    )
    file = batch.grade_import_files.create!(
      file_name: "target-mismatch.csv",
      file_checksum: "checksum-target-mismatch",
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
      source_key: "source-target-mismatch",
      import_fingerprint: "fingerprint-target-mismatch"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    refute_includes response.body, "Target Warnings Before Commit"
    refute_includes response.body, "Uploaded Targets Differ From Configured Targets"
    refute_includes response.body, "configured target"

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.reportable?
  end

  test "uploaded course targets warn when they differ from configured course targets" do
    semester = program_semesters(:fall_2025)
    competency = create_test_competency!("Policy Analysis")
    offering = CourseOffering.find_or_create_from_code!("PHPM-631-600", program_semester: semester)
    CourseCompetencyTarget.create!(course_offering: offering, competency: competency, target_level: 4)

    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "configured-target-mismatch.csv",
      file_checksum: "checksum-configured-target-mismatch",
      status: "processed",
      imported_rows: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: "PHPM-631-600",
      competency_title: competency.title,
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: 5,
      row_number: 2,
      source_key: "source-configured-target-mismatch",
      import_fingerprint: "fingerprint-configured-target-mismatch"
    )

    get admin_grade_import_batch_path(batch)

    assert_response :success
    assert_includes response.body, "Target Warnings Before Commit"
    assert_includes response.body, "Configured Course Target Mismatches"
    assert_includes response.body, "PHPM-631-600"
    assert_includes response.body, "Policy Analysis"
    assert_includes response.body, ">5<"
    assert_includes response.body, ">4<"

    post commit_admin_grade_import_batch_path(batch)

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.dry_run?
    assert_match "target-warning", flash[:alert]
  end

  test "show explains when configured course target comparison is unavailable" do
    semester = program_semesters(:fall_2025)
    competency = create_test_competency!("Configured Target Unavailable")
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "configured-target-unavailable.csv",
      file_checksum: "checksum-configured-target-unavailable",
      status: "processed",
      imported_rows: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Final Project",
      course_code: "PHPM-631-600",
      competency_title: competency.title,
      raw_grade: 91,
      mapped_level: 4,
      course_target_level: 5,
      row_number: 2,
      source_key: "source-configured-target-unavailable",
      import_fingerprint: "fingerprint-configured-target-unavailable"
    )

    connection = ActiveRecord::Base.connection
    original_data_source_exists = connection.method(:data_source_exists?)

    connection.stub(:data_source_exists?, ->(table_name) {
      table_name.to_s == "course_competency_targets" ? false : original_data_source_exists.call(table_name)
    }) do
      get admin_grade_import_batch_path(batch)
    end

    assert_response :success
    assert_includes response.body, "Configured course target comparison is unavailable"
    refute_includes response.body, "Configured Course Target Mismatches"
  end

  test "show renders pending student matches with manual correction controls" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "pending-students.xlsx",
      file_checksum: "checksum-pending-students",
      status: "processed"
    )
    batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_name: "Missing Student",
      student_uin: "555666777",
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
    assert_includes response.body, "2. Pending Student Matching"
    assert_includes response.body, "Missing Student"
    assert_includes response.body, "555666777"
    assert_includes response.body, "Hidden Assignment"
    assert_includes response.body, "PHPM-701-001"
    assert_includes response.body, "Match all rows to student"
    assert_includes response.body, "Imported rows"
    assert_includes response.body, "Why pending:"
    assert_includes response.body, "No student profile currently has UIN 555666777."
    assert_includes response.body, "Identifier Type"
    assert_includes response.body, "Identifier"
    assert_includes response.body, "Assessed level"
    assert_includes response.body, "Course target"
    assert_includes response.body, "Pending student match"
    assert_includes response.body, "Save grouped correction"
    assert_includes response.body, pending_row_group_admin_grade_import_batch_path(batch)
  end

  test "show groups repeated pending rows for the same imported student" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => true }
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
        student_uin: "555666777",
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
    assert_includes response.body, "Missing Student (UIN 555666777) | 2 pending rows | PHPM-701-001 | 2 competencies: Communication, Policy Analysis"
    refute_includes response.body, "source rows"
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

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      post rebuild_ratings_admin_grade_import_batch_path(batch)
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    refute GradeCompetencyRating.exists?(stale_rating.id)
    rating = batch.grade_competency_ratings.find_by!(student: @student, competency_title: "Performance Improvement")
    assert_equal 2, rating.aggregated_level.to_i
    assert_equal 1, rating.evidence_count
    assert_equal @admin.email, batch.reload.summary["ratings_rebuilt_by"]
    assert_equal "rebuild_ratings", AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first.metadata["import_action"]
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

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
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
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal "Corrected Assignment", evidence.reload.assignment_name
    assert_equal "PHPM-701-002", evidence.course_code
    assert_equal 5, evidence.mapped_level
    assert_equal 5, evidence.course_target_level
    rating = batch.grade_competency_ratings.find_by!(student: @student, competency_title: "Performance Improvement")
    assert_equal 5, rating.aggregated_level.to_i
    assert_equal @admin.email, batch.reload.summary["ratings_rebuilt_by"]
    activity = AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first
    assert_equal "correct_evidence", activity.metadata["import_action"]
    assert_equal evidence.id, activity.metadata["evidence_id"]
  end

  test "reupload corrected file replaces matching preview file and clears approval" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
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

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      assert_no_difference "GradeImportFile.count" do
        post reupload_admin_grade_import_batch_path(batch), params: { files: [ upload ] }
      end
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
    activity = AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first
    assert_equal "reupload", activity.metadata["import_action"]
    assert_equal [ "corrected_outcomes.csv" ], activity.metadata["file_names"]
  end

  test "finalize locks batch review actions" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
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

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      post finalize_admin_grade_import_batch_path(batch)
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert batch.reload.finalized?
    assert_equal @admin.email, batch.summary["finalized_by"]
    assert_equal "finalize", AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first.metadata["import_action"]

    patch semester_admin_grade_import_batch_path(batch), params: {
      program_semester_id: program_semesters(:fall_2025).id
    }
    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_equal program_semesters(:fall_2025), batch.reload.program_semester
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
      parse_errors: [
        {
          "row" => 5,
          "type" => "missing_competency_mapping",
          "column" => "competency_title",
          "value" => "Polciy Analysis",
          "expected" => "known competency alias",
          "received" => "Polciy Analysis",
          "suggested_canonical_competency_title" => "Policy Analysis",
          "suggested_alias_string" => "Policy Analysis",
          "suggestion_score" => 0.87,
          "message" => "Missing competency mapping for 'Polciy Analysis'. Did you mean 'Policy Analysis'?",
          "correction_hint" => "Add this string to db/data/competency_aliases.csv."
        }
      ],
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
    assert_equal "Missing competency mapping for 'Polciy Analysis'. Did you mean 'Policy Analysis'?", parsed[0]["Message"]
    assert_equal "Policy Analysis", parsed[0]["Suggested Canonical Competency"]
    assert_equal "Add this string to db/data/competency_aliases.csv.", parsed[0]["Suggested Fix"]
    assert_equal "pending_student_match", parsed[1]["Row Type"]
    assert_equal "Missing Student", parsed[1]["Student Name"]
    assert_equal "PHPM-631-600", parsed[1]["Course Code"]
    assert_equal "5", parsed[1]["Course Target Level"]
  end

  test "pending row update can save corrections without matching a student" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "pending-correction.csv",
      file_checksum: "checksum-pending-correction",
      status: "processed",
      pending_rows: 1
    )
    pending = batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "Missing Student",
      student_identifier_type: "student_name",
      student_name: "Missing Student",
      course_code: "PHPM-601",
      assignment_name: "Old Assignment",
      competency_title: "Policy Analysis",
      raw_grade: 80,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 2,
      source_key: "source-pending-correction",
      import_fingerprint: "fingerprint-pending-correction"
    )

    assert_no_difference "GradeCompetencyEvidence.count" do
      patch pending_row_admin_grade_import_batch_path(batch, pending), params: {
        grade_import_pending_row: {
          assignment_name: "Corrected Assignment",
          course_code: "PHPM-602",
          competency_title: "Communication",
          raw_grade: 91,
          mapped_level: 5,
          course_target_level: ""
        }
      }
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_match "correction saved", flash[:notice]
    assert_equal "Corrected Assignment", pending.reload.assignment_name
    assert_equal "PHPM-602", pending.course_code
    assert_nil pending.course_target_level
  end

  test "pending row actions reject finalized or invalid row updates" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false, "finalized_at" => Time.current.iso8601 }
    )
    file = batch.grade_import_files.create!(
      file_name: "locked-pending.csv",
      file_checksum: "checksum-locked-pending",
      status: "processed"
    )
    pending = batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "Missing Student",
      student_identifier_type: "student_name",
      student_name: "Missing Student",
      course_code: "PHPM-601",
      assignment_name: "Assignment",
      competency_title: "Policy Analysis",
      raw_grade: 80,
      mapped_level: 3,
      row_number: 2,
      source_key: "source-locked-pending",
      import_fingerprint: "fingerprint-locked-pending"
    )

    patch pending_row_admin_grade_import_batch_path(batch, pending), params: {
      grade_import_pending_row: { assignment_name: "Should Not Save" }
    }

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_match "finalized", flash[:alert]
    refute_equal "Should Not Save", pending.reload.assignment_name

    unlocked = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )
    patch pending_row_admin_grade_import_batch_path(unlocked, pending_row_id: 99_999), params: {
      grade_import_pending_row: { assignment_name: "Missing" }
    }

    assert_redirected_to admin_grade_import_batch_path(unlocked)
    assert_match "Could not update pending row", flash[:alert]
  end

  test "pending row group can save shared corrections without matching a student" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )
    file = batch.grade_import_files.create!(
      file_name: "pending-group.csv",
      file_checksum: "checksum-pending-group-update",
      status: "processed",
      pending_rows: 1
    )
    pending = batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "Missing Student",
      student_identifier_type: "student_name",
      student_name: "Missing Student",
      course_code: "PHPM-601",
      assignment_name: "Old Assignment",
      competency_title: "Policy Analysis",
      raw_grade: 80,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 2,
      source_key: "source-pending-group-update",
      import_fingerprint: "fingerprint-pending-group-update"
    )

    assert_no_difference "GradeCompetencyEvidence.count" do
      patch pending_row_group_admin_grade_import_batch_path(batch), params: {
        pending_row_ids: [ "0", pending.id, pending.id ],
        grade_import_pending_row_group: {
          student_identifier: "Corrected Student",
          student_identifier_type: "",
          student_name: "Corrected Student"
        },
        pending_rows: {
          pending.id => {
            assignment_name: "Updated Group Assignment",
            course_code: "PHPM-603",
            competency_title: "Communication",
            raw_grade: 95,
            mapped_level: 5,
            course_target_level: ""
          }
        }
      }
    end

    assert_redirected_to admin_grade_import_batch_path(batch)
    assert_match "Saved corrections", flash[:notice]
    assert_equal "Corrected Student", pending.reload.student_name
    assert_equal "Updated Group Assignment", pending.assignment_name
    assert_nil pending.course_target_level
  end

  test "pending row group rejects empty selections and finalized batches" do
    finalized = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      summary: { "dry_run" => false, "finalized_at" => Time.current.iso8601 }
    )
    preview = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed_with_errors",
      summary: { "dry_run" => true }
    )

    patch pending_row_group_admin_grade_import_batch_path(finalized), params: { pending_row_ids: [] }
    assert_redirected_to admin_grade_import_batch_path(finalized)
    assert_match "finalized", flash[:alert]

    patch pending_row_group_admin_grade_import_batch_path(preview), params: { pending_row_ids: [ "0", "" ] }
    assert_redirected_to admin_grade_import_batch_path(preview)
    assert_match "No pending rows", flash[:alert]
  end

  test "destroy deletes batch import rows and frees duplicate fingerprints" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
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

    assert_difference -> { AdminActivityLog.where(action: "grade_import_action").count }, 1 do
      assert_difference "GradeImportBatch.count", -1 do
        delete admin_grade_import_batch_path(batch)
      end
    end

    assert_redirected_to admin_grade_import_batches_path
    refute GradeImportFile.exists?(file.id)
    refute GradeCompetencyEvidence.exists?(evidence.id)
    refute GradeCompetencyRating.exists?(rating.id)
    activity = AdminActivityLog.where(action: "grade_import_action").order(created_at: :desc).first
    assert_equal "delete", activity.metadata["import_action"]
    assert_equal batch.id, activity.metadata["batch_id"]

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
      program_semester: program_semesters(:fall_2025),
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

  def create_test_competency!(title)
    domain = Domain.find_or_create_by!(name: "Test Import Domain") do |record|
      record.position = 100
    end
    Competency.find_or_create_by!(title: title) do |record|
      record.domain = domain
      record.position = 100
    end
  end

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

  def uploaded_text_file(filename, content)
    file = Tempfile.new([ "unsupported-upload", File.extname(filename) ])
    path = file.path
    file.write(content)
    file.close
    @temp_paths << path

    Rack::Test::UploadedFile.new(path, "text/plain", true, original_filename: filename)
  end
end
