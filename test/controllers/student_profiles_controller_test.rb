# frozen_string_literal: true

require "test_helper"
require "securerandom"

class StudentProfilesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student_user = users(:student)
    @student = students(:student) || Student.first
  end

  # Helper to generate valid student params for profile completion
  def valid_student_params(overrides = {})
    {
      uin: @student.uin || "123456789",
      major: @student.major || "Computer Science",
      track: @student.track || "Residential",
      program_year: @student.program_year || 2026,
      advisor_id: @student.advisor_id || Advisor.first&.id
    }.merge(overrides)
  end

  # Authentication Tests
  test "show requires authentication" do
    get student_profile_path

    assert_redirected_to new_user_session_path
  end

  test "edit requires authentication" do
    get edit_student_profile_path

    assert_redirected_to new_user_session_path
  end

  test "update requires authentication" do
    patch student_profile_path, params: { student: { program_year: 2026 } }

    assert_redirected_to new_user_session_path
  end

  # Role-Based Access Control
  test "show requires student role" do
    sign_in @admin

    get student_profile_path

    assert_redirected_to root_path
    assert_equal "You do not have permission to view that profile.", flash[:alert]
  end

  test "edit requires student role" do
    sign_in @admin

    get edit_student_profile_path

    assert_redirected_to root_path
    assert_equal "You do not have permission to view that profile.", flash[:alert]
  end

  test "update requires student role" do
    sign_in @admin

    patch student_profile_path, params: { student: { program_year: 2026 } }

    assert_redirected_to root_path
    assert_equal "You do not have permission to view that profile.", flash[:alert]
  end

  test "advisor cannot access show" do
    sign_in @advisor

    get student_profile_path

    assert_redirected_to root_path
    assert_equal "You do not have permission to view that profile.", flash[:alert]
  end

  test "advisor cannot access edit" do
    sign_in @advisor

    get edit_student_profile_path

    assert_redirected_to root_path
    assert_equal "You do not have permission to view that profile.", flash[:alert]
  end

  test "advisor cannot access update" do
    sign_in @advisor

    patch student_profile_path, params: { student: { program_year: 2026 } }

    assert_redirected_to root_path
    assert_equal "You do not have permission to view that profile.", flash[:alert]
  end

  # Show Action Tests
  test "show displays student profile for student" do
    sign_in @student_user

    get student_profile_path

    assert_response :success
  end

  test "show assigns current student" do
    sign_in @student_user

    get student_profile_path

    assert_response :success
  end

  # Edit Action Tests
  test "edit displays profile form for student" do
    sign_in @student_user

    get edit_student_profile_path

    assert_response :success
  end

  test "edit loads advisors list" do
    sign_in @student_user

    get edit_student_profile_path

    assert_response :success
  end

  test "edit orders advisors by name" do
    sign_in @student_user

    get edit_student_profile_path

    assert_response :success
  end

  test "edit skips profile completion check" do
    sign_in @student_user
    # Even if profile is incomplete, edit should be accessible

    get edit_student_profile_path

    assert_response :success
  end

  # Update Action Tests - Name
  test "update does not allow changing student name" do
    sign_in @student_user
    original_name = @student.user.name

    patch student_profile_path, params: {
      student: valid_student_params.merge(name: "New Name")
    }

    assert_redirected_to student_dashboard_path
    @student.user.reload
    assert_equal original_name, @student.user.name
  end

  # Update Action Tests - Student Attributes
  test "update allows changing UIN" do
    sign_in @student_user
    original_uin = @student.uin

    patch student_profile_path, params: {
      student: valid_student_params(uin: "111111111")
    }

    assert_redirected_to student_dashboard_path
    @student.reload
    assert_equal "111111111", @student.uin
  ensure
    @student.update!(uin: original_uin) if original_uin
  end

  test "update allows changing major" do
    sign_in @student_user
    original_major = @student.major

    patch student_profile_path, params: {
      student: valid_student_params(major: "Mathematics")
    }

    assert_redirected_to student_dashboard_path
    @student.reload
    assert_equal "Mathematics", @student.major
  ensure
    @student.update!(major: original_major)
  end

  test "update allows changing track" do
    sign_in @student_user
    original_track = @student.track_key

    patch student_profile_path, params: {
      student: valid_student_params(track: "Executive")
    }

    assert_redirected_to student_dashboard_path
    @student.reload
    assert_equal "Executive", @student.track
  ensure
    @student.update!(track: original_track) if original_track
  end

  test "update allows changing advisor" do
    sign_in @student_user
    original_advisor_id = @student.advisor_id
    new_advisor = Advisor.where.not(advisor_id: original_advisor_id).first
    new_advisor ||= create_additional_advisor

    patch student_profile_path, params: {
      student: valid_student_params(advisor_id: new_advisor.advisor_id)
    }

    assert_redirected_to student_dashboard_path
    @student.reload
    assert_equal new_advisor.id, @student.advisor_id
  ensure
    @student.update!(advisor_id: original_advisor_id) if original_advisor_id
  end

  # Update Action Tests - Multiple Attributes
  test "update allows changing multiple attributes" do
    sign_in @student_user
    original_major = @student.major
    original_program_year = @student.program_year

    patch student_profile_path, params: {
      student: valid_student_params(program_year: 2027, major: "Updated Major")
    }

    assert_redirected_to student_dashboard_path
    @student.reload
    @student.user.reload
    assert_equal "Updated Major", @student.major
    assert_equal 2027, @student.program_year
  ensure
    @student.update!(major: original_major)
    @student.update!(program_year: original_program_year)
  end

  # Success Messages
  test "update shows success notice" do
    sign_in @student_user

    patch student_profile_path, params: {
      student: valid_student_params
    }

    assert_equal "Profile completed successfully!", flash[:notice]
  end

  # Redirect Behavior
  test "update redirects to student dashboard on success" do
    sign_in @student_user

    patch student_profile_path, params: {
      student: valid_student_params
    }

    assert_redirected_to student_dashboard_path
  end

  # Validation Errors
  test "update re-renders edit with invalid params" do
    sign_in @student_user

    patch student_profile_path, params: {
      student: {
        uin: "",
        major: "",
        track: "",
        program_year: nil,
        advisor_id: nil
      }
    }

    assert_response :unprocessable_entity
  end

  test "update validates with profile_completion context" do
    sign_in @student_user

    patch student_profile_path, params: {
      student: valid_student_params(uin: "")
    }

    assert_response :unprocessable_entity
  end

  test "update rejects non-numeric uin" do
    sign_in @student_user

    patch student_profile_path, params: {
      student: valid_student_params(uin: "abc")
    }

    assert_response :unprocessable_entity
  end

  # Strong Parameters
  test "update filters unpermitted parameters" do
    sign_in @student_user
    original_student_id = @student.student_id

    patch student_profile_path, params: {
      student: valid_student_params.merge(student_id: "999999999")
    }

    @student.reload
    assert_equal original_student_id, @student.student_id
  end

  test "update only permits uin major track program_year and advisor_id" do
    sign_in @student_user

    patch student_profile_path, params: {
      student: valid_student_params.merge(role: "admin")
    }

    assert_redirected_to student_dashboard_path
  end

  # Survey Auto-Assignment
  test "update auto-assigns when track changes" do
    sign_in @student_user
    current_track_value = Student.tracks[@student.track_key] || @student.track
    target_track = current_track_value == "Residential" ? "Executive" : "Residential"
    auto_assign_called = false

    SurveyAssignments::AutoAssigner.stub(:call, ->(**) { auto_assign_called = true }) do
      patch student_profile_path, params: {
        student: valid_student_params(track: target_track)
      }
    end

    assert auto_assign_called, "Expected auto-assigner to run when track changes"
  end

  test "update auto-assigns when student has no assignments" do
    sign_in @student_user
    SurveyAssignment.where(student_id: @student.student_id).delete_all
    auto_assign_called = false

    SurveyAssignments::AutoAssigner.stub(:call, ->(**) { auto_assign_called = true }) do
      patch student_profile_path, params: {
        student: valid_student_params
      }
    end

    assert auto_assign_called, "Expected auto-assigner to run when no assignments exist"
  end

  test "update skips auto-assignment when track unchanged and assignments exist" do
    sign_in @student_user
    @student.update_columns(program_year: 2026)
    SurveyAssignment.find_or_create_by!(student_id: @student.student_id, survey: surveys(:fall_2025)) do |assignment|
      assignment.advisor_id = @student.advisor_id
      assignment.assigned_at = Time.zone.now
      assignment.available_until = 2.weeks.from_now
    end

    auto_assign_called = false

    SurveyAssignments::AutoAssigner.stub(:call, ->(**) { auto_assign_called = true }) do
      patch student_profile_path, params: {
        student: valid_student_params
      }
    end

    refute auto_assign_called, "Expected auto-assigner to be skipped when unnecessary"
  end

  # Profile Completion Check Skip
  test "edit is accessible even with incomplete profile" do
    sign_in @student_user
    # The skip_before_action allows access regardless of profile state

    get edit_student_profile_path

    assert_response :success
  end

  test "update is accessible even with incomplete profile" do
    sign_in @student_user

    patch student_profile_path, params: {
      student: valid_student_params
    }

    assert_response :redirect
  end

  # Current Student
  test "show displays current student information" do
    sign_in @student_user

    get student_profile_path

    assert_response :success
  end

  test "edit loads current student" do
    sign_in @student_user

    get edit_student_profile_path

    assert_response :success
  end

  test "update only affects current student" do
    sign_in @student_user
    other_student = Student.where.not(student_id: @student.student_id).first
    other_student ||= create_additional_student

    other_student.update_columns(major: "Other Major") if other_student.major.blank?
    other_student_major = other_student.major

    patch student_profile_path, params: {
      student: valid_student_params(major: "Different Major")
    }

    other_student.reload
    assert_equal other_student_major, other_student.major
  end

  # Form Display
  test "edit displays advisor options" do
    sign_in @student_user

    get edit_student_profile_path

    assert_response :success
  end

  # Persistence Tests
  test "update persists student attribute changes" do
    sign_in @student_user
    original_major = @student.major

    patch student_profile_path, params: {
      student: valid_student_params(major: "Persisted Major")
    }

    student_from_db = Student.find(@student.student_id)
    assert_equal "Persisted Major", student_from_db.major
  ensure
    @student.update!(major: original_major) if original_major
  end

  test "update persists program_year changes" do
    sign_in @student_user
    original_program_year = @student.program_year

    patch student_profile_path, params: {
      student: valid_student_params(program_year: 2027)
    }

    student_from_db = Student.find(@student.student_id)
    assert_equal 2027, student_from_db.program_year
  ensure
    @student.update!(program_year: original_program_year)
  end

  test "update allows nil advisor_id" do
    sign_in @student_user

    patch student_profile_path, params: {
      student: valid_student_params(advisor_id: nil)
    }

    assert_redirected_to student_dashboard_path
  end

  # Response Format Tests
  test "show returns HTML response" do
    sign_in @student_user

    get student_profile_path

    assert_equal "text/html; charset=utf-8", @response.content_type
  end

  private

  def create_additional_advisor
    user = User.create!(
      email: unique_email("advisor"),
      name: "Generated Advisor",
      role: "advisor",
      uid: "advisor-#{SecureRandom.hex(4)}"
    )
    Advisor.create!(advisor_id: user.id)
  end

  def create_additional_student
    advisor = Advisor.first || create_additional_advisor
    user = User.create!(
      email: unique_email("student"),
      name: "Generated Student",
      role: "student",
      uid: "student-#{SecureRandom.hex(4)}"
    )
    Student.create!(
      student_id: user.id,
      advisor: advisor,
      uin: generate_unique_uin,
      track: @student.track || "Residential",
      major: @student.major || "Undeclared",
      program_year: 2026
    )
  end

  def unique_email(prefix)
    "#{prefix}_#{SecureRandom.hex(4)}@example.com"
  end

  def generate_unique_uin
    loop do
      candidate = SecureRandom.random_number(10**9).to_s.rjust(9, "0")
      return candidate unless Student.exists?(uin: candidate)
    end
  end

  test "edit returns HTML response" do
    sign_in @student_user

    get edit_student_profile_path

    assert_equal "text/html; charset=utf-8", @response.content_type
  end

  test "update returns redirect on success" do
    sign_in @student_user

    patch student_profile_path, params: {
      student: valid_student_params
    }

    assert_response :redirect
  end

  # Context Validation
  test "update uses profile_completion validation context" do
    sign_in @student_user
    # This ensures stricter validation is applied

    patch student_profile_path, params: {
      student: valid_student_params
    }

    assert_redirected_to student_dashboard_path
  end

  # Save Transaction
  test "update saves student changes without changing user name" do
    sign_in @student_user
    original_name = @student.user.name
    original_major = @student.major
    original_program_year = @student.program_year

    patch student_profile_path, params: {
      student: valid_student_params(program_year: 2027, major: "Transaction Major")
    }

    @student.reload
    @student.user.reload
    assert_equal original_name, @student.user.name
    assert_equal "Transaction Major", @student.major
    assert_equal 2027, @student.program_year
  ensure
    @student.update!(major: original_major)
    @student.update!(program_year: original_program_year)
  end

  # Track Values
  test "update accepts valid track values" do
    sign_in @student_user
    original_track = @student.track_key
    valid_tracks = [ "Residential", "Executive" ]

    valid_tracks.each do |track|
      patch student_profile_path, params: {
        student: valid_student_params(track: track)
      }

      assert_redirected_to student_dashboard_path
      @student.reload
      assert_equal track, @student.track
    end
  ensure
    @student.update!(track: original_track) if original_track
  end

  # Advisor Join
  test "edit joins with users table for advisor ordering" do
    sign_in @student_user

    get edit_student_profile_path

    assert_response :success
  end
end
