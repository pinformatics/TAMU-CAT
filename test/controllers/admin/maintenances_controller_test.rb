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
end
