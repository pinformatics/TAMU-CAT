require "test_helper"

class Admin::CourseGradeReleaseDatesControllerPrivateTest < ActionController::TestCase
  tests Admin::CourseGradeReleaseDatesController

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in users(:admin)
    @semester = program_semesters(:fall_2025)
  end

  test "bulk release date params ignore non-parameter payloads" do
    @controller.params = ActionController::Parameters.new(release_dates: "bad payload")

    assert_equal({}, @controller.send(:bulk_release_date_params))
  end

  test "release date equality handles blank and present combinations" do
    now = Time.zone.local(2026, 1, 1, 12, 0, 0)

    assert @controller.send(:release_dates_equal?, nil, nil)
    refute @controller.send(:release_dates_equal?, nil, now)
    refute @controller.send(:release_dates_equal?, now, nil)
    assert @controller.send(:release_dates_equal?, now, now + 0.4.seconds)
    refute @controller.send(:release_dates_equal?, now, now + 2.seconds)
  end

  test "release audit is skipped when dates did not change" do
    release_at = 2.days.from_now

    assert_no_difference -> { AdminActivityLog.where(action: "course_release_date_update").count } do
      @controller.send(
        :record_release_date_audit!,
        semester: @semester,
        release_date: @semester.build_course_grade_release_date(release_date: release_at),
        previous_release_date: release_at,
        new_release_date: release_at,
        source: "single"
      )
    end
  end

  test "release notification transition only fires when an embargo becomes visible" do
    past = 1.day.ago
    future = 1.day.from_now

    assert @controller.send(:transitioned_to_released?, future, nil)
    assert @controller.send(:transitioned_to_released?, future, past)
    refute @controller.send(:transitioned_to_released?, nil, past)
    refute @controller.send(:transitioned_to_released?, future, 2.days.from_now)
  end
end
