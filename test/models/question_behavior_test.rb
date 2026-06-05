require "test_helper"

class QuestionBehaviorTest < ActiveSupport::TestCase
  setup do
    @category = categories(:clinical_skills)
  end

  test "answer option parsing supports legacy arrays hashes and fallback text" do
    question = Question.new(category: @category, question_text: "Options", question_type: "dropdown")
    assert_equal [], question.answer_options_list
    assert_equal [], question.answer_option_pairs
    assert_equal [], question.answer_option_definitions
    refute question.answer_option_requires_text?("")

    question.answer_options = [ " Yes ", [ "No label", "no" ], { label: "Other detail", value: "other_detail", requires_text: true }, { value: "Value Only" }, nil ].to_json

    assert_equal [ "Yes", "No label", "Other detail", "Value Only", "" ], question.answer_options_list
    assert_includes question.answer_option_pairs, [ "No label", "no" ]
    assert_includes question.answer_option_pairs, [ "Other detail", "other_detail" ]
    assert question.answer_option_requires_text?("other_detail")
    assert question.answer_option_requires_text?("Other custom")
    refute question.answer_option_requires_text?("Yes")

    question.answer_options = "Alpha, Beta\nOther write-in"
    assert_equal [ "Alpha", "Beta", "Other write-in" ], question.answer_options_list
    assert_equal [ [ "Alpha", "Alpha" ], [ "Beta", "Beta" ], [ "Other write-in", "Other write-in" ] ], question.answer_option_pairs
    assert question.answer_option_definitions.last[:requires_text]
  end

  test "question order sub question order prompt and integer helpers use fallbacks" do
    parent = @category.questions.create!(
      question_text: "Parent <strong>prompt</strong>",
      question_type: "multiple_choice",
      question_order: 45,
      answer_options: %w[Yes No].to_json
    )
    child = @category.questions.build(
      question_text: "Child",
      question_type: "short_answer",
      parent_question: parent
    )
    child.sub_question_order = nil
    child.save!
    standalone = @category.questions.create!(
      question_text: "Standalone",
      question_type: "short_answer"
    )
    invalid_integer = @category.questions.build(
      question_text: "Bad integer",
      question_type: "integer",
      integer_min: 10,
      integer_max: 5
    )

    assert_equal parent.question_order, child.question_order
    assert child.sub_question_order.positive?
    assert child.sub_question?
    refute parent.sub_question?
    assert standalone.question_order.present?
    assert parent.rich_text_prompt?
    assert_equal "plain_text", parent.effective_prompt_format
    parent.prompt_format = "rich_text"
    assert parent.rich_text_prompt?
    assert_equal 1, Question.new(question_type: "integer").integer_min_value
    assert_nil Question.new(question_type: "integer").integer_max_value
    refute invalid_integer.valid?
    assert_includes invalid_integer.errors[:integer_max], "must be greater than or equal to minimum"
  end

  test "answer option definitions honor explicit text flags and skip blank pairs" do
    question = Question.new(category: @category, question_text: "Flexible", question_type: "dropdown")
    question.answer_options = [
      [ "Blank value", "" ],
      { label: "", value: "blank_label" },
      { label: "Other false", value: "other_false", requires_text: false },
      { label: "Other text flag", value: "other_text", other_text: true },
      { label: "Other flag", value: "other_flag", other: true },
      { label: "Plain", value: "plain" }
    ].to_json

    definitions = question.answer_option_definitions

    assert_equal %w[other_false other_text other_flag plain], definitions.map { |definition| definition[:value] }
    refute definitions.find { |definition| definition[:value] == "other_false" }[:requires_text]
    assert definitions.find { |definition| definition[:value] == "other_text" }[:requires_text]
    assert definitions.find { |definition| definition[:value] == "other_flag" }[:requires_text]
    refute question.answer_option_requires_text?("plain")
  end

  test "answer option parsers skip incomplete array entries and blank hash values" do
    question = Question.new(category: @category, question_text: "Malformed options", question_type: "dropdown")
    question.answer_options = [
      [ "Only label" ],
      [ "Blank label", "" ],
      [ "", "blank_value" ],
      { label: "", value: "blank_label" },
      { label: "Blank hash value", value: "" },
      { label: "Valid", value: "valid" }
    ].to_json

    assert_equal [ [ "Valid", "valid" ] ], question.answer_option_pairs
    assert_equal [ { label: "Valid", value: "valid", requires_text: false } ], question.answer_option_definitions
  end

  test "question scopes and sub question helpers support normal column-backed paths" do
    parent = @category.questions.create!(
      question_text: "Scope Parent",
      question_type: "multiple_choice",
      question_order: 80,
      answer_options: %w[Yes No].to_json
    )
    child = @category.questions.create!(
      question_text: "Scope Child",
      question_type: "short_answer",
      parent_question: parent,
      sub_question_order: 1
    )

    assert_includes Question.parent_questions, parent
    refute_includes Question.parent_questions, child
    assert_includes Question.sub_questions_only, child
    refute_includes Question.sub_questions_only, parent

    no_parent_attribute = Question.new
    no_parent_attribute.stub(:has_attribute?, false) do
      refute no_parent_attribute.sub_question?
    end
  end

  test "sub question column support returns false when table is unavailable" do
    connection = Struct.new(:exists_value) do
      def data_source_exists?(_table_name) = exists_value
      def column_exists?(_table_name, _column_name) = true
    end

    Question.stub(:connection, connection.new(false)) do
      refute Question.sub_question_columns_supported?
    end
  end

  test "rich text and integer helpers cover configured and plain branches" do
    plain = Question.new(question_text: "Plain prompt", question_type: "short_answer")
    rich = Question.new(question_text: "Prompt with <strong>allowed</strong> tag", question_type: "short_answer")
    configured_plain = Question.new(question_text: "<strong>literal</strong>", question_type: "short_answer", prompt_format: "plain_text")
    integer = Question.new(question_text: "Integer", question_type: "integer", integer_min: "0", integer_max: "10")

    refute plain.rich_text_prompt?
    assert rich.rich_text_prompt?
    refute configured_plain.rich_text_prompt?
    assert_equal "plain_text", configured_plain.effective_prompt_format
    assert_equal 0, integer.integer_min_value
    assert_equal 10, integer.integer_max_value
  end
end
