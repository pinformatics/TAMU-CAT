require "test_helper"

class SurveysControllerAdditionalTest < ActionDispatch::IntegrationTest
  setup do
    @student_user = users(:student)
    @student = students(:student)
    sign_in @student_user
  end

  test "show renders newly added sections even when they have no categories" do
    survey = Survey.new(title: "Section Visibility #{SecureRandom.hex(4)}", semester: "Fall 2025")

    category = survey.categories.build(name: "Category A", description: "")
    category.questions.build(
      question_text: "Q1",
      question_order: 1,
      question_type: "short_answer",
      is_required: true
    )
    survey.save!

    section_with_category = survey.sections.create!(title: "Section A", description: "", position: 0)
    category.update!(section: section_with_category)
    survey.sections.create!(title: "New Empty Section", description: "", position: 1)

    SurveyAssignment.create!(
      survey: survey,
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      assigned_at: Time.current,
      available_from: 1.day.ago,
      available_until: 7.days.from_now
    )

    get survey_path(survey)
    assert_response :success
    assert_match(/New Empty Section/, response.body)
  end

  test "submit renders unprocessable_entity when required answer missing and persists partial answers" do
    survey = Survey.new(title: "Required Survey #{SecureRandom.hex(4)}", semester: "Fall 2025")
    category = survey.categories.build(name: "General", description: "")
    required_q = category.questions.build(
      question_text: "Required?",
      question_order: 1,
      question_type: "short_answer",
      is_required: true
    )
    optional_q = category.questions.build(
      question_text: "Optional",
      question_order: 2,
      question_type: "short_answer",
      is_required: false
    )
    survey.save!

    post submit_survey_path(survey), params: { answers: { required_q.id.to_s => "", optional_q.id.to_s => "some" } }

    assert_response :unprocessable_entity
    assert_match(/We could not submit/i, response.body)

    saved = StudentQuestion.find_by(student_id: @student.student_id, question_id: optional_q.id)
    assert_not_nil saved
  end

  test "submit rejects invalid evidence link format" do
    survey = Survey.new(title: "Evidence Survey #{SecureRandom.hex(4)}", semester: "Fall 2025")
    category = survey.categories.build(name: "Evidence", description: "")
    evidence_q = category.questions.build(
      question_text: "Upload evidence",
      question_order: 1,
      question_type: "evidence",
      is_required: true
    )
    survey.save!

    post submit_survey_path(survey), params: { answers: { evidence_q.id.to_s => "https://example.com/not-google" } }

    assert_response :unprocessable_entity
    assert_match(/evidence links/i, response.body)
  end

  test "save_progress stores answers without requiring completion" do
    survey = Survey.new(title: "Save Progress #{SecureRandom.hex(4)}", semester: "Fall 2025")
    category = survey.categories.build(name: "General", description: "")
    q1 = category.questions.build(
      question_text: "Q1",
      question_order: 1,
      question_type: "short_answer",
      is_required: true
    )
    survey.save!

    post save_progress_survey_path(survey), params: { answers: { q1.id.to_s => "draft" } }

    assert_redirected_to student_dashboard_path

    saved = StudentQuestion.find_by(student_id: @student.student_id, question_id: q1.id)
    assert_not_nil saved
    assert_equal "draft", saved.answer
  end

  test "save_progress redirects to view-only response when completed and past due" do
    survey = Survey.new(title: "Past Due #{SecureRandom.hex(4)}", semester: "Fall 2025")
    category = survey.categories.build(name: "General", description: "")
    q1 = category.questions.build(
      question_text: "Q1",
      question_order: 1,
      question_type: "short_answer",
      is_required: true
    )
    survey.save!

    SurveyAssignment.create!(
      survey: survey,
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      assigned_at: 2.days.ago,
      completed_at: 1.day.ago,
      available_until: 1.day.ago
    )

    post save_progress_survey_path(survey), params: { answers: { q1.id.to_s => "ignored" } }

    assert_response :redirect
    assert_match(/survey_responses\//, response.location)
  end

  test "save_progress blocks edits when already submitted but not past due" do
    survey = surveys(:fall_2025)
    student = students(:student)

    assignment = SurveyAssignment.find_by(student_id: student.student_id, survey_id: survey.id)
    assignment ||= SurveyAssignment.create!(
      survey: survey,
      student_id: student.student_id,
      advisor_id: student.advisor_id,
      assigned_at: 2.days.ago
    )

    assignment.update!(completed_at: Time.current, available_until: 2.days.from_now)

    post save_progress_survey_path(survey), params: { answers: {} }

    assert_redirected_to survey_path(survey)
    assert_match(/already been submitted/i, flash[:alert].to_s)
  ensure
    assignment&.update!(completed_at: nil)
  end

  test "submit redirects to view-only response when already submitted and past due" do
    survey = surveys(:fall_2025)
    student = students(:student)

    assignment = SurveyAssignment.find_by(student_id: student.student_id, survey_id: survey.id)
    assignment ||= SurveyAssignment.create!(
      survey: survey,
      student_id: student.student_id,
      advisor_id: student.advisor_id,
      assigned_at: 2.days.ago
    )

    assignment.update!(completed_at: 2.days.ago, available_until: 1.day.ago)

    post submit_survey_path(survey), params: { answers: {} }

    assert_response :redirect
    assert_match(/survey_responses\//, response.location)
  ensure
    assignment&.update!(completed_at: nil)
  end
end
