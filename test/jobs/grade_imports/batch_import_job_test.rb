require "test_helper"
require "base64"

module GradeImports
  class BatchImportJobTest < ActiveJob::TestCase
    setup do
      @admin = users(:admin)
      @student = students(:student)
      @batch = GradeImportBatch.create!(uploaded_by: @admin, status: "pending", summary: { "dry_run" => true })
    end

    test "queue adapter is solid_queue regardless of the app-wide default" do
      assert_instance_of ActiveJob::QueueAdapters::SolidQueueAdapter, GradeImports::BatchImportJob.queue_adapter
      refute_instance_of ActiveJob::QueueAdapters::InlineAdapter, GradeImports::BatchImportJob.queue_adapter
    end

    test "perform_now processes an in-memory file payload and creates evidence" do
      files_payload = [ direct_competency_csv_payload ]

      assert_difference -> { GradeCompetencyEvidence.count }, 1 do
        assert_difference -> { AdminActivityLog.count }, 1 do
          GradeImports::BatchImportJob.perform_now(
            batch_id: @batch.id,
            uploaded_by_id: @admin.id,
            dry_run: true,
            files_payload: files_payload
          )
        end
      end

      @batch.reload
      assert_equal "completed", @batch.status
      evidence = @batch.grade_competency_evidences.first
      assert_equal 5, evidence.mapped_level
      assert_equal 3, evidence.course_target_level

      activity = AdminActivityLog.order(:created_at).last
      assert_equal "grade_import_action", activity.action
      assert_equal @admin, activity.admin
    end

    test "failure path marks the batch failed and notifies admins" do
      files_payload = [ direct_competency_csv_payload ]
      processor_double = Object.new
      def processor_double.call
        raise "boom"
      end

      GradeImports::BatchProcessor.stub(:new, ->(*_args, **_kwargs) { processor_double }) do
        assert_difference -> { Notification.where(event_key: "grade_import.failed").count }, 1 do
          GradeImports::BatchImportJob.perform_now(
            batch_id: @batch.id,
            uploaded_by_id: @admin.id,
            dry_run: true,
            files_payload: files_payload
          )
        end
      end

      @batch.reload
      assert_equal "failed", @batch.status
      assert_equal "boom", @batch.summary["error"]
    end

    test "a paused attempt that made progress schedules an automatic resume" do
      files_payload = [ direct_competency_csv_payload ]
      batch = @batch
      student_id = @student.student_id

      processor_double = Object.new
      processor_double.define_singleton_method(:call) do
        file = batch.grade_import_files.create!(file_name: "f.csv", file_checksum: "checksum-a", status: "paused")
        GradeCompetencyEvidence.create!(
          grade_import_batch: batch, grade_import_file: file, student_id: student_id,
          competency_title: "Systems Thinking", raw_grade: 3, mapped_level: 3,
          source_key: "fp-a", import_fingerprint: "fp-a"
        )
        batch.update!(status: "processing", summary: batch.summary.merge("needs_continuation" => true))
      end

      GradeImports::BatchProcessor.stub(:new, ->(*_args, **_kwargs) { processor_double }) do
        assert_difference -> { SolidQueue::Job.where(class_name: "GradeImports::BatchImportJob").count }, 1 do
          GradeImports::BatchImportJob.perform_now(
            batch_id: batch.id,
            uploaded_by_id: @admin.id,
            dry_run: true,
            files_payload: files_payload
          )
        end
      end

      batch.reload
      assert_equal "processing", batch.status
      assert batch.summary["needs_continuation"]
      assert_equal 1, batch.summary["last_resume_progress"]

      scheduled_job = SolidQueue::Job.where(class_name: "GradeImports::BatchImportJob").order(:id).last
      assert_equal 1, scheduled_job.arguments["arguments"].first["resume_attempt"]
    end

    test "gives up and notifies admins when a paused attempt makes no further progress" do
      files_payload = [ direct_competency_csv_payload ]
      batch = @batch
      student_id = @student.student_id
      file = batch.grade_import_files.create!(file_name: "f.csv", file_checksum: "checksum-b", status: "paused")
      GradeCompetencyEvidence.create!(
        grade_import_batch: batch, grade_import_file: file, student_id: student_id,
        competency_title: "Systems Thinking", raw_grade: 3, mapped_level: 3,
        source_key: "fp-b", import_fingerprint: "fp-b"
      )
      batch.update!(summary: batch.summary.merge("last_resume_progress" => 1))

      processor_double = Object.new
      processor_double.define_singleton_method(:call) do
        # No new evidence created this attempt -- progress is unchanged from last_resume_progress.
        batch.update!(status: "processing", summary: batch.summary.merge("needs_continuation" => true))
      end

      GradeImports::BatchProcessor.stub(:new, ->(*_args, **_kwargs) { processor_double }) do
        assert_no_difference -> { SolidQueue::Job.where(class_name: "GradeImports::BatchImportJob").count } do
          assert_difference -> { Notification.where(event_key: "grade_import.failed").count }, 1 do
            GradeImports::BatchImportJob.perform_now(
              batch_id: batch.id,
              uploaded_by_id: @admin.id,
              dry_run: true,
              files_payload: files_payload,
              resume_attempt: 3
            )
          end
        end
      end

      batch.reload
      assert_equal "failed", batch.status
      assert_not batch.summary["needs_continuation"]
      assert_includes batch.summary["error"], "could not finish automatically"
    end

    private

    def direct_competency_csv_payload
      csv_content = <<~CSV
        Student name,Student ID,Student SIS ID,EMHA competencies > Legal & Ethical Bases for Health Services and Health Systems result,EMHA competencies > Legal & Ethical Bases for Health Services and Health Systems mastery points
        #{@student.user.name},#{@student.student_id},#{@student.uin},5,3
      CSV

      {
        "filename" => "PHPM_790_001.csv",
        "content_type" => "text/csv",
        "base64" => Base64.strict_encode64(csv_content)
      }
    end
  end
end
