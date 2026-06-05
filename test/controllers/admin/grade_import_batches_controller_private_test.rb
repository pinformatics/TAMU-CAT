require "test_helper"

class Admin::GradeImportBatchesControllerPrivateTest < ActionController::TestCase
  tests Admin::GradeImportBatchesController
  include ActiveJob::TestHelper

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in users(:admin)
    @admin = users(:admin)
    @student = students(:student)
    @batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      program_semester: program_semesters(:fall_2025),
      summary: { "dry_run" => false, "import_notes" => "Spring law import" }
    )
    @controller.instance_variable_set(:@batch, @batch)
  end

  test "grade import filters cover workflow semester uploader status and search branches" do
    preview = GradeImportBatch.create!(uploaded_by: @admin, status: "completed", summary: { "dry_run" => true })
    committed = GradeImportBatch.create!(uploaded_by: @admin, status: "completed_with_errors", summary: { "dry_run" => false })
    rolled_back = GradeImportBatch.create!(uploaded_by: @admin, status: "rolled_back", summary: { "dry_run" => true })
    finalized = GradeImportBatch.create!(uploaded_by: @admin, status: "completed", summary: { "finalized_at" => Time.current.iso8601 })
    no_semester = GradeImportBatch.create!(uploaded_by: @admin, status: "failed", summary: {})

    assert_includes @controller.send(:apply_grade_import_workflow_filter, GradeImportBatch.all, "preview"), preview
    refute_includes @controller.send(:apply_grade_import_workflow_filter, GradeImportBatch.all, "preview"), rolled_back
    assert_includes @controller.send(:apply_grade_import_workflow_filter, GradeImportBatch.all, "committed"), committed
    assert_includes @controller.send(:apply_grade_import_workflow_filter, GradeImportBatch.all, "rolled_back"), rolled_back
    assert_includes @controller.send(:apply_grade_import_workflow_filter, GradeImportBatch.all, "finalized"), finalized
    assert_equal GradeImportBatch.count, @controller.send(:apply_grade_import_workflow_filter, GradeImportBatch.all, "unknown").count

    assert_includes @controller.send(:apply_grade_import_semester_filter, GradeImportBatch.all, "none"), no_semester
    assert_includes @controller.send(:apply_grade_import_semester_filter, GradeImportBatch.all, program_semesters(:fall_2025).id.to_s), @batch
    assert_equal GradeImportBatch.count, @controller.send(:apply_grade_import_semester_filter, GradeImportBatch.all, "").count
    assert_includes @controller.send(:apply_grade_import_uploader_filter, GradeImportBatch.all, @admin.id.to_s), @batch
    assert_equal GradeImportBatch.count, @controller.send(:apply_grade_import_uploader_filter, GradeImportBatch.all, "").count

    file = @batch.grade_import_files.create!(file_name: "law-export.csv", file_checksum: "search-#{SecureRandom.hex(4)}", status: "processed")
    @batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "Missing Student",
      student_identifier_type: "student_name",
      student_name: "Missing Student",
      course_code: "PHPM-633",
      assignment_name: "Case",
      competency_title: "Policy Analysis",
      raw_grade: 80,
      mapped_level: 3,
      row_number: 2,
      source_key: "pending-search",
      import_fingerprint: "pending-search"
    )

    assert_equal GradeImportBatch.count, @controller.send(:apply_grade_import_search_filter, GradeImportBatch.all, " ").count
    assert_includes @controller.send(:apply_grade_import_search_filter, GradeImportBatch.all, "law-export"), @batch
    assert_includes @controller.send(:apply_grade_import_search_filter, GradeImportBatch.all, "PHPM-633"), @batch
    assert_includes @controller.send(:apply_grade_import_search_filter, GradeImportBatch.all, "Spring law"), @batch

    @controller.instance_variable_set(:@batch_filters, {
      "status" => "completed",
      "workflow" => "committed",
      "program_semester_id" => program_semesters(:fall_2025).id.to_s,
      "uploaded_by_id" => @admin.id.to_s,
      "q" => "Spring law"
    })
    assert_includes @controller.send(:filtered_grade_import_batches), @batch
  end

  test "pending row parameter helpers normalize ids blank levels and raw hash params" do
    @controller.instance_variable_set(:@_params, ActionController::Parameters.new(
      pending_row_ids: [ "0", "", "12", "12", "abc", "7" ],
      grade_import_pending_row_group: {
        matched_student_id: @student.student_id,
        student_identifier: "Student User",
        student_identifier_type: "",
        student_name: "Student User"
      },
      pending_rows: {
        "12" => {
          course_code: "PHPM-601",
          assignment_name: "Case",
          competency_title: "Policy Analysis",
          raw_grade: "88",
          mapped_level: "4",
          course_target_level: ""
        },
        "13" => nil
      },
      grade_competency_evidence: {
        course_code: "PHPM-602",
        assignment_name: "Brief",
        competency_title: "Communication",
        raw_grade: "90",
        mapped_level: "5",
        course_target_level: ""
      }
    ))

    assert_equal [ 12, 7 ], @controller.send(:normalized_pending_row_ids)
    group_params = @controller.send(:pending_row_group_params)
    assert_nil group_params[:student_identifier_type]
    updates = @controller.send(:normalized_pending_row_updates)
    assert_nil updates["12"][:course_target_level]
    assert_equal "PHPM-601", updates["12"][:course_code]
    assert_nil updates["13"][:course_target_level]
    assert_nil @controller.send(:evidence_params)[:course_target_level]
  end

  test "pending student counts de-duplicate identities by file" do
    file = @batch.grade_import_files.create!(file_name: "pending.csv", file_checksum: "pending-#{SecureRandom.hex(4)}", status: "processed")
    2.times do |index|
      @batch.grade_import_pending_rows.create!(
        grade_import_file: file,
        student_identifier: "Missing Student",
        student_identifier_type: "student_name",
        student_name: "Missing Student",
        course_code: "PHPM-601",
        assignment_name: "Case #{index}",
        competency_title: "Policy Analysis",
        raw_grade: 80,
        mapped_level: 3,
        row_number: index + 2,
        source_key: "pending-count-#{index}",
        import_fingerprint: "pending-count-#{index}"
      )
    end
    @batch.grade_import_pending_rows.create!(
      grade_import_file: file,
      student_identifier: "",
      student_identifier_type: "",
      student_email: "other@example.com",
      student_name: "",
      course_code: "PHPM-601",
      assignment_name: "Case 3",
      competency_title: "Communication",
      raw_grade: 82,
      mapped_level: 4,
      row_number: 4,
      source_key: "pending-count-email",
      import_fingerprint: "pending-count-email"
    )

    counts = @controller.send(:pending_student_counts_by_file)

    assert_equal 2, counts[file.id]
  end

  test "activity notification and export helper branches handle empty and populated data" do
    file = @batch.grade_import_files.create!(file_name: "ratings.csv", file_checksum: "ratings-#{SecureRandom.hex(4)}", status: "processed", imported_rows: 1)
    evidence = @batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      course_code: "PHPM-601",
      assignment_name: "Case",
      competency_title: "Policy Analysis",
      raw_grade: 88,
      mapped_level: 4,
      course_target_level: nil,
      row_number: 2,
      source_key: "ratings-export-source",
      import_fingerprint: "ratings-export-fingerprint"
    )
    @batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: "Policy Analysis",
      aggregated_level: 4,
      aggregation_rule: "max",
      evidence_count: 1
    )

    assert_nil @controller.send(:match_rate_for, [])
    assert_equal 100.0, @controller.send(:match_rate_for, [ file ])
    assert_difference "AdminActivityLog.count", 1 do
      @controller.send(:record_grade_import_activity!, "export", "Exported ratings", file_id: file.id, ignored_blank: nil)
    end
    activity = AdminActivityLog.order(:created_at).last
    assert_equal "export", activity.metadata["import_action"]
    assert_equal file.id, activity.metadata["file_id"]
    assert_equal @batch.id, activity.metadata["batch_id"]

    rows = @controller.send(:ratings_export_rows)
    assert_equal @student.user.name, rows.first[:student_name]
    assert_equal "target=none", rows.first[:provenance_details].split(" | ").find { |part| part == "target=none" }
    assert_equal "No target", @controller.send(:target_met_export_label, evidence.mapped_level, evidence.course_target_level)
  end

  test "advisor course data notifications cover blank counts singular plural and rescue branch" do
    assert_nothing_raised { @controller.send(:notify_advisors_of_course_data_update!, "uploaded") }

    file = @batch.grade_import_files.create!(file_name: "notify.csv", file_checksum: "notify-#{SecureRandom.hex(4)}", status: "processed")
    @batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      course_code: "PHPM-601",
      assignment_name: "Case",
      competency_title: "Policy Analysis",
      raw_grade: 88,
      mapped_level: 4,
      row_number: 2,
      source_key: "notify-source",
      import_fingerprint: "notify-fingerprint"
    )

    assert_difference "Notification.count", 1 do
      assert_enqueued_jobs 1, only: NotificationEmailDeliveryJob do
        @controller.send(:notify_advisors_of_course_data_update!, "uploaded")
      end
    end
    assert_match "1 advisee", Notification.order(:created_at).last.message

    Notification.stub(:deliver!, ->(**_kwargs) { raise StandardError, "mail fail" }) do
      assert_nothing_raised { @controller.send(:notify_advisors_of_course_data_update!, "uploaded") }
    end
  end
end
