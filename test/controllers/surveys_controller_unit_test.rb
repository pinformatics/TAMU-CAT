require "test_helper"

class SurveysControllerUnitTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers

  tests SurveysController

  setup do
    @student_user = users(:student)
    @student = students(:student) || Student.first
    @semester = program_semesters(:fall_2025)

    @survey = Survey.new(
      title: "Unit Survey #{SecureRandom.hex(4)}",
      program_semester: @semester,
      description: "",
      is_active: true
    )
    @category = @survey.categories.build(name: "Unit Category", description: "")
    @required_q = @category.questions.build(
      question_text: "Required",
      question_order: 0,
      question_type: "short_answer",
      is_required: true
    )
    @dropdown_q = @category.questions.build(
      question_text: "Choice",
      question_order: 0,
      question_type: "dropdown",
      is_required: false,
      answer_options: [
        { label: "Other", value: "Other", requires_text: true },
        { label: "A", value: "A" }
      ].to_json
    )
    @evidence_q = @category.questions.build(
      question_text: "Evidence",
      question_order: 1,
      question_type: "evidence",
      is_required: false
    )
    @survey.save!

    SurveyAssignment.create!(
      survey: @survey,
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      assigned_at: 1.day.ago
    )
  end

  test "index handles nil current_student" do
    sign_in @student_user

    @controller.stub(:current_student, nil) do
      get :index
    end

    assert_response :success
    assert_equal [], assigns(:surveys).to_a
    assert assigns(:current_semester_label).present?
  end

  test "show sets editing notice when assignment completed but survey has not closed" do
    sign_in @student_user

    assignment = SurveyAssignment.find_by!(survey_id: @survey.id, student_id: @student.student_id)
    assignment.update!(completed_at: Time.current, available_until: nil)

    @controller.stub(:current_student, @student) do
      get :show, params: { id: @survey.id }
    end

    assert_response :success
    assert flash[:notice].to_s.include?("editing a submitted survey"), "Expected edit notice when revising"
  end

  test "show redirects to read-only response when survey is closed" do
    sign_in @student_user

    assignment = SurveyAssignment.find_by!(survey_id: @survey.id, student_id: @student.student_id)
    assignment.update!(completed_at: Time.current, available_until: 1.day.ago)

    @controller.stub(:current_student, @student) do
      get :show, params: { id: @survey.id }
    end

    survey_response = SurveyResponse.build(student: @student, survey: @survey)
    assert_redirected_to survey_response_path(survey_response)
    assert flash[:alert].to_s.include?("now closed")
  end

  test "save_progress redirects when student record missing" do
    sign_in @student_user

    @controller.stub(:current_student, nil) do
      post :save_progress, params: { id: @survey.id }
    end

    assert_redirected_to student_dashboard_path
    assert flash[:alert].to_s.include?("Student record not found")
  end

  test "submit highlights evidence link when access check fails" do
    sign_in @student_user

    @controller.stub(:current_student, @student) do
      @controller.stub(:evidence_accessible?, [ false, :forbidden ]) do
        post :submit, params: {
          id: @survey.id,
          answers: {
            @required_q.id.to_s => "ok",
            @evidence_q.id.to_s => "https://sites.google.com/tamu.edu/demo/home"
          }
        }
      end
    end

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), @evidence_q.id
    assert assigns(:first_error_question_id).present?
  end

  test "submit succeeds even if version capture and notification enqueue fail" do
    sign_in @student_user

    SurveyResponseVersion.stub(:capture_current!, ->(**_) { raise "boom" }) do
      SurveyNotificationJob.stub(:perform_later, ->(**_) { raise "enqueue failed" }) do
        @controller.stub(:current_student, @student) do
          @controller.stub(:evidence_accessible?, [ true, :ok ]) do
            post :submit, params: {
              id: @survey.id,
              answers: {
                @required_q.id.to_s => "ok",
                @dropdown_q.id.to_s => "A",
                @evidence_q.id.to_s => "https://sites.google.com/tamu.edu/demo/home"
              }
            }
          end
        end
      end
    end

    assert_response :redirect
    SurveyAssignment.find_by!(survey_id: @survey.id, student_id: @student.student_id).tap do |assignment|
      assert assignment.completed_at?
    end
  end

  test "submit falls back to student dashboard when survey_response_path generation fails" do
    sign_in @student_user

    @controller.stub(:survey_response_path, ->(_id = nil) { raise ActionController::UrlGenerationError, "nope" }) do
      @controller.stub(:current_student, @student) do
        @controller.stub(:evidence_accessible?, [ true, :ok ]) do
          post :submit, params: {
            id: @survey.id,
            answers: {
              @required_q.id.to_s => "ok",
              @dropdown_q.id.to_s => "A",
              @evidence_q.id.to_s => "https://sites.google.com/tamu.edu/demo/home"
            }
          }
        end
      end
    end

    assert_redirected_to student_dashboard_path
  end

  test "show normalizes stored hash answers for evidence and choice questions" do
    sign_in @student_user

    StudentQuestion.where(student_id: @student.student_id, question_id: [ @evidence_q.id, @dropdown_q.id ]).delete_all
    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: @evidence_q.id,
      answer: { "link" => "https://sites.google.com/tamu.edu/demo/home" }
    )
    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: @dropdown_q.id,
      answer: { "answer" => "Other", "text" => "details" }
    )

    @controller.stub(:current_student, @student) do
      get :show, params: { id: @survey.id }
    end

    assert_response :success
    assert_equal "https://sites.google.com/tamu.edu/demo/home", assigns(:existing_answers)[@evidence_q.id.to_s]
    assert_equal "Other", assigns(:existing_answers)[@dropdown_q.id.to_s]
    assert_equal "details", assigns(:other_answers)[@dropdown_q.id.to_s]
  end

  test "submit redirects when student record missing" do
    sign_in @student_user

    @controller.stub(:current_student, nil) do
      post :submit, params: { id: @survey.id }
    end

    assert_redirected_to student_dashboard_path
    assert_match "Student record not found", flash[:alert]
  end

  test "submit redirects to read-only response when already completed and closed" do
    sign_in @student_user

    assignment = SurveyAssignment.find_by!(survey_id: @survey.id, student_id: @student.student_id)
    assignment.update!(completed_at: Time.current, available_until: 1.day.ago)

    @controller.stub(:current_student, @student) do
      post :submit, params: { id: @survey.id }
    end

    survey_response = SurveyResponse.build(student: @student, survey: @survey)
    assert_redirected_to survey_response_path(survey_response)
    assert_match "now closed", flash[:alert]
  end

  test "save_progress enforces read-only when impersonating" do
    sign_in users(:advisor)

    @request.session[:impersonator_user_id] = users(:admin).id
    @request.env["HTTP_REFERER"] = advisor_dashboard_path

    post :save_progress, params: { id: @survey.id }

    assert_redirected_to advisor_dashboard_path
    assert_equal "Read-only while impersonating.", flash[:alert]
  end

  test "show computed required treats yes/no and flexibility scale as optional" do
    sign_in @student_user

    yes_no = @category.questions.create!(
      question_text: "Optional yes/no",
      question_order: 10,
      question_type: "dropdown",
      is_required: false,
      answer_options: [
        { label: "Yes", value: "Yes" },
        { label: "No", value: "No" }
      ].to_json
    )
    flexibility = @category.questions.create!(
      question_text: "How flexible are you?",
      question_order: 11,
      question_type: "dropdown",
      is_required: false,
      answer_options: %w[1 2 3 4 5].map { |v| { label: v, value: v } }.to_json
    )

    @controller.stub(:current_student, @student) do
      get :show, params: { id: @survey.id }
    end

    assert_response :success
    computed = assigns(:computed_required)
    assert_equal false, computed[yes_no.id]
    assert_equal false, computed[flexibility.id]
  end

  test "employment-style sub questions are required only when parent answer is yes" do
    parent = @category.questions.create!(
      question_text: "Are you currently employed?",
      question_order: 12,
      question_type: "multiple_choice",
      is_required: true,
      answer_options: %w[Yes No].to_json
    )
    child = @category.questions.create!(
      question_text: "If yes, where are you employed?",
      question_order: 12,
      question_type: "short_answer",
      is_required: false,
      parent_question: parent,
      sub_question_order: 1
    )

    assert_equal true, @controller.send(:required_for_submission?, child, answers: { parent.id.to_s => "Yes" }, branch_parent_ids: [ parent.id ])
    assert_equal false, @controller.send(:required_for_submission?, child, answers: { parent.id.to_s => "No" }, branch_parent_ids: [ parent.id ])
  end

  test "submit persists provided answers and destroys removed records when submit validation fails" do
    sign_in @student_user

    section = SurveySection.create!(survey: @survey, title: "Unit Section")
    @category.update!(section: section)

    # Existing answer should be removed when user submits blank.
    StudentQuestion.where(student_id: @student.student_id, question_id: @evidence_q.id).delete_all
    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: @evidence_q.id,
      answer: "https://sites.google.com/tamu.edu/old/home"
    )

    @controller.stub(:current_student, @student) do
      post :submit, params: {
        id: @survey.id,
        answers: {
          # Leave required blank to force unprocessable_entity
          @required_q.id.to_s => "",
          @dropdown_q.id.to_s => "Other",
          @evidence_q.id.to_s => ""
        },
        other_answers: {
          @dropdown_q.id.to_s => "details"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_equal "survey-section-#{section.id}", assigns(:first_error_section_dom_id)

    assert_nil StudentQuestion.find_by(student_id: @student.student_id, question_id: @evidence_q.id)
    stored = StudentQuestion.find_by(student_id: @student.student_id, question_id: @dropdown_q.id)
    assert stored.present?
    assert_equal({ "answer" => "Other", "text" => "details" }, stored.answer)
  end

  test "question_ids_in_display_order handles loaded and unloaded questions" do
    sign_in @student_user

    category = @survey.categories.create!(name: "Order Category", description: "")
    q1 = category.questions.create!(question_text: "A", question_order: 2, question_type: "short_answer", is_required: false)
    q2 = category.questions.create!(question_text: "B", question_order: 1, question_type: "short_answer", is_required: false)

    # Loaded association path
    loaded_category = Category.includes(:questions).find(category.id)
    ids_loaded = @controller.send(:question_ids_in_display_order, [ loaded_category ])
    assert_equal [ q2.id, q1.id ], ids_loaded

    # Unloaded association path with sub-question columns disabled
    unloaded_category = Category.find(category.id)
    Question.stub(:sub_question_columns_supported?, false) do
      ids_unloaded = @controller.send(:question_ids_in_display_order, [ unloaded_category ])
      assert_equal [ q2.id, q1.id ], ids_unloaded
    end
  end

  test "evidence_accessible rejects invalid URLs and forbids redirects to non-allowlisted hosts" do
    # invalid URI
    assert_equal [ false, :invalid ], @controller.send(:evidence_accessible?, "not a url")
    # non-HTTPS
    assert_equal [ false, :invalid ], @controller.send(:evidence_accessible?, "http://sites.google.com/tamu.edu/demo/home")

    url = "https://sites.google.com/tamu.edu/demo/home"
    stub_request(:head, url).to_return(status: 302, headers: { "Location" => "https://accounts.google.com/signin" })
    assert_equal [ false, :forbidden ], @controller.send(:evidence_accessible?, url)
  end

  test "build_progress_notice appends a period and includes counts" do
    msg = @controller.send(
      :build_progress_notice,
      prefix: "Progress saved!",
      progress: { total_questions: 3, answered_total: 1, total_required: 2, answered_required: 1 }
    )

    assert_match "1/3 questions answered", msg
    assert_match "(1/2 required)", msg
    assert msg.end_with?("."), "Expected a trailing period"

    assert_equal "Done.", @controller.send(:build_progress_notice, prefix: "Done.", progress: { total_questions: 0 })
  end
end
