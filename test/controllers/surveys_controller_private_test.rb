require "test_helper"

class SurveysControllerPrivateTest < ActionController::TestCase
  tests SurveysController

  FakeAssignment = Struct.new(
    :completed_at_value,
    :can_edit_now_value,
    :availability_status_value,
    :available_from,
    :available_until,
    keyword_init: true
  ) do
    def completed_at? = completed_at_value
    def can_edit_now? = can_edit_now_value
    def availability_status = availability_status_value
  end

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
    @controller.instance_variable_set(:@survey, surveys(:fall_2025))
  end

  test "save progress autosave returns json when no student profile is attached" do
    sign_in users(:admin)

    post :save_progress, params: { id: surveys(:fall_2025).id, autosave: "1" }, as: :json

    assert_response :unprocessable_entity
    payload = JSON.parse(response.body)
    assert_equal false, payload["saved"]
    assert_match "student record", payload["message"]
  end

  test "submit and manual save redirect when no student profile is attached" do
    sign_in users(:admin)
    survey = surveys(:fall_2025)

    post :submit, params: { id: survey.id, answers: {} }
    assert_redirected_to student_dashboard_path
    assert_match "student record", flash[:alert]

    post :save_progress, params: { id: survey.id, answers: {} }
    assert_redirected_to student_dashboard_path
    assert_match "student record", flash[:alert]
  end

  test "save progress autosave rejects submitted assignments inside the edit window" do
    sign_in users(:completed_student)
    assignment = survey_assignments(:completed_residential_assignment)
    assignment.update!(available_until: 5.days.from_now, completed_at: 1.day.ago)

    post :save_progress, params: { id: surveys(:fall_2025).id, autosave: "1" }, as: :json

    assert_response :unprocessable_entity
    payload = JSON.parse(response.body)
    assert_equal false, payload["saved"]
    assert_equal "This submitted survey can only be updated with Submit Survey.", payload["message"]
  end

  test "manual save redirects locked submitted assignments to read only response" do
    sign_in users(:completed_student)
    assignment = survey_assignments(:completed_residential_assignment)
    assignment.update!(completed_at: 1.day.ago, available_until: 1.day.ago)

    post :save_progress, params: { id: assignment.survey_id, answers: {} }

    assert_redirected_to survey_response_path(SurveyResponse.build(student: assignment.student, survey: assignment.survey))
    assert_match "already been submitted", flash[:alert]
  end

  test "save progress persists choice other text integer drafts and removes blank answers without leaving page" do
    sign_in users(:student)
    survey = surveys(:fall_2025)
    category = categories(:clinical_skills)
    choice = category.questions.create!(
      question_text: "How flexible are your work hours?",
      question_type: "dropdown",
      question_order: 20,
      answer_options: [
        { label: "Very flexible", value: "flexible" },
        { label: "Other", value: "Other", requires_text: true }
      ].to_json
    )
    integer = category.questions.create!(
      question_text: "How many hours per week do you work on average?",
      question_type: "integer",
      question_order: 21,
      integer_min: "1",
      integer_max: "40"
    )
    blanked = category.questions.create!(
      question_text: "This answer will be blanked",
      question_type: "short_answer",
      question_order: 22
    )
    StudentQuestion.create!(
      student: students(:student),
      advisor: advisors(:advisor),
      question: blanked,
      answer: "Existing answer"
    )

    post :save_progress,
         params: {
           id: survey.id,
           stay: "1",
           return_to: "/survey_responses/#{students(:student).student_id}-#{survey.id}",
           answers: {
             choice.id.to_s => "Other",
             integer.id.to_s => "99",
             blanked.id.to_s => ""
           },
           other_answers: { choice.id.to_s => "Rotating schedule" }
         }

    assert_redirected_to survey_path(survey, return_to: "/survey_responses/#{students(:student).student_id}-#{survey.id}")
    assert_equal({ "answer" => "Other", "text" => "Rotating schedule" }, StudentQuestion.find_by!(student: students(:student), question: choice).answer)
    assert_equal "99", StudentQuestion.find_by!(student: students(:student), question: integer).answer
    assert_nil StudentQuestion.find_by(student: students(:student), question: blanked)
  end

  test "save progress autosave reports saved count and keeps progress message" do
    sign_in users(:student)
    survey = surveys(:fall_2025)
    question = questions(:fall_q1)

    post :save_progress,
         params: {
           id: survey.id,
           autosave: "1",
           answers: { question.id.to_s => "Draft response" }
         },
         as: :json

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal true, payload["saved"]
    assert_operator payload["saved_count"], :>=, 1
    assert_match "Progress saved", payload["message"]
    assert_equal "Draft response", StudentQuestion.find_by!(student: students(:student), question: question).answer
  end

  test "submit renders validation errors while preserving provided draft answers" do
    sign_in users(:student)
    survey = surveys(:fall_2025)
    category = categories(:clinical_skills)
    required_question = questions(:fall_q1)
    evidence = category.questions.create!(
      question_text: "Evidence link",
      question_type: "evidence",
      question_order: 30
    )
    integer = category.questions.create!(
      question_text: "Integer response",
      question_type: "integer",
      question_order: 31,
      integer_min: "1",
      integer_max: "5"
    )

    post :submit,
         params: {
           id: survey.id,
           answers: {
             required_question.id.to_s => "",
             evidence.id.to_s => "https://example.com/not-google",
             integer.id.to_s => "9"
           }
         }

    assert_response :unprocessable_entity
    assert_includes assigns(:missing_required), required_question.id
    assert_includes assigns(:invalid_evidence), evidence.id
    assert_includes assigns(:invalid_integer), integer.id
    assert_equal "https://example.com/not-google", StudentQuestion.find_by!(student: students(:student), question: evidence).answer
    assert_equal "9", StudentQuestion.find_by!(student: students(:student), question: integer).answer
  end

  test "show normalizes stored hash answers for evidence choice and rating style responses" do
    sign_in users(:student)
    survey = surveys(:fall_2025)
    category = categories(:clinical_skills)
    evidence = category.questions.create!(question_text: "Evidence", question_type: "evidence", question_order: 40)
    choice = category.questions.create!(
      question_text: "Choice",
      question_type: "multiple_choice",
      question_order: 41,
      answer_options: [ { label: "Other", value: "Other", requires_text: true } ].to_json
    )
    rating = category.questions.create!(question_text: "Rating", question_type: "short_answer", question_order: 42)

    StudentQuestion.create!(student: students(:student), question: evidence, answer: { link: "https://sites.google.com/tamu.edu/site" })
    StudentQuestion.create!(student: students(:student), question: choice, answer: { answer: "Other", text: "Needs explanation" })
    StudentQuestion.create!(student: students(:student), question: rating, answer: { rating: 4 })

    get :show, params: { id: survey.id }

    assert_response :success
    assert_equal "https://sites.google.com/tamu.edu/site", assigns(:existing_answers)[evidence.id.to_s]
    assert_equal "Other", assigns(:existing_answers)[choice.id.to_s]
    assert_equal "Needs explanation", assigns(:other_answers)[choice.id.to_s]
    assert_equal "4", assigns(:existing_answers)[rating.id.to_s]
  end

  test "show normalization skips other text when choice option does not require it" do
    sign_in users(:student)
    survey = surveys(:fall_2025)
    category = categories(:clinical_skills)
    choice = category.questions.create!(
      question_text: "Choice without other",
      question_type: "dropdown",
      question_order: 43,
      answer_options: [ { label: "Yes", value: "yes", requires_text: false } ].to_json
    )
    generic = category.questions.create!(question_text: "Generic answer hash", question_type: "short_answer", question_order: 44)

    StudentQuestion.create!(student: students(:student), question: choice, answer: { answer: "yes" })
    StudentQuestion.create!(student: students(:student), question: generic, answer: { answer: "Stored answer" })

    get :show, params: { id: survey.id }

    assert_response :success
    assert_equal "yes", assigns(:existing_answers)[choice.id.to_s]
    refute_includes assigns(:other_answers).keys, choice.id.to_s
    assert_equal "Stored answer", assigns(:existing_answers)[generic.id.to_s]
  end

  test "integer validation accepts strings numerics and answer hashes within configured range" do
    question = Question.new(question_type: "integer", integer_min: "2", integer_max: "5")

    assert @controller.send(:valid_integer_response_for_question?, question, " 2 ")
    assert @controller.send(:valid_integer_response_for_question?, question, 5)
    assert @controller.send(:valid_integer_response_for_question?, question, { answer: "4" })
    assert @controller.send(:valid_integer_response_for_question?, question, { text: "3" })
    assert @controller.send(:valid_integer_response_for_question?, question, { value: "2" })
    refute @controller.send(:valid_integer_response_for_question?, question, "1")
    refute @controller.send(:valid_integer_response_for_question?, question, "6")
    refute @controller.send(:valid_integer_response_for_question?, question, "3.5")
    refute @controller.send(:valid_integer_response_for_question?, question, "abc")

    no_max_question = Question.new(question_type: "integer", integer_min: "1", integer_max: nil)
    assert @controller.send(:valid_integer_response_for_question?, no_max_question, "999")
    refute @controller.send(:valid_integer_response_for_question?, no_max_question, "0")
  end

  test "integer draft normalization supports all submitted shapes" do
    assert_equal "4", @controller.send(:normalized_integer_draft_value, " 4 ")
    assert_equal "5", @controller.send(:normalized_integer_draft_value, 5)
    assert_equal "3", @controller.send(:normalized_integer_draft_value, { answer: "3" })
    assert_equal "2", @controller.send(:normalized_integer_draft_value, { text: "2" })
    assert_equal "1", @controller.send(:normalized_integer_draft_value, { value: "1" })
    assert_equal "", @controller.send(:normalized_integer_draft_value, nil)
  end

  test "safe internal path and save progress redirect reject external destinations" do
    survey = surveys(:fall_2025)
    @controller.instance_variable_set(:@survey, survey)

    assert_nil @controller.send(:safe_internal_path, nil)
    assert_nil @controller.send(:safe_internal_path, "")
    assert_nil @controller.send(:safe_internal_path, "https://example.com")
    assert_nil @controller.send(:safe_internal_path, "//evil.example")
    assert_equal "/student_dashboard", @controller.send(:safe_internal_path, "/student_dashboard")

    @controller.stub(:params, ActionController::Parameters.new(stay: "1", return_to: "/survey_responses/1-2")) do
      assert_equal survey_path(survey, return_to: "/survey_responses/1-2"), @controller.send(:save_progress_redirect_path)
    end

    @controller.stub(:params, ActionController::Parameters.new(exit_to: "/student_dashboard")) do
      assert_equal "/student_dashboard", @controller.send(:save_progress_redirect_path)
    end

    @controller.stub(:params, ActionController::Parameters.new(exit_to: "https://example.com")) do
      assert_equal student_dashboard_path, @controller.send(:save_progress_redirect_path)
    end
  end

  test "question ids in display order handles loaded associations with parent and child questions" do
    survey = surveys(:fall_2025)
    category = survey.categories.create!(name: "Display Order #{SecureRandom.hex(4)}")
    later = category.questions.create!(question_text: "Later", question_type: "short_answer", question_order: 2)
    parent = category.questions.create!(question_text: "Parent", question_type: "multiple_choice", question_order: 1, answer_options: %w[Yes No].to_json)
    child = category.questions.create!(
      question_text: "Child",
      question_type: "short_answer",
      question_order: 1,
      parent_question: parent,
      sub_question_order: 1
    )
    category.questions.load

    assert_equal [ parent.id, child.id, later.id ], @controller.send(:question_ids_in_display_order, [ category ])
    assert_equal [], @controller.send(:question_ids_in_display_order, [ nil ])
  end

  test "question ids in display order handles unloaded relations with and without sub question support" do
    survey = surveys(:fall_2025)
    category = survey.categories.create!(name: "Unloaded Display #{SecureRandom.hex(4)}")
    parent = category.questions.create!(question_text: "Parent", question_type: "dropdown", question_order: 1, answer_options: %w[Yes No].to_json)
    child = category.questions.create!(
      question_text: "Child",
      question_type: "short_answer",
      question_order: 1,
      parent_question: parent,
      sub_question_order: 1
    )
    later = category.questions.create!(question_text: "Later", question_type: "short_answer", question_order: 2)
    fresh_category = Category.find(category.id)

    Question.stub(:sub_question_columns_supported?, true) do
      assert_equal [ parent.id, child.id, later.id ], @controller.send(:question_ids_in_display_order, [ fresh_category ])
    end

    Question.stub(:sub_question_columns_supported?, false) do
      assert_equal [ parent.id, child.id, later.id ], @controller.send(:question_ids_in_display_order, [ Category.find(category.id) ])
    end
  end

  test "question rule wrapper methods delegate to shared survey rules" do
    parent = Question.new(id: 10, question_type: "dropdown", answer_options: %w[Yes No].to_json, is_required: true)
    child = Question.new(
      question_type: "short_answer",
      parent_question_id: 10,
      is_required: true
    )

    assert @controller.send(:required_for_submission?, child, answers: { "10" => "Yes" }, branch_parent_ids: [ 10 ])
    refute @controller.send(:required_for_submission?, child, answers: { "10" => "No" }, branch_parent_ids: [ 10 ])
    assert @controller.send(:blank_required_response?, child, " ")
    refute @controller.send(:blank_required_response?, child, "Employer")
    assert_equal "Yes", @controller.send(:normalized_answer_value, { answer: "Yes", text: "ignored" })
    assert @controller.send(:required_for_submission?, parent, answers: {}, branch_parent_ids: [ 10 ])
  end

  test "autosave request detects explicit param xhr and json format" do
    request_double = Struct.new(:xhr_value, :format_value) do
      def xhr? = xhr_value
      def format = format_value
    end
    html_format = Struct.new(:json_value) { def json? = json_value }.new(false)
    json_format = Struct.new(:json_value) { def json? = json_value }.new(true)

    @controller.stub(:params, ActionController::Parameters.new) do
      @controller.stub(:request, request_double.new(false, html_format)) do
        refute @controller.send(:autosave_request?)
      end
    end

    @controller.stub(:params, ActionController::Parameters.new(autosave: "1")) do
      @controller.stub(:request, request_double.new(false, html_format)) do
        assert @controller.send(:autosave_request?)
      end
    end

    @controller.stub(:params, ActionController::Parameters.new) do
      @controller.stub(:request, request_double.new(true, html_format)) do
        assert @controller.send(:autosave_request?)
      end

      @controller.stub(:request, request_double.new(false, json_format)) do
        assert @controller.send(:autosave_request?)
      end
    end
  end

  test "evidence accessibility delegates to the link checker" do
    EvidenceLinkChecker.stub(:call, [ true, :ok ]) do
      assert_equal [ true, :ok ], @controller.send(:evidence_accessible?, "https://sites.google.com/tamu.edu/example")
    end
  end

  test "build progress notice handles empty progress required counts and punctuation" do
    assert_equal "Saved", @controller.send(:build_progress_notice, prefix: "Saved", progress: {})
    assert_equal(
      "Saved 3/5 questions answered.",
      @controller.send(
        :build_progress_notice,
        prefix: "Saved",
        progress: { answered_total: 3, total_questions: 5, answered_required: 0, total_required: 0 }
      )
    )
    assert_equal(
      "Survey submitted successfully! 4/5 questions answered (2/3 required).",
      @controller.send(
        :build_progress_notice,
        prefix: "Survey submitted successfully!",
        progress: { answered_total: 4, total_questions: 5, answered_required: 2, total_required: 3 }
      )
    )
    assert_equal(
      "Already saved. 1/1 questions answered.",
      @controller.send(
        :build_progress_notice,
        prefix: "Already saved.",
        progress: { answered_total: 1, total_questions: 1, answered_required: 0, total_required: 0 }
      )
    )
  end

  test "completed assignment redirect skips absent editable and incomplete assignments" do
    student = students(:student)

    @controller.stub(:current_student, nil) do
      assert_nil @controller.send(:redirect_completed_assignment!)
    end

    @controller.stub(:current_student, student) do
      SurveyAssignment.stub(:find_by, nil) do
        assert_nil @controller.send(:redirect_completed_assignment!)
      end

      SurveyAssignment.stub(:find_by, FakeAssignment.new(completed_at_value: false, can_edit_now_value: false)) do
        assert_nil @controller.send(:redirect_completed_assignment!)
      end

      SurveyAssignment.stub(:find_by, FakeAssignment.new(completed_at_value: true, can_edit_now_value: true)) do
        assert_nil @controller.send(:redirect_completed_assignment!)
      end
    end
  end

  test "completed assignment redirect sends locked submissions to read only response" do
    student = students(:student)
    captured = nil
    assignment = FakeAssignment.new(completed_at_value: true, can_edit_now_value: false)

    @controller.stub(:current_student, student) do
      SurveyAssignment.stub(:find_by, assignment) do
        @controller.stub(:redirect_to, ->(*args, **kwargs) { captured = [ args, kwargs ]; true }) do
          @controller.send(:redirect_completed_assignment!)
        end
      end
    end

    assert_equal survey_response_path(SurveyResponse.build(student:, survey: surveys(:fall_2025))), captured.first.first
    assert_match "already been submitted", captured.second[:alert]
  end

  test "unavailable assignment redirect skips when no student survey or assignment exists" do
    student = students(:student)

    @controller.stub(:current_student, nil) do
      assert_nil @controller.send(:redirect_unavailable_assignment!)
    end

    @controller.instance_variable_set(:@survey, nil)
    @controller.stub(:current_student, student) do
      assert_nil @controller.send(:redirect_unavailable_assignment!)
    end

    @controller.instance_variable_set(:@survey, surveys(:fall_2025))
    @controller.stub(:current_student, student) do
      SurveyAssignment.stub(:find_by, nil) do
        assert_nil @controller.send(:redirect_unavailable_assignment!)
      end
    end
  end

  test "unavailable assignment redirect handles inactive surveys upcoming windows and closed windows" do
    student = students(:student)
    survey = surveys(:fall_2025)
    @controller.instance_variable_set(:@survey, survey)
    captured = []
    redirect = ->(*args, **kwargs) { captured << [ args, kwargs ]; true }

    @controller.stub(:current_student, student) do
      @controller.stub(:redirect_to, redirect) do
        survey.update!(is_active: false)
        SurveyAssignment.stub(:find_by, FakeAssignment.new(availability_status_value: :open)) do
          @controller.send(:redirect_unavailable_assignment!)
        end
        assert_match "no longer available", captured.last.second[:alert]

        survey.update!(is_active: true)
        SurveyAssignment.stub(:find_by, FakeAssignment.new(availability_status_value: :not_yet)) do
          @controller.send(:redirect_unavailable_assignment!)
        end
        assert_equal surveys_path, captured.last.first.first
        assert_equal "This survey is not available yet.", captured.last.second[:alert]

        available_from = Time.zone.local(2026, 1, 15, 9, 0)
        SurveyAssignment.stub(:find_by, FakeAssignment.new(availability_status_value: :not_yet, available_from:)) do
          @controller.send(:redirect_unavailable_assignment!)
        end
        assert_match "available starting", captured.last.second[:alert]

        SurveyAssignment.stub(:find_by, FakeAssignment.new(availability_status_value: :closed)) do
          @controller.send(:redirect_unavailable_assignment!)
        end
        assert_match "no longer available", captured.last.second[:alert]

        available_until = Time.zone.local(2026, 2, 1, 17, 0)
        SurveyAssignment.stub(:find_by, FakeAssignment.new(availability_status_value: :closed, available_until:)) do
          @controller.send(:redirect_unavailable_assignment!)
        end
        assert_match "closed on", captured.last.second[:alert]

        SurveyAssignment.stub(:find_by, FakeAssignment.new(availability_status_value: :open)) do
          assert_nil @controller.send(:redirect_unavailable_assignment!)
        end
      end
    ensure
      survey.update!(is_active: true)
    end
  end
end
