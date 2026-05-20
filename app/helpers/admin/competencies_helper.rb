# frozen_string_literal: true

module Admin::CompetenciesHelper
  def competency_matrix_rating(value)
    return "—" if value.nil?

    number_with_precision(value, precision: 1, strip_insignificant_zeros: true)
  end

  def competency_rating_target_class(value, target)
    return "c-score-pill--empty" if value.nil?
    return "c-score-pill--no-target" if target.blank?

    value.to_f >= target.to_f ? "c-score-pill--met" : "c-score-pill--below"
  end

  def competency_rating_target_title(value, target, source: nil)
    source_text = case source&.to_sym
    when :self
      "Self"
    when :advisor
      "Advisor"
    when :course
      "Course"
    else
      "Score"
    end

    return "#{source_text}: no score; target #{competency_matrix_rating(target)}" if value.nil? && target.present?
    return "#{source_text}: no score; target not set" if value.nil?
    return "#{source_text} #{competency_matrix_rating(value)}; target not set" if target.blank?

    status = value.to_f >= target.to_f ? "meets target" : "below target"
    "#{source_text} #{competency_matrix_rating(value)} vs target #{competency_matrix_rating(target)}: #{status}"
  end
end
