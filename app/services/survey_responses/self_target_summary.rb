# frozen_string_literal: true

module SurveyResponses
  class SelfTargetSummary
    include CompetencyTargetLevelsHelper

    COMPLETED_VERSION_EVENTS = %w[submitted revised admin_edited].freeze

    def self.build(survey_response:)
      new(survey_response:).build
    end

    def self.completed_version_event?(event)
      COMPLETED_VERSION_EVENTS.include?(event.to_s)
    end

    def initialize(survey_response:)
      @survey_response = survey_response
      @survey = survey_response&.survey
      @student = survey_response&.student
    end

    def build
      rows = summary_rows

      comparable_rows = rows.select { |row| row[:status].in?(%i[met below_target]) }
      met_count = rows.count { |row| row[:status] == :met }
      below_count = rows.count { |row| row[:status] == :below_target }
      missing_self_count = rows.count { |row| row[:status] == :not_rated }
      missing_target_count = rows.count { |row| row[:status] == :no_target }

      {
        rows: rows,
        total_count: rows.size,
        comparable_count: comparable_rows.size,
        met_count: met_count,
        below_count: below_count,
        missing_self_count: missing_self_count,
        missing_target_count: missing_target_count,
        met_rate: comparable_rows.any? ? ((met_count.to_f / comparable_rows.size) * 100).round(1) : nil
      }
    end

    private

    attr_reader :survey_response, :survey, :student

    def summary_rows
      return [] unless survey_response && survey && student

      competency_questions.filter_map do |question|
        competency_title = competency_title_for(question)
        next if competency_title.blank?

        target_level = normalized_level(
          effective_competency_target_level(question:, survey:, student:)
        )
        self_rating = normalized_self_rating(SurveyQuestionRules.answer_for(survey_response.answers, question.id))

        {
          domain: question.category&.name.to_s.strip.presence || "Unassigned domain",
          competency: competency_title,
          self_rating: self_rating,
          target_level: target_level,
          status: target_status(self_rating, target_level),
          status_label: target_status_label(self_rating, target_level)
        }
      end
    end

    def competency_questions
      Category
        .where(survey_id: survey.id)
        .includes(:section, :questions)
        .order(:id)
        .flat_map { |category| category.questions.ordered.to_a }
        .select { |question| question.question_type_dropdown? }
    end

    def competency_title_for(question)
      raw_title = question&.question_text.to_s.strip
      return nil if raw_title.blank?
      return raw_title if Reports::DataAggregator::COMPETENCY_TITLES.include?(raw_title)

      competency = Competency.find_by_normalized_title(raw_title) if defined?(Competency)
      competency&.title
    end

    def normalized_self_rating(value)
      normalized = SurveyQuestionRules.normalize_answer_value(value)
      return nil if normalized.blank?

      explicit = normalized.match(/\A([1-5])(?:\.0+)?\z/)
      return explicit[1].to_i if explicit

      parenthetical = normalized.match(/\(([1-5])\)/)
      return parenthetical[1].to_i if parenthetical

      embedded = normalized.match(/\b([1-5])\b/)
      embedded ? embedded[1].to_i : nil
    end

    def normalized_level(value)
      numeric = Float(value)
      return nil unless numeric.between?(1, 5)

      numeric.to_i
    rescue ArgumentError, TypeError
      nil
    end

    def target_status(self_rating, target_level)
      return :no_target if target_level.blank?
      return :not_rated if self_rating.blank?

      self_rating >= target_level ? :met : :below_target
    end

    def target_status_label(self_rating, target_level)
      case target_status(self_rating, target_level)
      when :met
        "Target met"
      when :below_target
        "Below target"
      when :no_target
        "Target not set"
      else
        "No self-rating"
      end
    end
  end
end
