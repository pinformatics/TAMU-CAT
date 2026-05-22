require "test_helper"

class Admin::ProgramSetupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    sign_in @admin
  end

  test "shows program setup with back button in brand header" do
    get admin_program_setup_path(tab: "tracks")

    assert_response :success
    assert_select ".c-card.c-card--brand" do
      assert_select "a[href=?]", admin_dashboard_path
    end
  end

  test "target tab uses target-context language and omits noisy commit parameter" do
    semester = program_semesters(:fall_2025)

    get admin_program_setup_path(tab: "targets", program_semester_id: semester.id, track: "Residential", class_of: 2026)

    assert_response :success
    assert_includes response.body, "1. Target context"
    assert_includes response.body, "Load Targets"
    assert_includes response.body, "Class of 2026"
    assert_includes response.body, "2. Program target coverage"
    assert_includes response.body, "3. Edit targets"
    assert_includes response.body, "End-of-program target"
    assert_includes response.body, "Change Context"
    refute_includes response.body, "Apply Filters"
    refute_includes response.body, "All classes"
    refute_includes response.body, 'name="commit"'
  end

  test "target cohort selector uses configured program years even without students" do
    ProgramYear.create!(value: 2028, position: 30, active: true)

    get admin_program_setup_path(tab: "targets")

    assert_response :success
    assert_includes response.body, "Class of 2028"
  end
end
