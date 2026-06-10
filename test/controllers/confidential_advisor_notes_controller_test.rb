require "test_helper"

class ConfidentialAdvisorNotesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = students(:student)
    @survey = surveys(:fall_2025)
    @survey_response = SurveyResponse.build(student: @student, survey: @survey)

    @assigned_advisor_user = users(:advisor)
    @other_advisor_user = users(:other_advisor)
    @student_user = users(:student)
    @admin_user = users(:admin)
  end

  test "assigned advisor can create/update a confidential note" do
    sign_in @assigned_advisor_user

    assert_difference "ConfidentialAdvisorNote.count", 1 do
      patch confidential_advisor_note_survey_response_path(@survey_response),
            params: { confidential_advisor_note: { body: "Keep an eye on internship progress." } }
    end

    assert_redirected_to survey_response_path(@survey_response)

    note = ConfidentialAdvisorNote.find_by(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id
    )
    assert note
    assert_equal "Keep an eye on internship progress.", note.body
  end

  test "other advisor cannot write a confidential note" do
    sign_in @other_advisor_user

    assert_no_difference "ConfidentialAdvisorNote.count" do
      patch confidential_advisor_note_survey_response_path(@survey_response),
            params: { confidential_advisor_note: { body: "Should not save" } }
    end

    assert_response :unauthorized
  end

  test "student cannot write a confidential note" do
    sign_in @student_user

    assert_no_difference "ConfidentialAdvisorNote.count" do
      patch confidential_advisor_note_survey_response_path(@survey_response),
            params: { confidential_advisor_note: { body: "Should not save" } }
    end

    assert_response :unauthorized
  end

  test "admin can write a confidential note for the assigned advisor" do
    sign_in @admin_user

    assert_difference "ConfidentialAdvisorNote.count", 1 do
      patch confidential_advisor_note_survey_response_path(@survey_response),
            params: { confidential_advisor_note: { body: "Should not save" } }
    end

    assert_redirected_to survey_response_path(@survey_response)

    note = ConfidentialAdvisorNote.find_by(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id
    )
    assert note
    assert_equal "Should not save", note.body
  end

  test "assigned advisor can clear a confidential note" do
    ConfidentialAdvisorNote.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      body: "Existing"
    )

    sign_in @assigned_advisor_user

    assert_difference "ConfidentialAdvisorNote.count", -1 do
      patch confidential_advisor_note_survey_response_path(@survey_response),
            params: {
              survey_id: @survey.id,
              student_id: @student.student_id,
              confidential_advisor_note: { body: "" }
            }
    end

    assert_redirected_to new_feedback_path(survey_id: @survey.id, student_id: @student.student_id)
    assert_match(/cleared/i, flash[:notice].to_s)
  end

  test "blank confidential note without an existing note does not create a record" do
    sign_in @assigned_advisor_user

    assert_no_difference "ConfidentialAdvisorNote.count" do
      patch confidential_advisor_note_survey_response_path(@survey_response),
            params: {
              return_to: student_records_path,
              confidential_advisor_note: { body: "   " }
            }
    end

    assert_redirected_to student_records_path
    assert_match(/cleared/i, flash[:notice].to_s)
  end

  test "unsafe return path falls back to the survey response" do
    sign_in @assigned_advisor_user

    patch confidential_advisor_note_survey_response_path(@survey_response),
          params: {
            return_to: "//example.com/escape",
            confidential_advisor_note: { body: "Still local" }
          }

    assert_redirected_to survey_response_path(@survey_response)
  end

  test "admin cannot save confidential note when advisor is missing" do
    orphan_user = User.create!(email: "orphan_student_#{SecureRandom.hex(4)}@example.com", name: "Orphan", role: "student", uid: "uid-#{SecureRandom.hex(4)}")
    orphan_student = orphan_user.student_profile
    orphan_student.update!(advisor: nil, uin: "222333444", track: "Residential", program_year: 2026)
    survey_response = SurveyResponse.build(student: orphan_student, survey: @survey)

    sign_in @admin_user
    patch confidential_advisor_note_survey_response_path(survey_response),
          params: { confidential_advisor_note: { body: "note" } }

    assert_redirected_to survey_response_path(survey_response)
    assert_match(/could not save the confidential note/i, flash[:alert].to_s)
  ensure
    orphan_user&.destroy
  end

  test "confidential note section is only shown to assigned advisor" do
    previous_survey = surveys(:spring_2025)

    ConfidentialAdvisorNote.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      body: "Private note"
    )

    ConfidentialAdvisorNote.create!(
      student_id: @student.student_id,
      survey_id: previous_survey.id,
      advisor_id: @student.advisor_id,
      body: "Older note"
    )

    sign_in @student_user
    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }
    assert_redirected_to dashboard_path
    assert_equal ApplicationController::STAFF_ONLY_MESSAGE, flash[:alert]

    get survey_response_path(@survey_response)
    assert_response :success
    refute_includes response.body, "Confidential advisor notes"

    sign_in @admin_user
    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }
    assert_response :success
    assert_includes response.body, "Confidential advisor notes"
    assert_includes response.body, "Private note"
    assert_includes response.body, "confidential_advisor_note_body"
    assert_includes response.body, "Older note"
    assert_includes response.body, "Note (read-only)"

    get survey_response_path(@survey_response)
    assert_response :success
    refute_includes response.body, "Confidential advisor notes"

    sign_in @assigned_advisor_user
    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }
    assert_response :success
    assert_includes response.body, "Confidential advisor notes"
    assert_includes response.body, "Private note"
    assert_includes response.body, "confidential_advisor_note_body"
    assert_includes response.body, "Older note"
    assert_includes response.body, "Note (read-only)"

    sign_in @other_advisor_user
    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }
    assert_redirected_to survey_records_path
    assert_match "not assigned", flash[:alert]

    sign_in @assigned_advisor_user
    get survey_response_path(@survey_response)
    assert_response :success
    assert_includes response.body, "Confidential advisor notes"
    assert_includes response.body, "Private note"
    assert_includes response.body, "Visible only to the assigned advisor"
    assert_select "form[action=?]", confidential_advisor_note_survey_response_path(@survey_response)
    assert_select "textarea#confidential_advisor_note_body"
  end
end
