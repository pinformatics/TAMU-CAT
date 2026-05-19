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
end
