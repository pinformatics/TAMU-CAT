require "test_helper"

class SurveyResponsesVersioningTest < ActionDispatch::IntegrationTest
  setup do
    @student_user = users(:student)
    @admin_user = users(:admin)
    @student = students(:student)
    @survey = surveys(:fall_2025)
  end

  test "admin edit creates a new version and older versions remain viewable" do
    question = @survey.questions.order(:id).first
    assert question, "Expected survey to have at least one question"

    sign_in @student_user

    # Create a baseline version.
    post submit_survey_path(@survey), params: { answers: { question.id.to_s => "A1" } }
    assert_response :redirect

    versions_after_submit = SurveyResponseVersion
                             .for_pair(student_id: @student.student_id, survey_id: @survey.id)
                             .chronological
    assert_equal 1, versions_after_submit.size
    assert_equal "submitted", versions_after_submit.last.event
    assert_equal "A1", versions_after_submit.last.answers[question.id.to_s]

    # Admin edit should create a new "admin_edited" version.
    sign_in @admin_user
    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    assert_difference "SurveyResponseVersion.count", 1 do
      patch survey_response_path(survey_response), params: { answers: { question.id.to_s => "A_ADMIN" } }
    end
    assert_response :redirect

    versions_after_admin = SurveyResponseVersion
                            .for_pair(student_id: @student.student_id, survey_id: @survey.id)
                            .chronological
    assert_equal 2, versions_after_admin.size
    assert_equal "admin_edited", versions_after_admin.last.event
    assert_equal "A_ADMIN", versions_after_admin.last.answers[question.id.to_s]

    # Latest renders.
    get survey_response_path(survey_response)
    assert_response :success

    # Prior version renders via version_id.
    get survey_response_path(survey_response, version_id: versions_after_admin.first.id)
    assert_response :success
  end

  test "double submit with unchanged answers does not create an extra version" do
    question = @survey.questions.order(:id).first
    assert question, "Expected survey to have at least one question"

    sign_in @student_user

    answers = { question.id.to_s => "A1" }
    post submit_survey_path(@survey), params: { answers: answers }
    assert_response :redirect

    assert_equal 1, SurveyResponseVersion.for_pair(student_id: @student.student_id, survey_id: @survey.id).count

    assert_no_difference "SurveyResponseVersion.for_pair(student_id: @student.student_id, survey_id: @survey.id).count" do
      post submit_survey_path(@survey), params: { answers: answers }
      assert_response :redirect
    end
  end

  test "first submit ignores legacy draft edited versions" do
    question = @survey.questions.order(:id).first
    assert question, "Expected survey to have at least one question"
    SurveyResponseVersion.for_pair(student_id: @student.student_id, survey_id: @survey.id).delete_all
    StudentQuestion.where(student_id: @student.student_id, question_id: question.id).delete_all

    answers = { question.id.to_s => "Draft answer that becomes submitted" }
    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: question.id,
      response_value: answers[question.id.to_s]
    )
    assignment = SurveyAssignment.find_or_create_by!(student_id: @student.student_id, survey_id: @survey.id) do |row|
      row.advisor_id = @student.advisor_id
      row.assigned_at = 1.day.ago
    end
    assignment.update!(completed_at: nil, available_until: 2.days.from_now)
    SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      survey_assignment_id: assignment.id,
      event: "edited",
      answers: answers
    )

    sign_in @student_user

    assert_difference -> { SurveyResponseVersion.where(student_id: @student.student_id, survey_id: @survey.id, event: "submitted").count }, 1 do
      post submit_survey_path(@survey), params: { answers: answers }
      assert_response :redirect
    end

    versions = SurveyResponseVersion.for_pair(student_id: @student.student_id, survey_id: @survey.id).chronological
    assert_equal [ "edited", "submitted" ], versions.map(&:event)
    assert_equal answers, versions.last.answers
  end

  test "admin edit captures a baseline when no prior versions exist" do
    question = @survey.questions.order(:id).detect do |candidate|
      StudentQuestion.where(student_id: @student.student_id, question_id: candidate.id).none?
    end
    question ||= @survey.questions.order(:id).first
    assert question, "Expected survey to have at least one question"

    # Ensure we don't collide with fixtures.
    StudentQuestion.where(student_id: @student.student_id, question_id: question.id).delete_all

    # Create persisted answers without creating any SurveyResponseVersion rows.
    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: question.id,
      response_value: "A_BEFORE"
    )

    assert_equal 0, SurveyResponseVersion.for_pair(student_id: @student.student_id, survey_id: @survey.id).count

    sign_in @admin_user
    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    assert_difference "SurveyResponseVersion.count", 2 do
      patch survey_response_path(survey_response), params: { answers: { question.id.to_s => "A_AFTER" } }
    end
    assert_response :redirect

    versions = SurveyResponseVersion
                 .for_pair(student_id: @student.student_id, survey_id: @survey.id)
                 .chronological

    assert_equal 2, versions.size
    assert_equal "admin_snapshot", versions.first.event
    assert_equal "A_BEFORE", versions.first.answers[question.id.to_s]
    assert_equal "admin_edited", versions.last.event
    assert_equal "A_AFTER", versions.last.answers[question.id.to_s]
  end

  test "survey response show supports version navigation" do
    sign_in @student_user

    # Create a version by submitting once.
    answers = {}
    @survey.questions.limit(1).each { |q| answers[q.id.to_s] = "A1" }
    post submit_survey_path(@survey), params: { answers: answers }
    assert_response :redirect

    survey_response = SurveyResponse.build(student: @student, survey: @survey)
    get survey_response_path(survey_response)
    assert_response :success
    assert_match(/<a[^>]+>Edit<\/a>/, response.body)

    # Create a second version by revising before the survey closes.
    assignment = SurveyAssignment.find_by!(student_id: @student.student_id, survey_id: @survey.id)
    assignment.update!(available_until: 2.days.from_now)

    answers2 = {}
    @survey.questions.limit(1).each { |q| answers2[q.id.to_s] = "A2" }
    post submit_survey_path(@survey), params: { answers: answers2 }
    assert_response :redirect

    get survey_response_path(survey_response)
    assert_response :success
    assert_includes response.body, "Version"
    assert_includes response.body, "Latest"
    assert_includes response.body, "←"
  end

  test "survey response show renders Other free-text in read-only view" do
    category = @survey.categories.order(:id).first
    assert category, "Expected survey to have at least one category"

    question = Question.create!(
      category: category,
      question_text: "Test question with Other",
      question_type: "multiple_choice",
      question_order: 999,
      is_required: false,
      has_evidence_field: false,
      answer_options: [ "Yes", "No", "Other" ].to_json
    )

    StudentQuestion.where(student_id: @student.student_id, question_id: question.id).delete_all

    record = StudentQuestion.new(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: question.id
    )
    record.answer = { "text" => "My other free text" }
    record.save!(validate: false)

    sign_in @admin_user
    survey_response = SurveyResponse.build(student: @student, survey: @survey)
    get survey_response_path(survey_response)
    assert_response :success
    assert_includes response.body, "My other free text"
    refute_match(/<div[^>]*class="[^"]*hidden[^"]*"[^>]*data-other-for-question-id="#{question.id}"[^>]*>/, response.body)
  end

  test "admin delete creates notification" do
    sign_in @student_user
    answers = {}
    @survey.questions.limit(1).each { |q| answers[q.id.to_s] = "A1" }
    post submit_survey_path(@survey), params: { answers: answers }
    assert_response :redirect

    sign_in @admin_user
    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    assert_difference "Notification.count", 1 do
      delete survey_response_path(survey_response)
    end

    assert_redirected_to survey_records_path
  end
end
