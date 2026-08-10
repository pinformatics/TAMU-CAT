# Records admin activity and sends advisor/admin notifications for grade
# import batch actions. Extracted from Admin::GradeImportBatchesController so
# it can run from both the controller (approve/commit/rollback/etc, which
# stay synchronous) and GradeImports::BatchImportJob (the async upload path),
# without depending on request-scoped state like current_user.
module GradeImports
  class BatchAuditNotifier
    def initialize(batch:, actor:, request_path: nil)
      @batch = batch
      @actor = actor
      @request_path = request_path
    end

    def record_activity!(import_action, description, metadata = {})
      return unless actor && batch

      AdminActivityLog.record!(
        admin: actor,
        action: "grade_import_action",
        description: description,
        subject: batch,
        metadata: activity_metadata(import_action).merge(metadata.compact)
      )
    rescue StandardError => e
      Rails.logger.warn("[GradeImportAudit] Failed to record import activity: #{e.class}: #{e.message}")
    end

    def notify_advisors_of_course_data_update!(action_label)
      advisor_counts = Student
        .where(student_id: batch.grade_competency_evidences.select(:student_id))
        .where.not(advisor_id: nil)
        .group(:advisor_id)
        .count
      return if advisor_counts.blank?

      User.advisors.where(id: advisor_counts.keys).find_each do |advisor_user|
        count = advisor_counts[advisor_user.id].to_i
        noun = count == 1 ? "advisee" : "advisees"
        semester_label = batch.program_semester&.name
        semester_phrase = semester_label.present? ? " for #{semester_label}" : ""
        notification = Notification.deliver!(
          user: advisor_user,
          title: "Advisee Course Competency Data Updated",
          message: "Course competency data was #{action_label}#{semester_phrase} for #{count} #{noun} you advise.",
          notifiable: batch,
          event_key: "advisee.course_data.updated",
          dedupe_key: "advisee.course_data.updated:batch:#{batch.id}:advisor:#{advisor_user.id}:action:#{action_label}",
          metadata: {
            batch_id: batch.id,
            advisor_id: advisor_user.id,
            advisee_count: count,
            action: action_label,
            program_semester_id: batch.program_semester_id,
            program_semester_name: semester_label
          }
        )
        NotificationEmailDeliveryJob.perform_later(notification_id: notification.id)
      end
    rescue StandardError => e
      Rails.logger.warn("[GradeImportNotifications] Failed advisor notification for batch #{batch&.id}: #{e.class}: #{e.message}")
    end

    def notify_admins_of_grade_import_review_if_needed!(action_label)
      summary = attention_summary
      return unless summary[:needs_review]

      reasons = summary[:reasons].presence || [ "review is required before this batch can be committed" ]
      notify_admins_of_grade_import_event!(
        event_key: "grade_import.review_needed",
        title: "Grade Import Needs Review",
        message: "Grade import batch ##{batch.id} needs admin review after #{action_label}: #{reasons.to_sentence}.",
        metadata: attention_metadata(summary, action_label: action_label)
      )
    end

    def notify_admins_of_grade_import_failure!(error_message)
      summary = attention_summary(error_message: error_message)
      notify_admins_of_grade_import_event!(
        event_key: "grade_import.failed",
        title: "Grade Import Failed",
        message: "Grade import batch ##{batch.id} failed: #{error_message}.",
        metadata: attention_metadata(summary, action_label: "failure", error_message: error_message)
      )
    end

    def notify_admins_of_missing_grade_import_semester!
      return unless batch&.reportable?
      return if batch.program_semester_id.present?

      notify_admins_of_grade_import_event!(
        event_key: "grade_import.missing_semester",
        title: "Grade Import Missing Semester",
        message: "Grade import batch ##{batch.id} is reportable but does not have a semester assigned. Add a semester so reports and student views filter correctly.",
        metadata: {
          batch_id: batch.id,
          status: batch.status,
          dry_run: batch.dry_run?,
          reportable: batch.reportable?,
          program_semester_id: batch.program_semester_id
        }
      )
    end

    private

    attr_reader :batch, :actor, :request_path

    def notify_admins_of_grade_import_event!(event_key:, title:, message:, metadata:)
      User.admins.find_each do |admin_user|
        notification = Notification.deliver!(
          user: admin_user,
          title: title,
          message: message,
          notifiable: batch,
          event_key: event_key,
          dedupe_key: "#{event_key}:batch:#{batch.id}:admin:#{admin_user.id}",
          metadata: metadata.merge(admin_id: admin_user.id)
        )
        NotificationEmailDeliveryJob.perform_later(notification_id: notification.id) if notification
      end
    rescue StandardError => e
      Rails.logger.warn("[GradeImportNotifications] Failed admin notification for batch #{batch&.id}: #{e.class}: #{e.message}")
    end

    def attention_summary(error_message: nil)
      target_summary = GradeImports::TargetWarningAnalyzer.call(batch: batch)
      target_counts = target_summary.fetch(:counts, {})
      files = batch.grade_import_files.to_a
      failed_file_count = files.count { |file| file.status == "failed" || Array(file.parse_errors).any? }
      failed_row_count = files.sum(&:error_rows)
      pending_row_count = batch.grade_import_pending_rows.pending_student_match.count
      course_code_issue_count = target_counts[:course_code_issues].to_i
      missing_target_count = target_counts[:missing_course_targets].to_i
      mismatched_target_count = target_counts[:mismatched_configured_course_targets].to_i

      reasons = []
      reasons << error_message if error_message.present?
      reasons << count_phrase(failed_file_count, "failed file") if failed_file_count.positive?
      reasons << count_phrase(failed_row_count, "failed row") if failed_row_count.positive?
      reasons << count_phrase(pending_row_count, "pending student match", "pending student matches") if pending_row_count.positive?
      reasons << count_phrase(course_code_issue_count, "course code issue") if course_code_issue_count.positive?
      reasons << count_phrase(missing_target_count, "missing course target") if missing_target_count.positive?
      reasons << count_phrase(mismatched_target_count, "course target mismatch", "course target mismatches") if mismatched_target_count.positive?
      reasons << "preview completed with errors" if reasons.blank? && batch.completed_with_errors?

      {
        needs_review: error_message.present? || batch.failed? || batch.needs_admin_approval? || target_summary[:requires_review],
        reasons: reasons,
        failed_file_count: failed_file_count,
        failed_row_count: failed_row_count,
        pending_row_count: pending_row_count,
        course_code_issue_count: course_code_issue_count,
        missing_target_count: missing_target_count,
        mismatched_target_count: mismatched_target_count
      }
    end

    def attention_metadata(summary, action_label:, error_message: nil)
      {
        batch_id: batch.id,
        action: action_label,
        status: batch.status,
        dry_run: batch.dry_run?,
        reportable: batch.reportable?,
        program_semester_id: batch.program_semester_id,
        program_semester_name: batch.program_semester&.name,
        failed_file_count: summary[:failed_file_count],
        failed_row_count: summary[:failed_row_count],
        pending_row_count: summary[:pending_row_count],
        course_code_issue_count: summary[:course_code_issue_count],
        missing_target_count: summary[:missing_target_count],
        mismatched_target_count: summary[:mismatched_target_count],
        reasons: summary[:reasons],
        error_message: error_message
      }.compact
    end

    def count_phrase(count, singular, plural = nil)
      "#{count} #{count == 1 ? singular : (plural || singular.pluralize)}"
    end

    def activity_metadata(import_action)
      {
        import_action: import_action,
        batch_id: batch.id,
        status: batch.status,
        dry_run: batch.dry_run?,
        finalized: batch.finalized?,
        program_semester_id: batch.program_semester_id,
        program_semester_name: batch.program_semester&.name,
        file_count: batch.grade_import_files.count,
        evidence_count: batch.grade_competency_evidences.count,
        pending_count: batch.grade_import_pending_rows.pending_student_match.count,
        rating_count: batch.grade_competency_ratings.count,
        path: request_path
      }
    end
  end
end
