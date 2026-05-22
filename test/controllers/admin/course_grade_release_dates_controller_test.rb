require "test_helper"

class Admin::CourseGradeReleaseDatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @survey = surveys(:fall_2025)
    @semester = @survey.program_semester
  end

  test "admin can view course grade release dates" do
    sign_in @admin

    get admin_course_grade_release_dates_path

    assert_response :success
    assert_includes response.body, "Course Grade Release Dates"
    assert_includes response.body, @semester.name
  end

  test "admin can set and clear a release date" do
    sign_in @admin
    release_at = 3.days.from_now.change(sec: 0)

    post admin_course_grade_release_dates_path, params: {
      course_grade_release_date: {
        program_semester_id: @semester.id,
        release_date: release_at.strftime("%Y-%m-%dT%H:%M")
      }
    }

    assert_redirected_to admin_course_grade_release_dates_path
    release = @semester.reload.course_grade_release_date
    assert_in_delta release_at.to_i, release.release_date.to_i, 60

    delete admin_course_grade_release_date_path(release)

    assert_redirected_to admin_course_grade_release_dates_path
    assert_nil @semester.reload.course_grade_release_date
  end

  test "clearing an embargoed release date enqueues course result notifications" do
    sign_in @admin
    release = @semester.course_grade_release_date || @semester.build_course_grade_release_date
    release.update!(release_date: 2.days.from_now)

    assert_enqueued_with(job: CourseCompetencyReleaseNotificationJob, args: [ { program_semester_id: @semester.id, triggered_by_id: @admin.id } ]) do
      delete admin_course_grade_release_date_path(release)
    end

    assert_redirected_to admin_course_grade_release_dates_path
  end

  test "bulk update from future embargo to visible enqueues course result notifications" do
    sign_in @admin
    release = @semester.course_grade_release_date || @semester.build_course_grade_release_date
    release.update!(release_date: 2.days.from_now)

    assert_enqueued_with(job: CourseCompetencyReleaseNotificationJob, args: [ { program_semester_id: @semester.id, triggered_by_id: @admin.id } ]) do
      patch bulk_update_admin_course_grade_release_dates_path, params: {
        release_dates: {
          @semester.id => ""
        }
      }
    end

    assert_redirected_to admin_course_grade_release_dates_path
  end

  test "admin can bulk update release dates and audit changes" do
    sign_in @admin
    release_at = 4.days.from_now.change(sec: 0)

    assert_difference -> { AdminActivityLog.where(action: "course_release_date_update").count }, 1 do
      patch bulk_update_admin_course_grade_release_dates_path, params: {
        release_dates: {
          @semester.id => release_at.strftime("%Y-%m-%dT%H:%M")
        }
      }
    end

    assert_redirected_to admin_course_grade_release_dates_path
    release = @semester.reload.course_grade_release_date
    assert_in_delta release_at.to_i, release.release_date.to_i, 60

    activity = AdminActivityLog.where(action: "course_release_date_update").order(created_at: :desc).first
    assert_equal @admin, activity.admin
    assert_equal @semester.name, activity.metadata["semester_name"]
    assert_equal "bulk", activity.metadata["source"]
  end

  test "release date page shows audit trail" do
    sign_in @admin
    AdminActivityLog.record!(
      admin: @admin,
      action: "course_release_date_update",
      description: "Updated course result release date for #{@semester.name}: visible immediately to tomorrow.",
      metadata: { semester_name: @semester.name }
    )

    get admin_course_grade_release_dates_path

    assert_response :success
    assert_includes response.body, "Release-date audit trail"
    assert_includes response.body, @semester.name
  end

  test "advisor cannot manage course grade release dates" do
    sign_in @advisor

    get admin_course_grade_release_dates_path

    assert_redirected_to dashboard_path
  end
end
