require "test_helper"

class Admin::TargetLevelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @student = users(:student)
    @semester = program_semesters(:fall_2025)
    @track_value = Student.tracks.values.first
    @competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
  end

  test "admin can view the editor" do
    sign_in @admin

    get admin_target_levels_path(program_semester_id: @semester.id, track: @track_value)
    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: @track_value, class_of: nil)

    follow_redirect!
    assert_response :success
    assert_match "Competency Targets", response.body
    assert_match "Select a semester, track, and cohort", response.body
    assert_no_match(/data-controller=\"confirm-submit\"/, response.body)
  end

  test "redirected editor cohort selector includes configured program years without students" do
    sign_in @admin
    ProgramYear.create!(value: 2028, position: 30, active: true)

    get admin_target_levels_path(program_semester_id: @semester.id, track: @track_value)
    follow_redirect!

    assert_response :success
    assert_includes response.body, "Class of 2028"
  end

  test "non-admin is redirected" do
    sign_in @student

    get admin_target_levels_path(program_semester_id: @semester.id, track: @track_value)
    assert_redirected_to dashboard_path
  end

  test "admin can update a target level" do
    sign_in @admin

    assert_difference "CompetencyTargetLevel.count", 1 do
      patch admin_target_levels_path, params: {
        program_semester_id: @semester.id,
        track: @track_value,
        class_of: "2026",
        targets: {
          "0" => {
            competency_title: @competency_title,
            target_level: "4"
          }
        }
      }
    end

    record = CompetencyTargetLevel.last
    assert_equal @semester.id, record.program_semester_id
    assert_equal @track_value, record.track
    assert_equal 2026, record.class_of
    assert_equal @competency_title, record.competency_title
    assert_equal 4, record.target_level
  end

  test "update redirects with alert when semester track or cohort not selected" do
    sign_in @admin

    patch admin_target_levels_path, params: {
      program_semester_id: @semester.id,
      track: @track_value,
      class_of: "",
      targets: {
        "0" => { competency_title: @competency_title, target_level: "4" }
      }
    }

    assert_redirected_to admin_program_setup_path(tab: "targets")
    follow_redirect!
    assert_match(/select a semester, track, and cohort/i, flash[:alert].to_s)
  end

  test "blank target level deletes existing record" do
    sign_in @admin

    existing = CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @track_value,
      class_of: 2026,
      competency_title: @competency_title,
      target_level: 3
    )

    assert_difference "CompetencyTargetLevel.count", -1 do
      patch admin_target_levels_path, params: {
        program_semester_id: @semester.id,
        track: @track_value,
        class_of: "2026",
        targets: {
          "0" => { competency_title: @competency_title, target_level: "" }
        }
      }
    end

    refute CompetencyTargetLevel.exists?(existing.id)
  end

  test "invalid target level renders unprocessable entity" do
    sign_in @admin

    patch admin_target_levels_path, params: {
      program_semester_id: @semester.id,
      track: @track_value,
      class_of: "2026",
      targets: {
        "0" => { competency_title: @competency_title, target_level: "0" }
      }
    }

    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: @track_value, class_of: 2026)
    follow_redirect!
    assert_match(/must be greater than or equal to 1/i, flash[:alert].to_s)
  end

  test "warns when updating target levels after students submitted surveys" do
    sign_in @admin

    survey_assignments(:completed_residential_assignment)

    assert_difference -> { Notification.where(title: "Target Levels Changed After Submissions").count }, User.admins.count do
      assert_enqueued_jobs User.admins.count, only: NotificationEmailDeliveryJob do
        patch admin_target_levels_path, params: {
          program_semester_id: @semester.id,
          track: "Residential",
          class_of: "2026",
          targets: {
            "0" => {
              competency_title: @competency_title,
              target_level: "4"
            }
          }
        }
      end
    end

    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: "Residential", class_of: 2026)

    follow_redirect!
    assert_response :success
    assert_match(/Warning:/i, response.body)
    assert_match(/Target levels changed/i, response.body)
    assert_match(/after 1 student/i, Notification.where(title: "Target Levels Changed After Submissions").last.message)
  end

  test "does not warn when updating target levels and no one has submitted" do
    sign_in @admin

    patch admin_target_levels_path, params: {
      program_semester_id: @semester.id,
      track: "Executive",
      class_of: "2026",
      targets: {
        "0" => {
          competency_title: @competency_title,
          target_level: "4"
        }
      }
    }

    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: "Executive", class_of: 2026)

    follow_redirect!
    assert_response :success
    assert_no_match(/Target levels changed/i, response.body)
  end

  test "admin can fill missing target levels from defaults" do
    sign_in @admin

    assert_difference -> { CompetencyTargetLevel.where(program_semester: @semester, track: "Residential", class_of: 2026, program_year: nil).count }, 17 do
      post admin_fill_default_target_levels_path, params: {
        program_semester_id: @semester.id,
        track: "Residential",
        class_of: "2026"
      }
    end

    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: "Residential", class_of: 2026)
    assert_match(/Default target levels filled: 17 added, 0 already set/, flash[:notice].to_s)
  end

  test "fill defaults requires selected cohort context" do
    sign_in @admin

    post admin_fill_default_target_levels_path, params: {
      program_semester_id: @semester.id,
      track: "Residential",
      class_of: ""
    }

    assert_redirected_to admin_program_setup_path(tab: "targets")
    assert_match(/Select a semester, track, and cohort/i, flash[:alert].to_s)
  end

  test "admin can copy selected target levels to current semester" do
    sign_in @admin
    source_semester = program_semesters(:spring_2026)
    current_semester = ProgramSemester.current

    CompetencyTargetLevel.create!(
      program_semester: source_semester,
      track: @track_value,
      class_of: 2026,
      competency_title: @competency_title,
      target_level: 5
    )

    assert_difference -> { CompetencyTargetLevel.where(program_semester: current_semester, track: @track_value, class_of: 2026).count }, 1 do
      post admin_copy_target_levels_to_current_path, params: {
        program_semester_id: source_semester.id,
        track: @track_value,
        class_of: "2026"
      }
    end

    copied = CompetencyTargetLevel.find_by!(
      program_semester: current_semester,
      track: @track_value,
      class_of: 2026,
      competency_title: @competency_title
    )

    assert_equal 5, copied.target_level
    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: current_semester.id, track: @track_value, class_of: 2026)
    assert_match(/Copied 1 target level to #{Regexp.escape(current_semester.name)}/, flash[:notice].to_s)
  end

  test "copy to current updates existing target levels" do
    sign_in @admin
    source_semester = program_semesters(:spring_2026)
    current_semester = ProgramSemester.current

    CompetencyTargetLevel.create!(
      program_semester: source_semester,
      track: @track_value,
      class_of: 2026,
      competency_title: @competency_title,
      target_level: 5
    )
    current_record = CompetencyTargetLevel.create!(
      program_semester: current_semester,
      track: @track_value,
      class_of: 2026,
      competency_title: @competency_title,
      target_level: 2
    )

    assert_no_difference "CompetencyTargetLevel.count" do
      post admin_copy_target_levels_to_current_path, params: {
        program_semester_id: source_semester.id,
        track: @track_value,
        class_of: "2026"
      }
    end

    assert_equal 5, current_record.reload.target_level
    assert_match(/Copied 1 target level/, flash[:notice].to_s)
  end

  test "copy to current button appears for non-current target context" do
    sign_in @admin
    source_semester = program_semesters(:spring_2026)

    get admin_target_levels_path(program_semester_id: source_semester.id, track: @track_value, class_of: "2026")
    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: source_semester.id, track: @track_value, class_of: "2026")

    follow_redirect!
    assert_response :success
    assert_includes response.body, "Copy to Current Semester"
  end

  test "editor renders previously saved target levels" do
    sign_in @admin

    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @track_value,
      class_of: 2026,
      competency_title: @competency_title,
      target_level: 5
    )

    get admin_target_levels_path(program_semester_id: @semester.id, track: @track_value, class_of: "2026")
    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: @track_value, class_of: "2026")

    follow_redirect!
    assert_response :success
    assert_match @competency_title, response.body
    assert_match(/<option[^>]*value="5"[^>]*selected="selected"[^>]*>[^<]*5[^<]*<\/option>|<option[^>]*selected="selected"[^>]*value="5"[^>]*>[^<]*5[^<]*<\/option>/, response.body)
  end

  test "editor preloads existing legacy cohort-year target levels for selected cohort" do
    sign_in @admin

    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @track_value,
      program_year: 2026,
      class_of: nil,
      competency_title: @competency_title,
      target_level: 4
    )

    get admin_target_levels_path(program_semester_id: @semester.id, track: @track_value, class_of: "2026")
    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: @track_value, class_of: "2026")

    follow_redirect!
    assert_response :success
    assert_match @competency_title, response.body
    assert_match(/<option[^>]*value="4"[^>]*selected="selected"[^>]*>[^<]*4[^<]*<\/option>|<option[^>]*selected="selected"[^>]*value="4"[^>]*>[^<]*4[^<]*<\/option>/, response.body)
    assert_includes response.body, "prefilled from existing cohort target records"
  end

  test "editor preloads old first and second year target levels for selected cohort" do
    sign_in @admin

    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @track_value,
      program_year: 2,
      class_of: nil,
      competency_title: @competency_title,
      target_level: 3
    )

    get admin_target_levels_path(program_semester_id: @semester.id, track: @track_value, class_of: "2026")
    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: @track_value, class_of: "2026")

    follow_redirect!
    assert_response :success
    assert_match @competency_title, response.body
    assert_match(/<option[^>]*value="3"[^>]*selected="selected"[^>]*>[^<]*3[^<]*<\/option>|<option[^>]*selected="selected"[^>]*value="3"[^>]*>[^<]*3[^<]*<\/option>/, response.body)
  end

  test "editor preloads accidentally seeded old class_of target levels for selected cohort" do
    sign_in @admin

    CompetencyTargetLevel.insert_all!(
      [
        {
          program_semester_id: @semester.id,
          track: @track_value,
          program_year: nil,
          class_of: 2,
          competency_title: @competency_title,
          target_level: 2,
          created_at: Time.current,
          updated_at: Time.current
        }
      ]
    )

    get admin_target_levels_path(program_semester_id: @semester.id, track: @track_value, class_of: "2026")
    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: @track_value, class_of: "2026")

    follow_redirect!
    assert_response :success
    assert_match @competency_title, response.body
    assert_match(/<option[^>]*value="2"[^>]*selected="selected"[^>]*>[^<]*2[^<]*<\/option>|<option[^>]*selected="selected"[^>]*value="2"[^>]*>[^<]*2[^<]*<\/option>/, response.body)
  end

  test "editor summarizes missing program target coverage" do
    sign_in @admin

    CompetencyTargetLevel.where(
      program_semester: @semester,
      track: @track_value,
      class_of: 2026
    ).delete_all
    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @track_value,
      class_of: 2026,
      competency_title: @competency_title,
      target_level: 5
    )

    get admin_target_levels_path(program_semester_id: @semester.id, track: @track_value, class_of: "2026")
    assert_redirected_to admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: @track_value, class_of: "2026")

    follow_redirect!
    assert_response :success
    assert_includes response.body, "Program target coverage"
    assert_includes response.body, "1 of 17 end-of-program targets set"
    assert_includes response.body, "16 missing"
    assert_includes response.body, "Uploaded faculty CSV course targets are reviewed separately"
  end
end
