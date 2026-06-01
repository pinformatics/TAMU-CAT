require "test_helper"

class ProfileCompletionGuardTest < ActionDispatch::IntegrationTest
  test "incomplete student profile redirects to profile editor when not in test-mode guard" do
    student_user = users(:student)
    student = student_user.student_profile

    original_major = student.major
    student.update!(major: nil)

    env = Rails.env
    original_method = env.method(:test?)

    begin
      env.define_singleton_method(:test?) { false }

      sign_in student_user
      get surveys_path

      assert_redirected_to edit_account_path
      assert_match "Please complete your profile", flash[:alert]
    ensure
      env.define_singleton_method(:test?, &original_method)
      student.update!(major: original_major)
    end
  end
end
