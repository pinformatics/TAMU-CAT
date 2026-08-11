module GradeImports
  # Catches batches abandoned mid-import -- most commonly because the dyno
  # processing them was killed (e.g. Heroku R14/R15 memory kill) at a point
  # BatchProcessor's own memory guard didn't catch, before the job's rescue/
  # ensure blocks had a chance to run or schedule a resume. Without this,
  # such a batch sits at status "processing" forever with no operator
  # visibility; this marks it failed and notifies admins, on a recurring
  # schedule (see config/recurring.yml).
  #
  # Keyed off updated_at, not started_at/how long the batch has existed --
  # GradeImports::BatchImportJob's memory guard can legitimately keep a
  # large import "processing" across many auto-resumed chunks over a long
  # total wall-clock time, but each live chunk touches the batch/its files
  # well within STALE_AFTER. A long gap since the last touch is what
  # actually indicates nothing is working on it anymore.
  class StaleBatchWatchdog
    STALE_AFTER = 20.minutes

    def self.run!
      new.run!
    end

    def run!
      processing_batches.each { |batch| fail_stale_batch!(batch) if stale?(batch) }
    end

    private

    def processing_batches
      GradeImportBatch.where(status: "processing")
    end

    # A batch's own updated_at only changes at the start/end of each
    # BatchProcessor#call attempt; a single slow-but-healthy chunk touches
    # its GradeImportFile periodically instead (see the heartbeat in
    # BatchProcessor#process_canvas_outcomes_rows!), so the real signal is
    # whichever of the two was touched most recently.
    def stale?(batch)
      last_activity = [ batch.updated_at, batch.grade_import_files.maximum(:updated_at) ].compact.max
      last_activity.nil? || last_activity < STALE_AFTER.ago
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
