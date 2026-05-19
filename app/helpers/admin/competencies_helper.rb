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

  def competency_rating_target_title(competency_title, target, source: nil)
    target_text = target.present? ? competency_matrix_rating(target) : "not configured"
    source_text = case source&.to_sym
    when :self
      "Self score from student survey responses"
    when :advisor
      "Advisor score from advisor feedback on surveys"
    when :course
      "Course score from imported course competency data"
    else
      "Score"
    end

    "#{source_text}. Program target for #{competency_title}: #{target_text}"
  end
end
