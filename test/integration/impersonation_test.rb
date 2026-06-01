require "test_helper"

class ImpersonationTest < ActionDispatch::IntegrationTest
  test "admin can open view-as-student page" do
    sign_in users(:admin)

    get new_impersonation_path
    assert_response :success
    assert_match "View as", response.body
    assert_match "Student", response.body
    assert_match "Advisor", response.body
  end

  test "admin can impersonate a student and then exit" do
    sign_in users(:admin)

    post impersonation_path, params: { impersonation: { user_id: users(:student).id } }
    assert_redirected_to student_dashboard_path

    follow_redirect!
    assert_response :success
    assert_match "Viewing as", response.body
    assert_match "Exit view", response.body

    delete impersonation_path
    assert_redirected_to admin_dashboard_path
  end

  test "writes are blocked while impersonating" do
    sign_in users(:admin)

    post impersonation_path, params: { impersonation: { user_id: users(:student).id } }
    assert_redirected_to student_dashboard_path

    # Attempt a write that would normally be allowed for a student.
    patch account_path, params: {
      student: {
        uin: "123456789",
        major: "Test Major",
        track: "Residential"
      }
    }

    assert_redirected_to student_dashboard_path
    follow_redirect!
    assert_match "Read-only while impersonating", response.body
  end
end
