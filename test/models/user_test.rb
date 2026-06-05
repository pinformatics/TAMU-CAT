require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "sessions time out after thirty minutes of inactivity" do
    user = users(:student)

    assert_includes User.devise_modules, :timeoutable
    assert_equal 30.minutes, user.timeout_in
    refute user.timedout?(29.minutes.ago)
    assert user.timedout?(31.minutes.ago)
  end

  test "normalizes role hints and rejects unknown roles" do
    assert_equal "student", User.normalize_role(:student)
    assert_equal "advisor", User.normalize_role("Advisor")
    assert_equal "admin", User.normalize_role("admin")
    assert_nil User.normalize_role("")
    assert_nil User.normalize_role("owner")
  end

  test "from google preserves existing values when optional fields are blank" do
    user = User.create!(
      email: "oauth_existing_#{SecureRandom.hex(4)}@example.com",
      name: "Existing Name",
      uid: "existing-uid",
      avatar_url: "https://example.com/avatar.png",
      role: "advisor"
    )

    updated = User.from_google(
      email: user.email,
      name: "",
      uid: "",
      avatar_url: "",
      role: nil
    )

    assert_equal user.id, updated.id
    assert_equal "Existing Name", updated.name
    assert_equal "existing-uid", updated.uid
    assert_equal "https://example.com/avatar.png", updated.avatar_url
    assert_equal "advisor", updated.role
    assert updated.advisor_profile
  ensure
    user&.destroy
  end

  test "role profile and student reconciliation guards cover each role" do
    admin = User.create!(email: "role_admin_#{SecureRandom.hex(4)}@example.com", name: "Role Admin", role: "admin", uid: "role-admin-#{SecureRandom.hex(4)}")
    advisor = User.create!(email: "role_advisor_#{SecureRandom.hex(4)}@example.com", name: "Role Advisor", role: "advisor", uid: "role-advisor-#{SecureRandom.hex(4)}")
    student = User.create!(email: "role_student_#{SecureRandom.hex(4)}@example.com", name: "Role Student", role: "student", uid: "role-student-#{SecureRandom.hex(4)}")

    assert admin.admin_profile
    assert advisor.advisor_profile
    assert student.student_profile

    student.student_profile.destroy!
    assert_nothing_raised { student.send(:reconcile_pending_grade_import_rows_for_student) }
  ensure
    [ admin, advisor, student ].compact.each(&:destroy)
  end
end
