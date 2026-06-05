require "test_helper"
require "tempfile"

class SurveyResponsesControllerPrivateTest < ActionController::TestCase
  tests SurveyResponsesController

  setup do
    @survey = surveys(:fall_2025)
    @student = students(:student)
    @survey_response = SurveyResponse.build(student: @student, survey: @survey)
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in users(:admin)
    @controller.instance_variable_set(:@survey_response, @survey_response)
  end

  test "safe return and filename helpers normalize allowed blank and unsafe values" do
    set_controller_params(return_to: "/survey_records")
    assert_equal "/survey_records", @controller.send(:safe_return_to_param)

    set_controller_params(return_to: "")
    assert_nil @controller.send(:safe_return_to_param)

    set_controller_params(return_to: "https://example.com")
    assert_nil @controller.send(:safe_return_to_param)

    set_controller_params(return_to: "//example.com")
    assert_nil @controller.send(:safe_return_to_param)

    assert_equal "student_user_fall_2025_health_assessment.pdf", @controller.send(:survey_pdf_filename, @survey_response)
    assert_equal "fallback_name", @controller.send(:safe_filename_part, " !!! ", fallback: "Fallback Name")
    assert_equal "named_file", @controller.send(:safe_filename_part, "Named File")
  end

  test "edit normalizes stored hash answers for choice generic hash and plain answers" do
    category = categories(:clinical_skills)
    choice = category.questions.create!(
      question_text: "Choice with other",
      question_type: "dropdown",
      question_order: 50,
      answer_options: [ { label: "Other", value: "Other", requires_text: true } ].to_json
    )
    generic = category.questions.create!(question_text: "Generic stored hash", question_type: "short_answer", question_order: 51)
    plain = category.questions.create!(question_text: "Plain answer", question_type: "short_answer", question_order: 52)
    StudentQuestion.create!(student: @student, question: choice, answer: { answer: "Other", text: "Flexible" })
    StudentQuestion.create!(student: @student, question: generic, answer: { text: "Generic text" })
    StudentQuestion.create!(student: @student, question: plain, answer: "Plain text")

    get :edit, params: { id: @survey_response.id, return_to: "/student_records" }

    assert_response :success
    assert_equal "Other", assigns(:existing_answers)[choice.id.to_s]
    assert_equal "Flexible", assigns(:other_answers)[choice.id.to_s]
    assert_equal "Generic text", assigns(:existing_answers)[generic.id.to_s]
    assert_equal "Plain text", assigns(:existing_answers)[plain.id.to_s]
    assert_equal "/student_records", assigns(:return_to)
  end

  test "update saves choice other text removes blank answers and captures changed versions" do
    category = categories(:clinical_skills)
    choice = category.questions.create!(
      question_text: "Admin updated choice",
      question_type: "multiple_choice",
      question_order: 60,
      answer_options: [ { label: "Other", value: "Other", requires_text: true } ].to_json
    )
    blanked = category.questions.create!(question_text: "Admin blanked answer", question_type: "short_answer", question_order: 61)
    StudentQuestion.create!(student: @student, question: blanked, answer: "Remove me")

    assert_difference "SurveyResponseVersion.where(student_id: @student.student_id, survey_id: @survey.id).count", 2 do
      patch :update,
            params: {
              id: @survey_response.id,
              return_to: "/student_records",
              answers: {
                choice.id.to_s => "Other",
                blanked.id.to_s => ""
              },
              other_answers: {
                choice.id.to_s => "Admin note"
              }
            }
    end

    assert_redirected_to survey_response_path(@survey_response.id, return_to: "/student_records")
    assert_equal({ "answer" => "Other", "text" => "Admin note" }, StudentQuestion.find_by!(student: @student, question: choice).answer)
    assert_nil StudentQuestion.find_by(student: @student, question: blanked)
  end

  test "update with unchanged blank payload does not create a new admin edited version" do
    empty_survey = Survey.create!(
      title: "Empty Admin Update Survey",
      program_semester: program_semesters(:fall_2025),
      is_active: true,
      categories_attributes: {
        "0" => {
          name: "Empty category",
          questions_attributes: {
            "0" => {
              question_text: "Empty response question",
              question_type: "short_answer",
              question_order: 1
            }
          }
        }
      }
    )
    empty_response = SurveyResponse.build(student: @student, survey: empty_survey)

    assert_no_difference "SurveyResponseVersion.where(student_id: @student.student_id, survey_id: empty_survey.id).count" do
      patch :update, params: { id: empty_response.id, answers: {}, other_answers: {} }
    end

    assert_redirected_to survey_response_path(empty_response.id)
  end

  test "composite pdf viewer mode follows role and token fallbacks" do
    assert_equal :staff, @controller.send(:composite_pdf_viewer_mode)

    sign_out users(:admin)
    sign_in users(:student)
    assert_equal :student, @controller.send(:composite_pdf_viewer_mode)

    sign_out users(:student)
    sign_in users(:advisor)
    assert_equal :staff, @controller.send(:composite_pdf_viewer_mode)

    sign_out users(:advisor)
    set_controller_params(token: "signed")
    assert_equal :student, @controller.send(:composite_pdf_viewer_mode)

    set_controller_params({})
    assert_equal :staff, @controller.send(:composite_pdf_viewer_mode)
  end

  test "set survey response accepts signed token id and handles missing lookup" do
    token = @survey_response.signed_download_token

    set_controller_params(token: token)
    @controller.send(:set_survey_response)
    assert_equal @survey_response.id, @controller.instance_variable_get(:@survey_response).id

    set_controller_params(id: @survey_response.id)
    @controller.send(:set_survey_response)
    assert_equal @survey_response.id, @controller.instance_variable_get(:@survey_response).id

    set_controller_params(token: "not-a-valid-token")
    @controller.stub(:head, true) do
      @controller.send(:set_survey_response)
    end
  end

  test "view authorization allows token admin advisor and student but rejects others" do
    set_controller_params(token: "present")
    assert_nil @controller.send(:authorize_view!)

    set_controller_params({})
    sign_in users(:admin)
    assert_nil @controller.send(:authorize_view!)

    sign_out users(:admin)
    sign_in @student.user
    assert_nil @controller.send(:authorize_view!)

    sign_out @student.user
    sign_in users(:advisor)
    assert_nil @controller.send(:authorize_view!)

    sign_out users(:advisor)
    sign_in users(:other_student)
    @controller.stub(:head, nil) do
      assert_nil @controller.send(:authorize_view!)
    end
  end

  test "admin and composite authorization cover missing token unauthenticated advisor and admin paths" do
    assert_nil @controller.send(:authorize_admin!)

    sign_out users(:admin)
    sign_in users(:student)
    @controller.stub(:head, nil) do
      assert_nil @controller.send(:authorize_admin!)
    end

    @controller.instance_variable_set(:@survey_response, nil)
    @controller.stub(:head, true) do
      assert_nil @controller.send(:authorize_composite!)
    end

    @controller.instance_variable_set(:@survey_response, @survey_response)
    set_controller_params(token: "present")
    @controller.stub(:head, true) do
      assert_nil @controller.send(:authorize_composite!)
    end

    set_controller_params({})
    sign_out users(:student)
    @controller.stub(:head, true) do
      assert_nil @controller.send(:authorize_composite!)
    end

    sign_in users(:admin)
    assert_nil @controller.send(:authorize_composite!)

    sign_out users(:admin)
    sign_in users(:advisor)
    assert_nil @controller.send(:authorize_composite!)

    sign_out users(:advisor)
    sign_in users(:other_student)
    @controller.stub(:head, true) do
      assert_nil @controller.send(:authorize_composite!)
    end
  end

  test "load versions selects latest selected previous and next versions" do
    first = SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      event: "submitted",
      answers: { "1" => "old" },
      created_at: 2.days.ago,
      updated_at: 2.days.ago
    )
    second = SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      event: "revised",
      answers: { "1" => "new" },
      created_at: 1.day.ago,
      updated_at: 1.day.ago
    )

    set_controller_params(version_id: first.id)
    @controller.send(:load_versions!)

    assert_equal first, @controller.instance_variable_get(:@selected_version)
    assert_nil @controller.instance_variable_get(:@previous_version)
    assert_equal second, @controller.instance_variable_get(:@next_version)

    set_controller_params({})
    @controller.instance_variable_set(:@survey_response, @survey_response)
    @controller.send(:load_versions!)
    assert_equal second, @controller.instance_variable_get(:@selected_version)
  end

  test "pdf byte streaming guards missing non pdf and valid pdf payloads" do
    result = Struct.new(:path).new(nil)
    @controller.stub(:render_unavailable, :unavailable) do
      assert_equal :unavailable, @controller.send(:stream_pdf_result, result, "file.pdf", unavailable_message: "No PDF")
    end

    temp = Tempfile.new([ "survey-response", ".pdf" ])
    temp.binmode
    temp.write("not a pdf")
    temp.close

    @controller.stub(:render_unavailable, :unavailable) do
      assert_equal :unavailable, @controller.send(:stream_pdf_result, Struct.new(:path).new(temp.path), "file.pdf", unavailable_message: "No PDF")
    end

    temp.open
    temp.truncate(0)
    temp.write("%PDF-1.4 test")
    temp.close

    sent = nil
    @controller.stub(:send_data, ->(data, **options) { sent = [ data, options ] }) do
      @controller.send(:stream_pdf_result, Struct.new(:path).new(temp.path), "file.pdf")
    end

    assert_equal "%PDF-1.4 test", sent.first
    assert_equal "file.pdf", sent.last[:filename]
  ensure
    temp&.unlink
  end

  test "read pdf and unavailable rendering handle missing files and fallback responses" do
    assert_nil @controller.send(:read_pdf_bytes, "missing-file.pdf")

    @controller.stub(:render, :rendered) do
      assert_equal :rendered, @controller.send(:render_unavailable, "Unavailable")
    end

    @controller.stub(:head, :headed) do
      assert_equal :headed, @controller.send(:render_unavailable, nil)
    end
  end

  test "confidential advisor note loader requires matching assigned advisor" do
    note = ConfidentialAdvisorNote.create!(
      student: @student,
      survey: @survey,
      advisor: advisors(:advisor),
      body: "Private context"
    )

    sign_out users(:admin)
    sign_in users(:student)
    @controller.send(:load_confidential_advisor_note!)
    assert_equal false, @controller.instance_variable_get(:@confidential_advisor_note_enabled)

    sign_out users(:student)
    sign_in users(:other_advisor)
    @controller.send(:load_confidential_advisor_note!)
    assert_equal false, @controller.instance_variable_get(:@confidential_advisor_note_enabled)

    @student.update!(advisor: advisors(:advisor))
    @survey_response = SurveyResponse.build(student: @student, survey: @survey)
    @controller.instance_variable_set(:@survey_response, @survey_response)
    sign_out users(:other_advisor)
    sign_in users(:advisor)

    @controller.stub(:current_advisor_profile, advisors(:advisor)) do
      @controller.send(:load_confidential_advisor_note!)
    end

    assert_equal true, @controller.instance_variable_get(:@confidential_advisor_note_enabled)
    assert_equal note, @controller.instance_variable_get(:@confidential_advisor_note)
  end

  test "self target summary visibility follows assignments versions and legacy completion" do
    @controller.instance_variable_set(:@survey_assignment, nil)
    submitted_version = SurveyResponseVersion.new(event: "submitted")
    @controller.instance_variable_set(:@selected_version, submitted_version)
    assert @controller.send(:completed_survey_response?)

    @controller.instance_variable_set(:@selected_version, SurveyResponseVersion.new(event: "autosaved"))
    @controller.stub(:legacy_completed_survey_response?, true) do
      assert @controller.send(:completed_survey_response?)
    end

    @controller.instance_variable_set(:@selected_version, nil)
    assignment = Struct.new(:completed_at, :effective_available_until).new(Time.current, nil)
    @controller.instance_variable_set(:@survey_assignment, assignment)
    assert @controller.send(:completed_survey_response?)

    @controller.instance_variable_set(:@survey_assignment, nil)
    @controller.instance_variable_set(:@selected_version, nil)
    @controller.stub(:legacy_completed_survey_response?, false) do
      refute @controller.send(:completed_survey_response?)
    end
  end

  test "legacy completed survey response handles assignment and survey availability states" do
    @controller.instance_variable_set(:@survey_assignment, nil)
    assert_equal(@survey_response.status == :submitted, @controller.send(:legacy_completed_survey_response?))

    submitted_response = Struct.new(:status, :survey).new(:submitted, Struct.new(:is_active?).new(false))
    @controller.instance_variable_set(:@survey_response, submitted_response)
    @controller.instance_variable_set(:@survey_assignment, Struct.new(:effective_available_until).new(nil))
    assert @controller.send(:legacy_completed_survey_response?)

    active_survey = Struct.new(:is_active?).new(true)
    past_assignment = Struct.new(:effective_available_until).new(1.day.ago)
    future_assignment = Struct.new(:effective_available_until).new(1.day.from_now)
    @controller.instance_variable_set(:@survey_response, Struct.new(:status, :survey).new(:submitted, active_survey))

    @controller.instance_variable_set(:@survey_assignment, past_assignment)
    assert @controller.send(:legacy_completed_survey_response?)

    @controller.instance_variable_set(:@survey_assignment, future_assignment)
    refute @controller.send(:legacy_completed_survey_response?)

    @controller.instance_variable_set(:@survey_response, Struct.new(:status, :survey).new(:in_progress, active_survey))
    refute @controller.send(:legacy_completed_survey_response?)
  end

  test "export audit and filename helpers tolerate nil survey response pieces" do
    assert_difference -> { AdminActivityLog.where(action: "student_data_export").count }, 1 do
      @controller.send(
        :record_survey_response_export_audit!,
        export_type: "coverage_pdf",
        description: "Coverage export",
        survey_response: nil
      )
    end

    filename = @controller.send(:survey_pdf_filename, Struct.new(:student, :student_id, :survey, :survey_id).new(nil, 42, nil, 99))
    assert_equal "student_42_survey_99.pdf", filename
  end

  private

  def set_controller_params(params_hash)
    @controller.instance_variable_set(:@_params, ActionController::Parameters.new(params_hash))
  end
end
