# frozen_string_literal: true

module StudentOverviewsHelper
  def competency_comparison_score_pill_classes(value, target, source_class)
    classes = [ "c-score-pill", source_class ]

    if value.blank?
      classes << "c-score-pill--empty"
    elsif target.blank?
      classes << "c-score-pill--no-target"
    elsif value.to_f >= target.to_f
      classes << "c-score-pill--met"
    else
      classes << "c-score-pill--below"
    end

    classes.join(" ")
  end
  alias_method :student_overview_score_pill_classes, :competency_comparison_score_pill_classes

  def student_overview_score_status(value, target, missing_label:)
    return missing_label if value.blank?
    return "Goal not configured" if target.blank?

    value.to_f >= target.to_f ? "Meets goal" : "Below goal"
  end
end
