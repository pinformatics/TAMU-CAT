module GradeImports
  # Catches batches abandoned mid-import -- most commonly because the dyno
  # processing them was killed (e.g. Heroku R14/R15 memory kill) before the
  # job's own rescue/ensure blocks had a chance to run. Without this, such a
  # batch sits at status "processing" forever with no operator visibility;
  # this marks it failed and notifies admins, on a recurring schedule (see
  # config/recurring.yml).
  class StaleBatchWatchdog
    STALE_AFTER = 45.minutes

    def self.run!
      new.run!
    end

    def run!
      stale_batches.find_each { |batch| fail_stale_batch!(batch) }
    end

    private

    def stale_batches
      GradeImportBatch.where(status: "processing").where(started_at: ...STALE_AFTER.ago)
    end

    def fail_stale_batch!(batch)
      message = "Processing did not finish within #{STALE_AFTER.inspect}, most likely because the " \
                "background worker was interrupted (for example, a server restart). Rows already " \
                "imported before the interruption are preserved. Re-upload the same file to safely " \
                "continue -- already-imported rows are skipped automatically."

      batch.update!(
        status: "failed",
        completed_at: Time.current,
        summary: batch.summary.merge("error" => message)
      )

      GradeImports::BatchAuditNotifier
        .new(batch: batch, actor: batch.uploaded_by)
        .notify_admins_of_grade_import_failure!(message)
    rescue StandardError => e
      Rails.logger.error("[GradeImports::StaleBatchWatchdog] Failed to fail stale batch ##{batch.id}: #{e.class}: #{e.message}")
    end
  end
end
