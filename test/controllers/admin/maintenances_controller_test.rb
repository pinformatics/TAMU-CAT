require "test_helper"

class Admin::MaintenancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @student = users(:student)
  end

  test "non-admin is redirected" do
    sign_in @student
    get admin_maintenance_path
    assert_redirected_to dashboard_path
  end

  test "admin can view maintenance status" do
    sign_in @admin
    get admin_maintenance_path
    assert_response :success
    assert_includes response.body, "Data Health"
  end

  test "admin can enable and disable maintenance" do
    sign_in @admin

    patch admin_maintenance_path, params: { enabled: "true" }
    assert_redirected_to admin_maintenance_path
    assert_equal true, SiteSetting.maintenance_enabled?

    patch admin_maintenance_path, params: { enabled: "false" }
    assert_redirected_to admin_maintenance_path
    assert_equal false, SiteSetting.maintenance_enabled?
  ensure
    SiteSetting.set_maintenance_enabled!(false)
  end

  test "admin can normalize legacy target levels" do
    sign_in @admin
    CompetencyTargetLevel.create!(
      program_semester: program_semesters(:fall_2025),
      track: "Residential",
      program_year: 2,
      class_of: nil,
      competency_title: Reports::DataAggregator::COMPETENCY_TITLES.first,
      target_level: 4
    )

    assert_difference -> { AdminActivityLog.where(description: "Normalized legacy competency target levels.").count }, 1 do
      post normalize_target_levels_admin_maintenance_path
    end

    assert_redirected_to admin_maintenance_path
    assert_match(/Target levels normalized: 1 created, 1 legacy rows removed, 0 skipped/, flash[:notice].to_s)
    assert CompetencyTargetLevel.exists?(
      program_semester: program_semesters(:fall_2025),
      track: "Residential",
      class_of: 2026,
      program_year: nil,
      competency_title: Reports::DataAggregator::COMPETENCY_TITLES.first,
      target_level: 4
    )
  end
end
