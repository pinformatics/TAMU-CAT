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

    def perform(batch_id:, uploaded_by_id:, dry_run:, files_payload:)
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
        # job's lifetime.
        payload["base64"] = nil
        UploadedFilePayload.new(tempfile.path, payload["filename"], payload["content_type"])
      end
      GC.start

      GradeImports::BatchProcessor.new(batch: batch, files: files, dry_run: dry_run).call
      GC.start

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
  end
end
