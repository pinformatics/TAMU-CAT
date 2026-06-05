require "test_helper"

class CompositeReportsHelperTest < ActionView::TestCase
  include CompositeReportsHelper

  test "truncate_for_composite_pdf returns unmodified text when within limit" do
    text, truncated = truncate_for_composite_pdf("short", limit: 10)

    assert_equal "short", text
    assert_equal false, truncated
  end

  test "truncate_for_composite_pdf appends suffix when exceeding limit" do
    value = "a" * 10
    text, truncated = truncate_for_composite_pdf(value, limit: 5)

    assert_equal value[0, 5] + CompositeReportsHelper::TRUNCATION_SUFFIX, text
    assert_equal true, truncated
  end

  test "truncate_for_composite_pdf coerces non-string values" do
    text, truncated = truncate_for_composite_pdf(123, limit: 2)

    assert_match(/12.+truncated/i, text)
    assert truncated
  end

  test "composite_answer_parts extracts structured other answers" do
    parts = composite_answer_parts({ "answer" => "Other", "text" => "Custom option" })

    assert_equal "Other", parts[:value]
    assert_equal "Custom option", parts[:text]
  end

  test "composite_answer_parts extracts evidence links" do
    parts = composite_answer_parts({ "link" => "https://example.com", "rating" => 4 })

    assert_equal "https://example.com", parts[:value]
    assert_equal "https://example.com", parts[:link]
    assert_equal 4, parts[:rating]
  end

  test "composite_display_answer prefers structured text" do
    assert_equal "Some details", composite_display_answer({ "answer" => "Other", "text" => "Some details" })
    assert_equal "Yes", composite_display_answer("Yes")
    assert_equal "A, B", composite_display_answer([ "A", "B" ])
    assert_equal "One, Two", composite_display_answer({ value: [ "One", "Two" ], text: "" })
  end

  test "proficiency_option_pairs_for keeps 0 values and falls back to defaults" do
    question_with_zero = Struct.new(:answer_option_pairs).new([ [ "Zero", "0" ], [ "One", "1" ] ])
    pairs = proficiency_option_pairs_for(question_with_zero)
    assert pairs.any? { |(_label, value)| value.to_s == "0" }
    assert pairs.any? { |(_label, value)| value.to_s == "1" }

    pairs = proficiency_option_pairs_for(nil)
    assert_equal DEFAULT_PROFICIENCY_OPTION_PAIRS, pairs
  end

  test "proficiency options insert or append zero when missing" do
    question_with_one = Struct.new(:answer_option_pairs).new([ [ "One", "1" ], [ "Two", "2" ] ])
    inserted = proficiency_option_pairs_for(question_with_one)
    assert_equal [ "Not able to assess (0)", "0" ], inserted.second

    question_without_one = Struct.new(:answer_option_pairs).new([ [ "Two", "2" ], [ "Three", "3" ] ])
    appended = proficiency_option_pairs_for(question_without_one)
    assert_equal [ "Not able to assess (0)", "0" ], appended.last
  end

  test "normalize_proficiency_value normalizes numeric inputs" do
    assert_equal "3", normalize_proficiency_value(3)
    assert_equal "3", normalize_proficiency_value(3.0)
    assert_equal "4", normalize_proficiency_value("4")
    assert_nil normalize_proficiency_value(nil)
    assert_equal "0", normalize_proficiency_value(0)
    assert_nil normalize_proficiency_value(99)
  end
end
