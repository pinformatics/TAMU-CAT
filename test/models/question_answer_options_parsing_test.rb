require "test_helper"

class QuestionAnswerOptionsParsingTest < ActiveSupport::TestCase
  test "answer_option_pairs parses json string arrays" do
    q = Question.new(question_type: "multiple_choice", answer_options: %w[Yes No].to_json)
    assert_equal [ [ "Yes", "Yes" ], [ "No", "No" ] ], q.answer_option_pairs
  end

  test "answer_option_pairs parses json [label,value] pairs" do
    q = Question.new(
      question_type: "dropdown",
      answer_options: [ [ "Beginner (1)", "1" ], [ "Mastery (5)", "5" ] ].to_json
    )
    assert_equal [ [ "Beginner (1)", "1" ], [ "Mastery (5)", "5" ] ], q.answer_option_pairs
  end

  test "answer_option_pairs parses json objects" do
    q = Question.new(
      question_type: "dropdown",
      answer_options: [ { label: "Other — Please describe", value: "0", requires_text: true } ].to_json
    )
    assert_equal [ [ "Other — Please describe", "0" ] ], q.answer_option_pairs
  end

  test "answer_options_list parses newline-separated options" do
    q = Question.new(
      question_type: "multiple_choice",
      answer_options: "Yes\nNo\nMaybe"
    )
    assert_equal [ "Yes", "No", "Maybe" ], q.answer_options_list
    assert_equal [ [ "Yes", "Yes" ], [ "No", "No" ], [ "Maybe", "Maybe" ] ], q.answer_option_pairs
  end

  test "answer_options_list parses comma-separated options" do
    q = Question.new(
      question_type: "multiple_choice",
      answer_options: "Yes, No, Maybe"
    )
    assert_equal [ "Yes", "No", "Maybe" ], q.answer_options_list
  end

  test "answer_option_definitions derives requires_text from explicit keys and 'Other' label" do
    q = Question.new(
      question_type: "multiple_choice",
      answer_options: [
        { label: "Other — Please describe...", value: "0", requires_text: true },
        { label: "Other", value: "1" },
        [ "Other option", "2" ],
        "No"
      ].to_json
    )

    defs = q.answer_option_definitions
    assert_equal true, defs[0][:requires_text]
    assert_equal true, defs[1][:requires_text]
    assert_equal true, defs[2][:requires_text]
    assert_equal false, defs[3][:requires_text]
  end

  test "answer_option_requires_text? uses definitions and falls back to 'other' prefix" do
    q = Question.new(
      question_type: "dropdown",
      answer_options: [
        { label: "Other — Please describe...", value: "0" },
        { label: "Yes", value: "yes" }
      ].to_json
    )

    assert_equal true, q.answer_option_requires_text?("0")
    assert_equal false, q.answer_option_requires_text?("yes")
    assert_equal true, q.answer_option_requires_text?("Other: custom")
    assert_equal false, q.answer_option_requires_text?("")
  end

  test "ensure_question_order and ensure_sub_question_order fill in defaults for sub-questions" do
    survey = surveys(:fall_2025)
    category = Category.create!(name: "Tmp Category #{SecureRandom.hex(3)}", survey: survey)

    parent = Question.create!(
      category: category,
      question_text: "Parent",
      question_type: "dropdown",
      question_order: 1,
      is_required: true
    )

    child = Question.new(
      category: category,
      parent_question: parent,
      question_text: "Child",
      question_type: "dropdown",
      is_required: true
    )
    child.save!

    assert_equal 1, child.question_order
    assert child.sub_question_order.present?
  ensure
    category&.destroy
  end
end
