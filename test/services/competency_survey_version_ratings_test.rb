require "test_helper"

class CompetencySurveyVersionRatingsTest < ActiveSupport::TestCase
  setup do
    @student = students(:student)
    @survey = surveys(:fall_2025)
    @section = SurveySection.find_or_create_by!(survey: @survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    @category = @survey.categories.create!(name: "Version Rating Coverage", section: @section)
    @competency_title = "Versioned Competency #{SecureRandom.hex(4)}"
    @question = @category.questions.create!(
      question_text: @competency_title,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5].to_json
    )
  end

  test "returns empty lookup when student ids or competency titles are missing" do
    scope = Survey.where(id: @survey.id)

    assert_equal({}, CompetencySurveyVersionRatings.call(student_ids: [], survey_scope: scope, competency_titles: [ @competency_title ]))
    assert_equal({}, CompetencySurveyVersionRatings.call(student_ids: [ @student.student_id ], survey_scope: scope, competency_titles: []))
  end

  test "uses newest version rating and skips older duplicates for the same competency" do
    SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      event: "submitted",
      answers: { @question.id.to_s => "2" },
      created_at: 2.days.ago
    )
    SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      event: "revised",
      answers: { @question.id.to_s => "4" },
      created_at: 1.day.ago
    )

    result = CompetencySurveyVersionRatings.call(
      student_ids: [ nil, @student.student_id ],
      survey_scope: Survey.where(id: @survey.id),
      competency_titles: [ @competency_title ]
    )

    assert_equal 4.0, result.dig(@student.student_id, @competency_title)
  end

  test "supports legacy offset ids and suffix rating parsing" do
    survey = Survey.new(
      title: "Legacy Offset Survey #{SecureRandom.hex(4)}",
      program_semester: program_semesters(:fall_2025),
      is_active: true
    )
    survey.save!(validate: false)
    section = SurveySection.create!(survey: survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = survey.categories.create!(name: "Legacy Offset Category", section: section)
    competency_title = "Legacy Offset Competency #{SecureRandom.hex(4)}"
    question = category.questions.create!(
      question_text: competency_title,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5].to_json
    )
    second_title = "Second Versioned Competency #{SecureRandom.hex(4)}"
    second_question = category.questions.create!(
      question_text: second_title,
      question_type: "dropdown",
      question_order: 2,
      answer_options: %w[1 2 3 4 5].to_json
    )
    offset = 100_000
    SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: survey.id,
      event: "submitted",
      answers: {
        (question.id - offset).to_s => "Level 5",
        (second_question.id - offset).to_s => "4"
      }
    )

    result = CompetencySurveyVersionRatings.call(
      student_ids: [ @student.student_id ],
      survey_scope: Survey.where(id: survey.id),
      competency_titles: [ competency_title, second_title ]
    )

    assert_equal 5.0, result.dig(@student.student_id, competency_title)
    assert_equal 4.0, result.dig(@student.student_id, second_title)
  end

  test "ignores surveys without matching competency questions or valid ratings" do
    SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      event: "submitted",
      answers: { @question.id.to_s => "not rated" }
    )

    result = CompetencySurveyVersionRatings.call(
      student_ids: [ @student.student_id ],
      survey_scope: Survey.where(id: @survey.id),
      competency_titles: [ @competency_title, "Missing competency" ]
    )

    assert_equal({}, result[@student.student_id])
    assert_equal(
      {},
      CompetencySurveyVersionRatings.call(
        student_ids: [ @student.student_id ],
        survey_scope: Survey.none,
        competency_titles: [ @competency_title ]
      )
    )
  end

  test "private helpers cover blank versions empty questions and exact answer ids" do
    service = CompetencySurveyVersionRatings.new(
      student_ids: [ @student.student_id ],
      survey_scope: Survey.where(id: @survey.id),
      competency_titles: [ @competency_title ]
    )

    assert_equal 0, service.send(:legacy_id_offset, [], { "123" => "4" })
    assert_equal 0, service.send(:legacy_id_offset, [ @question ], {})
    assert_equal 0, service.send(:legacy_id_offset, [ @question ], { @question.id.to_s => "4", "not_numeric" => "5" })
    assert_nil service.send(:normalize_rating, "")
    assert_nil service.send(:normalize_rating, nil)

    fake_version = OpenStruct.new(student_id: @student.student_id, survey_id: @survey.id, answers: {})
    service.stub(:versions, [ fake_version ]) do
      service.stub(:questions_by_survey_id, {}) do
        assert_equal({}, service.call)
      end
    end
  end

  test "competency question filtering requires competency section and dropdown type" do
    service = CompetencySurveyVersionRatings.new(
      student_ids: [ @student.student_id ],
      survey_scope: Survey.where(id: @survey.id),
      competency_titles: [ @competency_title ]
    )
    non_competency_category = @survey.categories.create!(name: "Non Competency")
    non_competency_question = non_competency_category.questions.create!(
      question_text: @competency_title,
      question_type: "dropdown",
      question_order: 30,
      answer_options: %w[1 2 3].to_json
    )
    short_answer = @category.questions.create!(
      question_text: @competency_title,
      question_type: "short_answer",
      question_order: 31
    )

    filtered = service.send(:competency_questions, [ @question, non_competency_question, short_answer ])

    assert_equal [ @question ], filtered
  end
end
