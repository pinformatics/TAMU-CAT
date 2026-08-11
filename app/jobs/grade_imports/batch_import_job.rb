require "base64"
require "tempfile"

module GradeImports
  # Runs GradeImports::BatchProcessor outside the request/response cycle, so
  # large files don't hit Heroku's 30s router timeout. Uses Solid Queue
  # specifically for this job class only -- the app-wide Active Job adapter
  # stays :inline (see config/environments/production.rb) since no other job
  # in the app has ever been verified running genuinely async in production.
  #
  # Uploaded files can't be passed as ActionDispatch::Http::UploadedFile
  # objects (their Tempfiles are deleted when the request ends, and Heroku
  # dynos don't share a filesystem), so the controller reads each file's
  # bytes into `files_payload` before enqueuing, and this job reconstructs
  # local Tempfiles that satisfy the same duck-type BatchProcessor already
  # expects (.path, .original_filename, .content_type).
  class BatchImportJob < ApplicationJob
    self.queue_adapter = :solid_queue

    # The base64 file payload can be large; ActiveJob's default logging
    # dumps full argument values (job.arguments.inspect) into the Rails
    # log on both enqueue and perform, which floods Heroku's log line with
    # megabytes of encoded bytes for every import.
    self.log_arguments = false

    UploadedFilePayload = Struct.new(:path, :original_filename, :content_type)

    # Safety valve for GradeImports::BatchProcessor's memory guard (see
    # MemoryGuardPause there): caps how many times this job will
    # automatically re-enqueue itself to continue a paused import, in case a
    # file genuinely can never finish (e.g. the dyno's baseline memory alone
    # already exceeds the guard's ceiling, so every attempt pauses at row 1
    # without making progress).
    MAX_RESUME_ATTEMPTS = 40
    RESUME_DELAY = 20.seconds

    def perform(batch_id:, uploaded_by_id:, dry_run:, files_payload:, resume_attempt: 0)
      batch = GradeImportBatch.find(batch_id)
      uploaded_by = User.find_by(id: uploaded_by_id)
      tempfiles = []

      files = files_payload.map do |payload|
        tempfile = Tempfile.new([ "grade_import", File.extname(payload["filename"].to_s) ])
        tempfile.binmode
        tempfile.write(Base64.decode64(payload["base64"]))
        tempfile.flush
        tempfiles << tempfile
        # Drop the (often multi-MB) base64 string as soon as it's decoded,
        # rather than keeping it alive in files_payload for the rest of the
        # job's lifetime. If this attempt pauses and needs to resume, the
        # tempfile on disk is re-encoded fresh instead.
        payload["base64"] = nil
        UploadedFilePayload.new(tempfile.path, payload["filename"], payload["content_type"])
      end
      GC.start

      GradeImports::BatchProcessor.new(batch: batch, files: files, dry_run: dry_run).call
      GC.start
      batch.reload

      if batch.summary["needs_continuation"]
        resume_or_give_up!(batch: batch, uploaded_by_id: uploaded_by_id, dry_run: dry_run, files: files, resume_attempt: resume_attempt)
        return
      end

      notifier = GradeImports::BatchAuditNotifier.new(batch: batch, actor: uploaded_by)
      notifier.record_activity!(
        "upload",
        "Uploaded grade import batch ##{batch.id} as #{dry_run ? 'a preview' : 'a committed import'}.",
        file_names: files.map { |file| file.original_filename.to_s }
      )
      notifier.notify_advisors_of_course_data_update!("uploaded") if batch.reportable?
      notifier.notify_admins_of_grade_import_review_if_needed!("upload")
      notifier.notify_admins_of_missing_grade_import_semester! if batch.reportable?
    rescue StandardError => e
      Rails.logger.error("[GradeImports::BatchImportJob] #{e.class}: #{e.message}")
      if batch&.persisted?
        batch.update(status: "failed", completed_at: Time.current, summary: { "error" => e.message })
        GradeImports::BatchAuditNotifier.new(batch: batch, actor: uploaded_by).notify_admins_of_grade_import_failure!(e.message)
      end
    ensure
      tempfiles&.each do |tempfile|
        tempfile.close
        tempfile.unlink
      end
    end

    private

    # Re-enqueues this job to continue a paused import, as long as the last
    # attempt actually made progress -- otherwise (e.g. the process's
    # baseline memory alone already exceeds the guard's ceiling, so nothing
    # can ever get processed) this gives up and notifies admins instead of
    # looping forever without doing anything useful.
    def resume_or_give_up!(batch:, uploaded_by_id:, dry_run:, files:, resume_attempt:)
      progress = batch.grade_competency_evidences.count + batch.grade_import_pending_rows.count
      made_progress = progress > batch.summary["last_resume_progress"].to_i

      if !made_progress || resume_attempt >= MAX_RESUME_ATTEMPTS
        message = "Import could not finish automatically after #{resume_attempt + 1} attempt(s) " \
                  "(#{made_progress ? "attempt limit reached" : "stopped making progress"}). " \
                  "Rows already imported are preserved. This needs manual attention."
        batch.update!(
          status: "failed",
          completed_at: Time.current,
          summary: batch.summary.merge("needs_continuation" => false, "error" => message)
        )
        GradeImports::BatchAuditNotifier
          .new(batch: batch, actor: User.find_by(id: uploaded_by_id))
          .notify_admins_of_grade_import_failure!(message)
        return
      end

      batch.update!(summary: batch.summary.merge("last_resume_progress" => progress))

      resumed_files_payload = files.map do |file|
        {
          "filename" => file.original_filename,
          "content_type" => file.content_type,
          "base64" => Base64.strict_encode64(File.binread(file.path))
        }
      end

      self.class.set(wait: RESUME_DELAY).perform_later(
        batch_id: batch.id,
        uploaded_by_id: uploaded_by_id,
        dry_run: dry_run,
        files_payload: resumed_files_payload,
        resume_attempt: resume_attempt + 1
      )
    end
  end
end
