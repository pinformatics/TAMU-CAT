require "test_helper"

class SurveyQuestionRulesTest < ActiveSupport::TestCase
  setup do
    @category = categories(:clinical_skills)
  end

  test "detects reusable yes no branch metadata" do
    parent, child = employment_branch_questions

    assert_equal [ parent.id ], SurveyQuestionRules.branch_parent_ids([ parent, child ])
    assert_equal({ parent.id => "Yes" }, SurveyQuestionRules.branch_parent_target_by_id([ parent, child ]))
  end

  test "branch child visibility supports string and integer answer keys" do
    parent, child = employment_branch_questions
    branch_targets = SurveyQuestionRules.branch_parent_target_by_id([ parent, child ])

    assert SurveyQuestionRules.branch_child_visible?(child, answers: { parent.id.to_s => "Yes" }, branch_parent_target_by_id: branch_targets)
    assert SurveyQuestionRules.branch_child_visible?(child, answers: { parent.id => "Yes" }, branch_parent_target_by_id: branch_targets)
    refute SurveyQuestionRules.branch_child_visible?(child, answers: { parent.id => "No" }, branch_parent_target_by_id: branch_targets)
  end

  test "required rules honor manual flags across branch parent and child states" do
    parent, child = employment_branch_questions
    branch_parent_ids = SurveyQuestionRules.branch_parent_ids([ parent, child ])

    refute SurveyQuestionRules.required_indicator?(parent, branch_parent_ids:)
    refute SurveyQuestionRules.required_indicator?(child, branch_parent_ids:)
    refute SurveyQuestionRules.required_for_submission?(parent, answers: {}, branch_parent_ids:)
    refute SurveyQuestionRules.required_for_submission?(child, answers: { parent.id => "Yes" }, branch_parent_ids:)
    refute SurveyQuestionRules.required_for_submission?(child, answers: { parent.id => "No" }, branch_parent_ids:)

    parent.update!(is_required: true)
    child.update!(is_required: true)

    assert SurveyQuestionRules.required_indicator?(parent, branch_parent_ids:)
    assert SurveyQuestionRules.required_indicator?(child, branch_parent_ids:)
    assert SurveyQuestionRules.required_for_submission?(parent, answers: {}, branch_parent_ids:)
    assert SurveyQuestionRules.required_for_submission?(child, answers: { parent.id => "Yes" }, branch_parent_ids:)
    refute SurveyQuestionRules.required_for_submission?(child, answers: { parent.id => "No" }, branch_parent_ids:)
  end

  test "other choice requires companion text when required" do
    question = @category.questions.create!(
      question_text: "How flexible are your work hours?",
      question_order: 997,
      question_type: "multiple_choice",
      answer_options: [
        { label: "Very flexible", value: "5" },
        { label: "Other", value: "Other" }
      ].to_json,
      is_required: true
    )

    assert SurveyQuestionRules.blank_required_response?(question, { "answer" => "Other", "text" => "" })
    refute SurveyQuestionRules.blank_required_response?(question, { "answer" => "Other", "text" => "Rotating schedule" })
    assert SurveyQuestionRules.blank_required_response?(question, { "answer" => "", "text" => "ignored" })
    refute SurveyQuestionRules.blank_required_response?(question, { "answer" => "5", "text" => "" })
  end

  test "answer lookup and dropdown helpers support fallback objects" do
    question_id = "custom_key"
    assert_nil SurveyQuestionRules.answer_for(Object.new, question_id)
    assert_equal "from symbol", SurveyQuestionRules.answer_for({ custom_key: "from symbol" }, question_id)

    dropdown_like = Struct.new(:question_type).new("dropdown")
    text_like = Struct.new(:question_type).new("short_answer")

    assert SurveyQuestionRules.dropdown_question?(dropdown_like)
    refute SurveyQuestionRules.dropdown_question?(text_like)
  end

  test "base required supports competency dropdowns and required fallback objects" do
    section = SurveySection.new(title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = Struct.new(:section).new(section)
    competency_dropdown = Struct.new(:question_type, :category) do
      def answer_option_values = %w[1 2 3 4 5]
      def choice_question? = true
    end.new("dropdown", category)

    required_like = Struct.new(:required_value) do
      def required? = required_value
      def choice_question? = false
    end.new(true)

    optional_like = Struct.new(:required_value) do
      def required? = required_value
      def choice_question? = false
    end.new(false)

    assert SurveyQuestionRules.base_required?(competency_dropdown)
    assert SurveyQuestionRules.required_flag?(required_like)
    refute SurveyQuestionRules.required_flag?(optional_like)
  end

  test "reflection questions are visible only after their assessment has an answer" do
    assessment = @category.questions.create!(
      question_text: "Communication",
      question_order: 998,
      question_type: "dropdown",
      answer_options: [ [ "Beginner (1)", "1" ], [ "Capable (3)", "3" ] ].to_json,
      is_required: true
    )
    reflection = @category.questions.create!(
      question_text: "Communication Reflection",
      question_order: 998,
      question_type: "short_answer",
      parent_question: assessment,
      sub_question_order: 1,
      is_required: false
    )

    questions = [ assessment, reflection ]
    branch_parent_ids = SurveyQuestionRules.branch_parent_ids(questions)

    assert_empty branch_parent_ids
    assert_equal assessment, SurveyQuestionRules.reflection_source_question(reflection, questions)
    assert SurveyQuestionRules.required_indicator?(assessment, branch_parent_ids:)
    refute SurveyQuestionRules.required_indicator?(reflection, branch_parent_ids:)
    refute SurveyQuestionRules.required_for_submission?(reflection, answers: { assessment.id => "1" }, branch_parent_ids:)
    refute SurveyQuestionRules.reflection_visible?(reflection, answers: {}, questions:)
    refute SurveyQuestionRules.reflection_visible?(reflection, answers: { assessment.id => "" }, questions:)
    assert SurveyQuestionRules.reflection_visible?(reflection, answers: { assessment.id => "1" }, questions:)
  end

  private

  def employment_branch_questions
    parent = @category.questions.create!(
      question_text: "Are you currently employed?",
      question_order: 999,
      question_type: "multiple_choice",
      answer_options: %w[Yes No].to_json,
      is_required: false
    )
    child = @category.questions.create!(
      question_text: "If yes, where are you employed?",
      question_order: 999,
      question_type: "short_answer",
      parent_question: parent,
      sub_question_order: 1,
      is_required: false
    )

    [ parent, child ]
  end
end
