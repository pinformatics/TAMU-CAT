require "test_helper"

class CourseCompetencyReleaseNotifierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include Rails.application.routes.url_helpers

  setup do
    @admin = users(:admin)
    @student = students(:student)
    @advisor = users(:advisor)
    @student.update!(advisor_id: @advisor.id)
    @semester = program_semesters(:fall_2025)
    @batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: @semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    @file = @batch.grade_import_files.create!(
      file_name: "release-notify.csv",
      file_checksum: "checksum-release-notify",
      status: "processed"
    )
    @batch.grade_competency_evidences.create!(
      grade_import_file: @file,
      student: @student,
      assignment_name: "Final",
      course_code: "PHPM-601",
      competency_title: "Policy Analysis",
      raw_grade: 5,
      mapped_level: 5,
      course_target_level: 4,
      source_key: "release-notify",
      import_fingerprint: "fingerprint-release-notify"
    )
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "creates student and advisor notifications when course results are released" do
    assert_difference -> { Notification.count }, 2 do
      assert_enqueued_jobs 2, only: NotificationEmailDeliveryJob do
        result = CourseCompetencyReleaseNotifier.new(semester: @semester, triggered_by_id: @admin.id).call

        assert_equal 1, result.student_count
        assert_equal 1, result.advisor_count
      end
    end

    student_notification = Notification.find_by!(user: @student.user, title: "Course Competency Results Released")
    advisor_notification = Notification.find_by!(user: @advisor, title: "Advisee Course Competency Results Released")

    assert_match @semester.name, student_notification.message
    assert_match "advisee", advisor_notification.message
    assert_equal @semester, student_notification.notifiable
    assert_equal "course_results.released", student_notification.event_key
    assert_equal "course_results.released:semester:#{@semester.id}:student:#{@student.student_id}", student_notification.dedupe_key
    assert_equal @semester.id, student_notification.metadata["program_semester_id"]
    assert_equal @student.student_id, student_notification.metadata["student_id"]
    assert_equal "advisee.course_results.released", advisor_notification.event_key
    assert_equal "advisee.course_results.released:semester:#{@semester.id}:advisor:#{@advisor.id}", advisor_notification.dedupe_key
    assert_equal 1, advisor_notification.metadata["advisee_count"]
    assert_equal student_competencies_path, student_notification.target_path_for(@student.user)
    assert_equal reports_path, advisor_notification.target_path_for(@advisor)
  end

  test "does not notify while semester course results are embargoed" do
    @semester.course_grade_release_date || @semester.build_course_grade_release_date
    @semester.course_grade_release_date.update!(release_date: 1.day.from_now)

    assert_no_difference -> { Notification.count } do
      assert_no_enqueued_jobs only: NotificationEmailDeliveryJob do
        result = CourseCompetencyReleaseNotifier.new(semester: @semester).call

        assert_equal 0, result.student_count
        assert_equal 0, result.advisor_count
      end
    end
  end
end
