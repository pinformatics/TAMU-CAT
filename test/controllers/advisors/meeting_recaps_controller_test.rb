require "test_helper"

class Advisors::MeetingRecapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = students(:student)
    @assigned_advisor_user = users(:advisor)
    @other_advisor_user = users(:other_advisor)
    @student_user = users(:student)
    @admin_user = users(:admin)
    @program_semester = program_semesters(:spring_2025)
  end

  test "index lists only the signed-in advisor's advisees" do
    sign_in @assigned_advisor_user

    get advisors_meeting_recaps_path

    assert_response :success
    assert_select "body", /#{@student.user.name}/
    assert_select "body", text: /#{students(:other_student).user.name}/, count: 0
  end

  test "index lists all students for admins" do
    sign_in @admin_user

    get advisors_meeting_recaps_path

    assert_response :success
    assert_select "body", /#{@student.user.name}/
    assert_select "body", /#{students(:other_student).user.name}/
  end

  test "index redirects non-advisor non-admin users" do
    sign_in @student_user

    get advisors_meeting_recaps_path
    assert_redirected_to dashboard_path
  end

  test "assigned advisor can create a meeting recap" do
    sign_in @assigned_advisor_user

    assert_difference -> { AdvisorMeetingRecap.count }, 1 do
      post advisors_student_meeting_recaps_path(@student), params: {
        advisor_meeting_recap: {
          program_semester_id: @program_semester.id,
          meeting_type: "midpoint",
          academic_advising_notes: "Discussed curriculum progress."
        }
      }
    end

    assert_redirected_to advisors_student_path(@student)
    recap = AdvisorMeetingRecap.find_by(student_id: @student.student_id, program_semester_id: @program_semester.id, meeting_type: "midpoint")
    assert recap
    assert_equal @student.advisor_id, recap.advisor_id
  end

  test "assigned advisor can edit an existing meeting recap" do
    sign_in @assigned_advisor_user
    recap = advisor_meeting_recaps(:student_initial_fall_2025)

    patch advisors_student_meeting_recap_path(@student, recap), params: {
      advisor_meeting_recap: { academic_advising_notes: "Updated notes." }
    }

    assert_redirected_to advisors_student_path(@student)
    assert_equal "Updated notes.", recap.reload.academic_advising_notes
  end

  test "new redirects with an alert when semester or meeting type is missing" do
    sign_in @assigned_advisor_user

    get new_advisors_student_meeting_recap_path(@student)

    assert_redirected_to advisors_student_path(@student)
    assert_match "Choose a semester and meeting type", flash[:alert]
  end

  test "new renders Carla's advisor recap fields" do
    sign_in @assigned_advisor_user

    get new_advisors_student_meeting_recap_path(
      @student,
      program_semester_id: @program_semester.id,
      meeting_type: "midpoint"
    )

    assert_response :success
    assert_includes response.body, "Provide a recap of your meeting with your student"
    assert_select "label", text: "Academic Advising"
    assert_select "label", text: "Career Advising"
    assert_select "label", text: "General"
    assert_includes response.body, "Competency achievements/areas for focused development"
    assert_includes response.body, "career search skills"
    assert_includes response.body, "Other resource or support needs."
  end

  test "creating a duplicate recap redirects with an alert instead of raising" do
    sign_in @assigned_advisor_user
    existing = advisor_meeting_recaps(:student_initial_fall_2025)

    assert_no_difference -> { AdvisorMeetingRecap.count } do
      post advisors_student_meeting_recaps_path(@student), params: {
        advisor_meeting_recap: {
          program_semester_id: existing.program_semester_id,
          meeting_type: existing.meeting_type,
          general_notes: "Should not save"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "other advisor cannot view or write a meeting recap for a student not assigned to them" do
    sign_in @other_advisor_user

    get new_advisors_student_meeting_recap_path(@student, program_semester_id: @program_semester.id, meeting_type: "midpoint")
    assert_redirected_to advisors_student_path(@student)
    assert_match "not assigned to you", flash[:alert]

    assert_no_difference -> { AdvisorMeetingRecap.count } do
      post advisors_student_meeting_recaps_path(@student), params: {
        advisor_meeting_recap: { program_semester_id: @program_semester.id, meeting_type: "midpoint", general_notes: "Should not save" }
      }
    end
  end

  test "student cannot reach meeting recap routes" do
    sign_in @student_user

    get advisors_student_path(@student)
    assert_redirected_to dashboard_path

    post advisors_student_meeting_recaps_path(@student), params: {
      advisor_meeting_recap: { program_semester_id: @program_semester.id, meeting_type: "midpoint", general_notes: "Should not save" }
    }
    assert_redirected_to dashboard_path
  end

  test "admin can create a meeting recap on behalf of the assigned advisor" do
    sign_in @admin_user

    assert_difference -> { AdvisorMeetingRecap.count }, 1 do
      post advisors_student_meeting_recaps_path(@student), params: {
        advisor_meeting_recap: { program_semester_id: @program_semester.id, meeting_type: "final", general_notes: "Wrap-up meeting." }
      }
    end

    recap = AdvisorMeetingRecap.find_by(student_id: @student.student_id, program_semester_id: @program_semester.id, meeting_type: "final")
    assert_equal @student.advisor_id, recap.advisor_id
  end
end
