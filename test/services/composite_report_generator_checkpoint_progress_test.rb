require "test_helper"

class CompositeReportGeneratorCheckpointProgressTest < ActiveSupport::TestCase
  setup do
    @student = students(:student)
  end

  test "collects self-assessment scores across Initial/Mid-point/Final checkpoint surveys" do
    build_checkpoint_survey_with_answer(prefix: "RMHA", checkpoint: "Initial", score: 2)
    mid_survey = build_checkpoint_survey_with_answer(prefix: "RMHA", checkpoint: "Mid-point", score: 4)
    build_checkpoint_survey_with_answer(prefix: "RMHA", checkpoint: "Final", score: 5)

    survey_response = SurveyResponse.build(student: @student, survey: mid_survey)
    generator = CompositeReportGenerator.new(survey_response: survey_response, cache: false)

    progress = generator.send(:checkpoint_progress)

    assert_equal [ "Initial", "Mid-point", "Final" ], progress[:checkpoints]
    row = progress[:rows].find { |r| r[:competency] == "Communication" }
    assert_equal({ "Initial" => 2, "Mid-point" => 4, "Final" => 5 }, row[:scores])
  end

  test "returns nil when only one checkpoint has data" do
    survey = build_checkpoint_survey_with_answer(prefix: "RMHA", checkpoint: "Mid-point", score: 4)

    survey_response = SurveyResponse.build(student: @student, survey: survey)
    generator = CompositeReportGenerator.new(survey_response: survey_response, cache: false)

    assert_nil generator.send(:checkpoint_progress)
  end

  test "does not mix EMHA checkpoints into an RMHA student's progress" do
    build_checkpoint_survey_with_answer(prefix: "RMHA", checkpoint: "Initial", score: 2)
    mid_survey = build_checkpoint_survey_with_answer(prefix: "RMHA", checkpoint: "Mid-point", score: 4)
    build_checkpoint_survey_with_answer(prefix: "EMHA", checkpoint: "Final", score: 5)

    survey_response = SurveyResponse.build(student: @student, survey: mid_survey)
    generator = CompositeReportGenerator.new(survey_response: survey_response, cache: false)

    progress = generator.send(:checkpoint_progress)

    assert_equal [ "Initial", "Mid-point" ], progress[:checkpoints]
  end

  private

  def build_checkpoint_survey_with_answer(prefix:, checkpoint:, score:)
    survey = Survey.create!(
      title: "#{prefix} #{checkpoint} Competency Survey #{SecureRandom.hex(4)}",
      program_semester: program_semesters(:fall_2025),
      is_active: true,
      categories_attributes: [
        {
          name: "Management Skills",
          questions_attributes: [
            {
              question_text: "Communication",
              question_order: 1,
              question_type: "dropdown",
              is_required: false,
              answer_options: [
                [ "Foundational (1)", "1" ],
                [ "Developing (2)", "2" ],
                [ "Proficient (3)", "3" ],
                [ "Advanced (4)", "4" ],
                [ "Expert (5)", "5" ]
              ].to_json,
              program_target_level: 3
            }
          ]
        }
      ]
    )
    section = SurveySection.create!(survey: survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE, position: 0)
    survey.categories.first.update!(section: section)
    question = survey.categories.first.questions.first

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: question.id,
      response_value: score.to_s
    )

    survey
  end
end
