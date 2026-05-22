# frozen_string_literal: true

class CourseCompetencyReleaseNotificationJob < ApplicationJob
  queue_as :default

  def perform(program_semester_id:, triggered_by_id: nil)
    semester = ProgramSemester.find(program_semester_id)
    CourseCompetencyReleaseNotifier.new(semester: semester, triggered_by_id: triggered_by_id).call
  rescue ActiveRecord::RecordNotFound => error
    Rails.logger.warn("[CourseCompetencyReleaseNotificationJob] skipped: #{error.message}")
  end
end
