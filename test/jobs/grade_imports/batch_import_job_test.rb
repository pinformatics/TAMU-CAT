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
