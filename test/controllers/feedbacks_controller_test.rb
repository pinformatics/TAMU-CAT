require "test_helper"

class FeedbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @adv_user = users(:advisor)
    @advisor = @adv_user.advisor_profile

    @admin_user = users(:admin)
    @other_adv_user = users(:other_advisor)
    @other_advisor = @other_adv_user.advisor_profile

    @student_user = users(:student)
    @student = students(:student) || Student.first

    @survey = (defined?(surveys) && surveys(:fall_2025) rescue nil)
    unless @survey
      @survey = Survey.create!(title: "Survey X", semester: "Fall")
      c1 = @survey.categories.create!(name: "Cat A")
      c1.questions.create!(question_text: "Q A1", question_order: 1, question_type: "short_answer")
      c2 = @survey.categories.create!(name: "Cat B")
      c2.questions.create!(question_text: "Q B1", question_order: 1, question_type: "short_answer")
    end

    # Ensure survey has at least two categories (fixtures may not include them)
    if @survey.categories.count < 2
      (2 - @survey.categories.count).times do |i|
        c = @survey.categories.create!(name: "Cat #{i + 1}")
        c.questions.create!(question_text: "Q #{i + 1}", question_order: i + 1, question_type: "short_answer")
      end
      @survey.reload
    end
    @cat1, @cat2 = @survey.categories.order(:id).limit(2)
    @feedback = feedbacks(:advisor_feedback)
    @survey.update!(advisor_numeric_feedback_enabled: true)

    sign_in @adv_user
  end

  # === Index Action ===

  test "index displays all feedbacks" do
    get feedbacks_path
    assert_response :success
  end

  # === Show Action ===

  test "show displays feedback" do
    get feedback_path(@feedback)
    assert_response :success
  end

  # === New Action ===

  test "new renders form with survey and student context" do
    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }
    assert_response :success
  end

  test "advisor numeric ratings can be retired while written feedback remains" do
    @survey.update!(advisor_numeric_feedback_enabled: false)
    section = SurveySection.find_or_create_by!(survey: @survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = @survey.categories.create!(name: "Retired Numeric Competencies", section: section)
    question = category.questions.create!(
      question_text: Reports::DataAggregator::COMPETENCY_TITLES.first,
      question_order: 1,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5],
      has_feedback: true
    )

    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }

    assert_response :success
    assert_select "select[name='ratings[#{question.id}][average_score]']", count: 0
    assert_includes response.body, "numeric ratings are retired"

    assert_difference "Feedback.count", 1 do
      post feedbacks_path, params: {
        survey_id: @survey.id,
        student_id: @student.student_id,
        submission_intent: "submit",
        ratings: {
          question.id.to_s => { comments: "Written review only" }
        }
      }
    end

    assert_response :see_other
    feedback = Feedback.order(:created_at).last
    assert_nil feedback.average_score
    assert_equal "Written review only", feedback.comments
  end

  test "new loads survey response context" do
    # Create student question responses
    q = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")
    StudentQuestion.find_or_create_by!(student_id: @student.student_id, question_id: q.id) do |sq|
      sq.response_text = "Test response"
    end

    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }
    assert_response :success
  end

  test "new with prefill seeds advisor scores from student competency responses" do
    section = SurveySection.find_or_create_by!(survey: @survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = @survey.categories.create!(name: "Prefill Competencies", section: section)
    question = category.questions.create!(
      question_text: Reports::DataAggregator::COMPETENCY_TITLES.first,
      question_order: 1,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5],
      has_feedback: true
    )
    StudentQuestion.find_or_create_by!(student_id: @student.student_id, question_id: question.id) do |response|
      response.response_value = "3"
    end

    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id, prefill: true }

    assert_response :success
    assert_select "select[name='ratings[#{question.id}][average_score]'] option[selected='selected'][value='3']", text: /3/
  end

  test "new with prefill remaps submitted version answers to current survey questions" do
    section = SurveySection.find_or_create_by!(survey: @survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = @survey.categories.create!(name: "Versioned Prefill Competencies", section: section)
    first_question = category.questions.create!(
      question_text: Reports::DataAggregator::COMPETENCY_TITLES.first,
      question_order: 1,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5],
      has_feedback: true
    )
    second_question = category.questions.create!(
      question_text: Reports::DataAggregator::COMPETENCY_TITLES.second,
      question_order: 2,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5],
      has_feedback: true
    )
    StudentQuestion.where(student_id: @student.student_id, question_id: [ first_question.id, second_question.id ]).delete_all
    SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      event: "submitted",
      answers: {
        (first_question.id + 50).to_s => "4",
        (second_question.id + 50).to_s => "2"
      }
    )

    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id, prefill: true }

    assert_response :success
    assert_select "select[name='ratings[#{first_question.id}][average_score]'] option[selected='selected'][value='4']", text: /4/
    assert_select "select[name='ratings[#{second_question.id}][average_score]'] option[selected='selected'][value='2']", text: /2/
  end

  test "new redirects when survey is archived" do
    @survey.update!(is_active: false)

    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }

    assert_redirected_to student_records_path
    assert_match "survey is archived", flash[:alert].to_s.downcase
  end

  # === Edit Action ===

  test "edit renders form" do
    get edit_feedback_path(@feedback)
    assert_response :success
  end

  # === Create Action - Batch Ratings ===

  test "batch create creates feedback records and redirects" do
    # Controller now expects ratings keyed by question id (per-question feedback)
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Auto Q1", question_order: 1, question_type: "short_answer")
    q2 = @cat2.questions.first || @cat2.questions.create!(question_text: "Auto Q2", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "4", comments: "Good" },
        q2.id.to_s => { average_score: "3", comments: "Ok" }
      }
    }

    before_count = Feedback.where(student_id: @student.student_id, survey_id: @survey.id).count
    post feedbacks_path, params: params

    assert_response :redirect
    assert_redirected_to student_records_path
    after_count = Feedback.where(student_id: @student.student_id, survey_id: @survey.id).count
    assert_equal before_count + 2, after_count
  end

  test "batch create is blocked when survey is archived" do
    @survey.update!(is_active: false)
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Auto Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "4", comments: "Good" }
      }
    }

    assert_no_difference "Feedback.count" do
      post feedbacks_path, params: params
    end

    assert_redirected_to student_records_path
    assert_match "survey is archived", flash[:alert].to_s.downcase
  end

  test "batch create with only score" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "5", comments: "" }
      }
    }

    assert_difference "Feedback.count", 1 do
      post feedbacks_path, params: params
    end

    assert_redirected_to student_records_path
    feedback = Feedback.order(:created_at).last
    assert_equal 5.0, feedback.average_score
    assert_nil feedback.comments
  end

  test "batch create with only comments" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "", comments: "Great work!" }
      }
    }

    assert_difference "Feedback.count", 1 do
      post feedbacks_path, params: params
    end

    assert_redirected_to student_records_path
    feedback = Feedback.order(:created_at).last
    assert_nil feedback.average_score
    assert_equal "Great work!", feedback.comments
  end

  test "batch create skips empty ratings" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")
    q2 = @cat2.questions.first || @cat2.questions.create!(question_text: "Q2", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "4", comments: "Good" },
        q2.id.to_s => { average_score: "", comments: "" } # Empty, should be skipped
      }
    }

    assert_difference "Feedback.count", 1 do # Only 1 should be created
      post feedbacks_path, params: params
    end

    assert_redirected_to student_records_path
  end

  test "batch create updates existing feedback" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    # Create initial feedback
    existing = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      question_id: q1.id,
      category_id: @cat1.id,
      advisor_id: @advisor.advisor_id,
      average_score: 3,
      comments: "Initial"
    )

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { id: existing.id, average_score: "5", comments: "Updated" }
      }
    }

    assert_no_difference "Feedback.count" do
      post feedbacks_path, params: params
    end

    existing.reload
    assert_equal 5.0, existing.average_score
    assert_equal "Updated", existing.comments
  end

  test "batch create returns conflict when feedback was updated concurrently" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    existing = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      question_id: q1.id,
      category_id: @cat1.id,
      advisor_id: @advisor.advisor_id,
      average_score: 3,
      comments: "Initial"
    )

    stale_lock_version = existing.lock_version

    # Simulate a concurrent save that happens after the form was rendered.
    existing.update!(comments: "Concurrent update")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { id: existing.id, lock_version: stale_lock_version.to_s, average_score: "5", comments: "My update" }
      }
    }

    post feedbacks_path, params: params
    assert_response :unprocessable_entity

    existing.reload
    assert_equal "Concurrent update", existing.comments
  end

  test "batch create saves confidential advisor note when present" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Auto Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "4", comments: "Good" }
      },
      confidential_advisor_note: { body: "Confidential note from unified save" }
    }

    assert_difference "ConfidentialAdvisorNote.count", 1 do
      post feedbacks_path, params: params
    end

    note = ConfidentialAdvisorNote.find_by(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id
    )
    assert note
    assert_equal "Confidential note from unified save", note.body
  end

  test "batch create clears confidential advisor note when blank" do
    ConfidentialAdvisorNote.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      body: "Existing confidential note"
    )

    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Auto Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "4", comments: "Good" }
      },
      confidential_advisor_note: { body: "   " }
    }

    assert_difference "ConfidentialAdvisorNote.count", -1 do
      post feedbacks_path, params: params
    end

    refute ConfidentialAdvisorNote.find_by(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id
    )
  end

  test "batch create allows note-only save and redirects" do
    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {},
      confidential_advisor_note: { body: "Note-only save" }
    }

    assert_difference "ConfidentialAdvisorNote.count", 1 do
      post feedbacks_path, params: params
    end

    assert_response :redirect
    assert_redirected_to student_records_path

    note = ConfidentialAdvisorNote.find_by(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id
    )
    assert note
    assert_equal "Note-only save", note.body
  end

  test "batch create redirects to return_to when provided" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Auto Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      return_to: "/student_records",
      ratings: {
        q1.id.to_s => { average_score: "4", comments: "Good" }
      }
    }

    post feedbacks_path, params: params
    assert_response :redirect
    assert_redirected_to student_records_path
  end

  test "batch create with validation errors rolls back transaction" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "invalid", comments: "Test" }
      }
    }

    assert_no_difference "Feedback.count" do
      post feedbacks_path, params: params
    end

    assert_response :unprocessable_entity
  end

  test "batch create rejects scores outside 1-5" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "6", comments: "Too high" }
      }
    }

    assert_no_difference "Feedback.count" do
      post feedbacks_path, params: params
    end

    assert_response :unprocessable_entity
  end

  test "batch create accepts 0 score" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "0", comments: "Not assessable" }
      }
    }

    assert_difference "Feedback.count", 1 do
      post feedbacks_path, params: params
    end

    assert_response :see_other
  end

  test "batch create with no valid ratings returns error" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "", comments: "" } # Empty
      }
    }

    assert_no_difference "Feedback.count" do
      post feedbacks_path, params: params
    end

    assert_response :unprocessable_entity
  end

  test "batch create responds with JSON on success" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "4", comments: "Good" }
      }
    }

    post feedbacks_path, params: params, as: :json

    assert_response :created
    json = JSON.parse(response.body)
    assert_kind_of Array, json
  end

  test "batch create responds with JSON on validation error" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "invalid", comments: "Test" }
      }
    }

    post feedbacks_path, params: params, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["errors"].present?
  end

  test "batch create responds with JSON when no ratings provided" do
    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {}
    }

    post feedbacks_path, params: params, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "No category or ratings provided", json["error"]
  end

  test "create with feedback param but no question_id shows error" do
    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      feedback: {
        average_score: "4",
        comments: "Test"
      }
    }

    post feedbacks_path, params: params

    # No question_id means it falls through to the else clause
    assert_response :unprocessable_entity
  end

  # === Create Action - Error Cases ===

  test "create without ratings or feedback params returns error" do
    params = {
      survey_id: @survey.id,
      student_id: @student.student_id
    }

    post feedbacks_path, params: params

    assert_response :unprocessable_entity
  end

  test "create without ratings or feedback responds with JSON error" do
    params = {
      survey_id: @survey.id,
      student_id: @student.student_id
    }

    post feedbacks_path, params: params, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "No category or ratings provided", json["error"]
  end

  test "create allows confidential note save without ratings param" do
    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      confidential_advisor_note: { body: "Note-only without ratings param" }
    }

    assert_difference "ConfidentialAdvisorNote.count", 1 do
      post feedbacks_path, params: params
    end

    assert_response :redirect
    assert_redirected_to student_records_path
  end

  test "create with feedback question_id saves per-question feedback" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Auto Q1", question_order: 1, question_type: "short_answer")

    params = {
      feedback: {
        survey_id: @survey.id,
        student_id: @student.student_id,
        question_id: q1.id,
        average_score: "4",
        comments: "Single"
      }
    }

    assert_difference "Feedback.count", 1 do
      post feedbacks_path, params: params
    end

    assert_redirected_to student_records_path
    feedback = Feedback.order(:created_at).last
    assert_equal q1.id, feedback.question_id
    assert_equal q1.category_id, feedback.category_id
    assert_equal 4.0, feedback.average_score
    assert_equal "Single", feedback.comments
  end

  test "admin create with feedback question_id saves under assigned advisor" do
    sign_in @admin_user
    @student.update!(advisor_id: @advisor.advisor_id)
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Auto Q1", question_order: 1, question_type: "short_answer")

    assert_difference "Feedback.count", 1 do
      post feedbacks_path, params: {
        feedback: {
          survey_id: @survey.id,
          student_id: @student.student_id,
          question_id: q1.id,
          average_score: "3",
          comments: "Admin entered"
        }
      }
    end

    feedback = Feedback.order(:created_at).last
    assert_equal @advisor.advisor_id, feedback.advisor_id
    assert_equal q1.id, feedback.question_id
    assert_equal 3.0, feedback.average_score
  end

  test "batch create returns JSON error when confidential note lock is stale" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Auto Q1", question_order: 1, question_type: "short_answer")

    note = ConfidentialAdvisorNote.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      body: "Initial"
    )
    stale_lock_version = note.lock_version
    note.update!(body: "Concurrent update")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { average_score: "4", comments: "Good" }
      },
      confidential_advisor_note: { body: "My update", lock_version: stale_lock_version.to_s }
    }

    post feedbacks_path, params: params, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json.fetch("errors").fetch("confidential_advisor_note").join(" "), "updated by someone else"
  end

  test "note-only batch create returns JSON errors when confidential note lock is stale" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Auto Q1", question_order: 1, question_type: "short_answer")

    note = ConfidentialAdvisorNote.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      body: "Initial"
    )
    stale_lock_version = note.lock_version
    note.update!(body: "Concurrent update")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      # ratings must be present to take the batch path, but can be empty inputs
      # to trigger the note-only save behavior.
      ratings: {
        q1.id.to_s => { average_score: "", comments: "" }
      },
      confidential_advisor_note: { body: "My update", lock_version: stale_lock_version.to_s }
    }

    post feedbacks_path,
         params: params,
         as: :json,
         headers: { "ACCEPT" => "application/json" }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json.fetch("errors").fetch("confidential_advisor_note").join(" "), "updated by someone else"
  end

  # === Update Action ===

  test "update feedback successfully" do
    patch feedback_path(@feedback), params: {
      feedback: {
        average_score: "4.8",
        comments: "Updated comments"
      }
    }

    assert_redirected_to feedback_path(@feedback)
    @feedback.reload
    assert_equal 4.8, @feedback.average_score
    assert_equal "Updated comments", @feedback.comments
  end

  test "update feedback with survey and student context redirects to new feedback page" do
    patch feedback_path(@feedback), params: {
      feedback: {
        survey_id: @survey.id,
        student_id: @student.student_id,
        average_score: "4.5",
        comments: "Updated"
      }
    }

    assert_redirected_to new_feedback_path(survey_id: @survey.id, student_id: @student.student_id)
  end

  test "update feedback responds with JSON" do
    patch feedback_path(@feedback), params: {
      feedback: {
        average_score: "4.9"
      }
    }, as: :json

    assert_response :ok
  end

  test "update feedback with validation error" do
    patch feedback_path(@feedback), params: {
      feedback: {
        average_score: "invalid"
      }
    }

    assert_response :unprocessable_entity
  end

  test "update feedback with validation error responds with JSON" do
    patch feedback_path(@feedback), params: {
      feedback: {
        average_score: "invalid"
      }
    }, as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert json["average_score"].present?
  end

  test "update is blocked when feedback survey is archived" do
    feedback = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      category_id: @cat1.id,
      advisor_id: @advisor.advisor_id,
      average_score: 3,
      comments: "Original"
    )
    @survey.update!(is_active: false)

    patch feedback_path(feedback), params: {
      feedback: {
        comments: "Should not save"
      }
    }

    assert_redirected_to student_records_path
    assert_match "feedback is read-only", flash[:alert].to_s.downcase
    feedback.reload
    assert_equal "Original", feedback.comments
  end

  # === Destroy Action ===

  test "destroy deletes feedback and redirects" do
    feedback = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      category_id: @cat1.id,
      advisor_id: @advisor.advisor_id,
      average_score: 3,
      comments: "To delete"
    )

    assert_difference "Feedback.count", -1 do
      delete feedback_path(feedback)
    end

    assert_redirected_to feedbacks_path
  end

  test "destroy responds with JSON" do
    feedback = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      category_id: @cat1.id,
      advisor_id: @advisor.advisor_id,
      average_score: 3,
      comments: "To delete"
    )

    assert_difference "Feedback.count", -1 do
      delete feedback_path(feedback), as: :json
    end

    assert_response :no_content
  end

  test "destroy is blocked when feedback survey is archived" do
    feedback = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      category_id: @cat1.id,
      advisor_id: @advisor.advisor_id,
      average_score: 3,
      comments: "To keep"
    )
    @survey.update!(is_active: false)

    assert_no_difference "Feedback.count" do
      delete feedback_path(feedback)
    end

    assert_redirected_to student_records_path
    assert_match "feedback is read-only", flash[:alert].to_s.downcase
  end

  # === Edge Cases ===

  test "batch create with invalid question raises error due to null category_id" do
    invalid_question_id = 999999

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        invalid_question_id.to_s => { average_score: "4", comments: "Test" }
      }
    }

    post feedbacks_path, params: params
    assert_response :unprocessable_entity
  end

  test "new loads context properly" do
    # Just test it doesn't error and loads the view
    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }
    assert_response :success
  end

  test "create with existing feedback by id that doesn't match returns error" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      ratings: {
        q1.id.to_s => { id: 999999, average_score: "4", comments: "Test" }
      }
    }

    post feedbacks_path, params: params

    assert_response :unprocessable_entity
  end

  test "new shows confidential notes section for admin" do
    sign_out @adv_user
    sign_in @admin_user

    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }
    assert_response :success
    assert_includes response.body, "Confidential advisor notes"
  end

  test "new hides confidential notes section for non-owner advisor" do
    sign_out @adv_user
    sign_in @other_adv_user

    get new_feedback_path, params: { survey_id: @survey.id, student_id: @student.student_id }
    assert_response :success
    refute_includes response.body, "Confidential advisor notes"
  end

  test "note-only create does not save confidential note for non-owner advisor" do
    sign_out @adv_user
    sign_in @other_adv_user

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      confidential_advisor_note: { body: "Should not persist" }
    }

    assert_no_difference "ConfidentialAdvisorNote.count" do
      post feedbacks_path, params: params
    end

    assert_response :redirect
    assert_redirected_to student_records_path
  end

  test "create rejects non-local return_to to prevent open redirect" do
    q1 = @cat1.questions.first || @cat1.questions.create!(question_text: "Q1", question_order: 1, question_type: "short_answer")

    params = {
      survey_id: @survey.id,
      student_id: @student.student_id,
      return_to: "//evil.example.com/phish",
      ratings: {
        q1.id.to_s => { average_score: "4", comments: "Good" }
      }
    }

    post feedbacks_path, params: params

    assert_response :redirect
    assert_redirected_to student_records_path
  end
end
