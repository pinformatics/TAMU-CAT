# frozen_string_literal: true

class CourseCompetencyReleaseNotifier
  def initialize(semester:, triggered_by_id: nil)
    @semester = semester
    @triggered_by_id = triggered_by_id
  end

  def call
    return Result.new(student_count: 0, advisor_count: 0) unless released?

    student_notifications = notify_students
    advisor_notifications = notify_advisors

    Result.new(student_count: student_notifications, advisor_count: advisor_notifications)
  end

  Result = Struct.new(:student_count, :advisor_count, keyword_init: true)

  private

  attr_reader :semester, :triggered_by_id

  def released?
    release = semester.course_grade_release_date
    release.blank? || release.released?
  end

  def evidence_scope
    GradeCompetencyEvidence
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .where(grade_import_batches: { program_semester_id: semester.id })
  end

  def notify_students
    Student.includes(:user).where(student_id: evidence_scope.select(:student_id).distinct).sum do |student|
      next 0 unless student.user

      notification = Notification.deliver!(
        user: student.user,
        title: "Course Competency Results Released",
        message: "Your course competency results for #{semester.name} are now available in My Competencies.",
        notifiable: semester
      )
      enqueue_email(notification)
      1
    end
  end

  def notify_advisors
    advisor_ids = Student.where(student_id: evidence_scope.select(:student_id).distinct).where.not(advisor_id: nil).distinct.pluck(:advisor_id)

    User.where(id: advisor_ids).find_each.sum do |advisor_user|
      advisee_count = Student.where(advisor_id: advisor_user.id, student_id: evidence_scope.select(:student_id).distinct).count
      notification = Notification.deliver!(
        user: advisor_user,
        title: "Advisee Course Competency Results Released",
        message: "#{advisee_count} advisee#{'s' unless advisee_count == 1} have newly available #{semester.name} course competency results.",
        notifiable: semester
      )
      enqueue_email(notification)
      1
    end
  end

  def enqueue_email(notification)
    NotificationEmailDeliveryJob.perform_later(notification_id: notification.id)
  end
end
