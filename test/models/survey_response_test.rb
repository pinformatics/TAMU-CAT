require "test_helper"

class SurveyResponseTest < ActiveSupport::TestCase
  test "answers returns map of question id to answer when question_responses provided" do
    student = students(:student)
    survey = surveys(:fall_2025)
    sr = SurveyResponse.new(student: student, survey: survey)

    # provide a fake question_responses array for the PORO
    qr1 = OpenStruct.new(question_id: questions(:fall_q1).id, answer: "Yes")
    qr2 = OpenStruct.new(question_id: questions(:fall_q1).id + 1, answer: "No")
    sr.instance_variable_set(:@question_responses, [ qr1, qr2 ])

    map = sr.answers
    assert_kind_of Hash, map
    assert_equal "Yes", map[questions(:fall_q1).id]
  end

  test "id composes student id and survey id" do
    student = students(:student)
    survey = surveys(:fall_2025)
    sr = SurveyResponse.new(student: student, survey: survey)
    assert_match /#{student.student_id}-#{survey.id}/, sr.id
  end

  test "build creates a SurveyResponse and associates records" do
    survey = surveys(:fall_2025)
    student = students(:student)
    sr = SurveyResponse.build(student: student, survey: survey)
    # SurveyResponse is a PORO (ActiveModel), not persisted ActiveRecord
    assert_instance_of SurveyResponse, sr
    assert_equal "#{student.student_id}-#{survey.id}", sr.id
    assert_equal "#{student.student_id}-#{survey.id}", sr.to_param
  end
  setup do
    @student = students(:student)
    @advisor = advisors(:advisor)
    @student.update!(advisor: @advisor)

    @survey = surveys(:fall_2025)
    @question = questions(:fall_q1)
    StudentQuestion.where(student_id: @student.student_id).delete_all
  end

  test "answers returns student responses keyed by question id" do
    StudentQuestion.create!(student_id: @student.student_id, advisor: @advisor, question: @question, response_value: "Very satisfied")

    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    assert_equal({ @question.id => "Very satisfied" }, survey_response.answers)
  end

  test "question responses scope to survey" do
    other_survey = Survey.new(title: "Other", semester: "Fall 2025")
    other_category = other_survey.categories.build(name: "Other", description: "Other category")
    other_question = other_category.questions.build(
      question_text: "Other?",
      question_order: 2,
      question_type: "short_answer",
      is_required: false
    )
    other_survey.save!

    StudentQuestion.create!(student_id: @student.student_id, advisor: @advisor, question: @question, response_value: "Very satisfied")
    StudentQuestion.create!(student_id: @student.student_id, advisor: @advisor, question: other_question, response_value: "Different")

    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    question_ids = survey_response.question_responses.pluck(:question_id)
    assert_equal [ @question.id ], question_ids
  end

  test "advisor delegates to student advisor" do
    survey_response = SurveyResponse.build(student: @student, survey: @survey)
    assert_equal @advisor, survey_response.advisor
  end

  test "find_from_param and signed token lookup handle invalid values" do
    assert_raises(ActiveRecord::RecordNotFound) { SurveyResponse.find_from_param("missing") }
    assert_raises(ActiveRecord::RecordNotFound) { SurveyResponse.find_from_param("-") }
    assert_nil SurveyResponse.find_by_signed_download_token("bad-token")

    response = SurveyResponse.build(student: @student, survey: @survey)
    assert_equal response.id, SurveyResponse.find_by_signed_download_token(response.signed_download_token).id
  end

  test "answers override normalizes string keys and skips missing questions" do
    response = SurveyResponse.build(
      student: @student,
      survey: @survey,
      answers_override: {
        @question.id.to_s => "Override answer",
        "not_numeric" => "Ignored"
      },
      as_of: Time.zone.local(2026, 1, 1)
    )

    assert_equal "Override answer", response.answers[@question.id]
    assert_equal 1, response.question_responses.size
    assert_equal Time.zone.local(2026, 1, 1), response.completion_date
  end

  test "status handles optional-only surveys and blank array answers" do
    survey = Survey.new(title: "Optional Survey", program_semester: program_semesters(:fall_2025), is_active: true)
    survey.save!(validate: false)
    category = survey.categories.create!(name: "Optional")
    question = category.questions.create!(
      question_text: "Optional",
      question_type: "short_answer",
      question_order: 1,
      is_required: false
    )

    not_started = SurveyResponse.build(student: @student, survey: survey, answers_override: { question.id => [] })
    assert_equal :not_started, not_started.status

    submitted = SurveyResponse.build(student: @student, survey: survey, answers_override: { question.id => [ "Answered" ] })
    assert_equal :submitted, submitted.status
  end
end
