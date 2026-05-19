# frozen_string_literal: true

class CompetencySurveyVersionRatings
  def self.call(student_ids:, survey_scope:, competency_titles:)
    new(student_ids:, survey_scope:, competency_titles:).call
  end

  def initialize(student_ids:, survey_scope:, competency_titles:)
    @student_ids = Array(student_ids).compact
    @survey_scope = survey_scope
    @competency_titles = Array(competency_titles)
  end

  def call
    return {} if student_ids.empty? || competency_titles.empty?

    versions.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |version, lookup|
      questions = questions_by_survey_id[version.survey_id].to_a
      next if questions.empty?

      answers = normalized_answers(version.answers)
      id_offset = legacy_id_offset(questions, answers)

      competency_questions(questions).each do |question|
        next if lookup[version.student_id].key?(question.question_text)

        answer = answer_for(question, answers, id_offset)
        rating = normalize_rating(answer)
        lookup[version.student_id][question.question_text] = rating if rating
      end
    end
  end

  private

  attr_reader :student_ids, :survey_scope, :competency_titles

  def versions
    @versions ||= begin
      SurveyResponseVersion
        .where(student_id: student_ids, survey_id: survey_scope.select(:id))
        .order(student_id: :asc, created_at: :desc, survey_id: :desc, id: :desc)
    end
  end

  def questions_by_survey_id
    @questions_by_survey_id ||= begin
      Question
        .joins(:category)
        .where(categories: { survey_id: versions.map(&:survey_id).uniq })
        .includes(category: :survey)
        .order("categories.id ASC, questions.question_order ASC, questions.id ASC")
        .group_by { |question| question.category.survey_id }
    end
  end

  def competency_questions(questions)
    questions.select do |question|
      competency_titles.include?(question.question_text) &&
        question.question_type == "dropdown" &&
        question.category&.section&.mha_competency?
    end
  end

  def normalized_answers(raw_answers)
    raw_answers.to_h.each_with_object({}) do |(key, value), memo|
      memo[key.to_s] = value
    end
  end

  def legacy_id_offset(questions, answers)
    numeric_answer_ids = answers.keys.filter_map { |key| key.match?(/\A\d+\z/) ? key.to_i : nil }
    return 0 if numeric_answer_ids.empty? || questions.empty?
    return 0 if questions.any? { |question| answers.key?(question.id.to_s) }

    question_ids = questions.map(&:id)
    numeric_answer_ids
      .flat_map { |answer_id| question_ids.map { |question_id| question_id - answer_id } }
      .tally
      .max_by { |offset, count| [ count, -offset.abs ] }
      &.first || 0
  end

  def answer_for(question, answers, id_offset)
    answers[question.id.to_s] || answers[(question.id - id_offset).to_s]
  end

  def normalize_rating(value)
    return nil if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    value.to_s[/([0-5])(?:\D*)\z/, 1]&.to_f
  end
end
