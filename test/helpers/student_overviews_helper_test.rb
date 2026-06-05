require "test_helper"

class StudentOverviewsHelperTest < ActionView::TestCase
  include StudentOverviewsHelper

  test "score pill classes cover missing no target met and below states" do
    assert_includes competency_comparison_score_pill_classes(nil, 3, "c-score-pill--self"), "c-score-pill--empty"
    assert_includes competency_comparison_score_pill_classes(3, nil, "c-score-pill--course"), "c-score-pill--no-target"
    assert_includes competency_comparison_score_pill_classes(4, 3, "c-score-pill--course"), "c-score-pill--met"
    assert_includes competency_comparison_score_pill_classes(2, 3, "c-score-pill--course"), "c-score-pill--below"
    assert_equal competency_comparison_score_pill_classes(4, 3, "source"), student_overview_score_pill_classes(4, 3, "source")
  end

  test "score status covers missing no target met and below labels" do
    assert_equal "No evidence", student_overview_score_status(nil, 3, missing_label: "No evidence")
    assert_equal "Goal not configured", student_overview_score_status(3, nil, missing_label: "No evidence")
    assert_equal "Meets goal", student_overview_score_status(3, 3, missing_label: "No evidence")
    assert_equal "Below goal", student_overview_score_status(2, 3, missing_label: "No evidence")
  end
end
