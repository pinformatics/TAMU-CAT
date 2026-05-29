# Shared survey question rules used by submit validation, previews, and progress summaries.
module SurveyQuestionRules
  NUMERIC_SCALE_VALUES = %w[1 2 3 4 5].freeze
  YES_NO_VALUES = %w[yes no].freeze

  module_function

  def branch_parent_ids(questions)
    ordered_questions = Array(questions)
    parent_ids = ordered_questions
      .select { |question| question.respond_to?(:sub_question?) && question.sub_question? }
      .map(&:parent_question_id)
      .compact
      .uniq

    ordered_questions
      .select { |question| parent_ids.include?(question.id) }
      .select { |question| question.respond_to?(:choice_question?) && question.choice_question? && yes_no_options?(question) }
      .map(&:id)
  end

  def branch_parent_target_by_id(questions)
    parents = branch_parent_ids(questions)

    Array(questions).each_with_object({}) do |question, memo|
      next unless parents.include?(question.id)

      memo[question.id] = "Yes"
    end
  end

  def branch_child_parent_id(question, branch_parent_target_by_id:)
    return nil unless question.respond_to?(:sub_question?) && question.sub_question?

    parent_id = question.parent_question_id
    branch_parent_target_by_id.key?(parent_id) ? parent_id : nil
  end

  def branch_child_visible?(question, answers:, branch_parent_target_by_id:)
    parent_id = branch_child_parent_id(question, branch_parent_target_by_id:)
    return true unless parent_id

    target = branch_parent_target_by_id[parent_id].to_s
    normalize_answer_value(answer_for(answers, parent_id)).casecmp?(target)
  end

  def reflection_source_question(question, questions)
    return nil unless reflection_question?(question)

    ordered_questions = Array(questions)
    parent = if question.respond_to?(:parent_question_id) && question.parent_question_id.present?
      ordered_questions.find { |candidate| candidate.id == question.parent_question_id }
    end

    return parent if parent.present? && dropdown_question?(parent)

    reflection_base = question.question_text.to_s.squish.sub(/\s+Reflection\z/i, "").downcase
    ordered_questions.find do |candidate|
      candidate.id != question.id &&
        dropdown_question?(candidate) &&
        candidate.question_text.to_s.squish.downcase == reflection_base
    end
  end

  def reflection_visible?(question, answers:, questions:)
    source_question = reflection_source_question(question, questions)
    return true unless source_question

    normalize_answer_value(answer_for(answers, source_question.id)).present?
  end

  def required_indicator?(question, branch_parent_ids:)
    if branch_child_question?(question, branch_parent_ids:)
      return required_flag?(question)
    end

    base_required?(question)
  end

  def required_for_submission?(question, answers:, branch_parent_ids:)
    if branch_child_question?(question, branch_parent_ids:)
      parent_answer = normalize_answer_value(answer_for(answers, question.parent_question_id))
      return false unless parent_answer.casecmp?("yes")

      return required_flag?(question)
    end

    base_required?(question)
  end

  def blank_required_response?(question, submitted_value)
    if question.choice_question? && submitted_value.is_a?(Hash)
      selected_answer = (submitted_value["answer"] || submitted_value[:answer]).to_s.strip
      return true if selected_answer.blank?

      if question.answer_option_requires_text?(selected_answer)
        return (submitted_value["text"] || submitted_value[:text]).to_s.strip.blank?
      end

      return false
    end

    submitted_value.to_s.strip.blank?
  end

  def answer_for(answers, question_id)
    return nil unless answers.respond_to?(:[])

    answers[question_id] ||
      answers[question_id.to_s] ||
      (answers[question_id.to_sym] if question_id.respond_to?(:to_sym))
  end

  def normalize_answer_value(value)
    case value
    when Hash
      (value["answer"] || value[:answer] || value["text"] || value[:text] || value["value"] || value[:value]).to_s.strip
    else
      value.to_s.strip
    end
  end

  def yes_no_options?(question)
    normalized_option_values(question).sort == YES_NO_VALUES.sort
  end

  def reflection_question?(question)
    question.question_text.to_s.squish.match?(/\s+Reflection\z/i)
  end

  def dropdown_question?(question)
    return question.question_type_dropdown? if question.respond_to?(:question_type_dropdown?)

    question.respond_to?(:question_type) && question.question_type.to_s == "dropdown"
  end

  def branch_child_question?(question, branch_parent_ids:)
    question.respond_to?(:sub_question?) &&
      question.sub_question? &&
      branch_parent_ids.include?(question.parent_question_id)
  end

  def flexibility_scale?(question)
    options = normalized_option_values(question)
    (NUMERIC_SCALE_VALUES - options).empty? &&
      question.question_text.to_s.downcase.include?("flexible")
  end

  def base_required?(question)
    return true if required_flag?(question)
    if question.respond_to?(:question_type) &&
       question.question_type == "dropdown" &&
       question.respond_to?(:category) &&
       question.category&.section&.mha_competency?
      return true
    end

    return false unless question.respond_to?(:choice_question?) && question.choice_question?

    !(yes_no_options?(question) || flexibility_scale?(question))
  end

  def normalized_option_values(question)
    question.answer_option_values.map { |value| value.to_s.strip.downcase }
  end

  def required_flag?(question)
    return question.is_required? if question.respond_to?(:is_required?)
    return question.required? if question.respond_to?(:required?)

    false
  end
end
