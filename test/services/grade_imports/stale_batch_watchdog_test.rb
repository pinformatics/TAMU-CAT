require "test_helper"

class GradeImports::StaleBatchWatchdogTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
  end

  test "fails a batch stuck processing past the staleness window and notifies admins" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "processing",
      started_at: 1.hour.ago,
      summary: { "dry_run" => true }
    )
    batch.update_column(:updated_at, 1.hour.ago)

    assert_difference -> { Notification.count } do
      GradeImports::StaleBatchWatchdog.run!
    end

    batch.reload
    assert_equal "failed", batch.status
    assert batch.completed_at.present?
    assert_includes batch.summary["error"], "Re-upload the same file"
  end

  test "leaves recently-started processing batches alone" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "processing",
      started_at: 5.minutes.ago,
      summary: { "dry_run" => true }
    )

    assert_no_difference -> { Notification.count } do
      GradeImports::StaleBatchWatchdog.run!
    end

    assert_equal "processing", batch.reload.status
  end

  test "leaves non-processing batches alone regardless of age" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      status: "completed",
      started_at: 1.hour.ago,
      completed_at: 1.hour.ago,
      summary: { "dry_run" => true }
    )

    GradeImports::StaleBatchWatchdog.run!

    assert_equal "completed", batch.reload.status
  end
end
