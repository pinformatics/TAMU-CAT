require "test_helper"

class Admin::SurveysHelperTest < ActionView::TestCase
  include Admin::SurveysHelper

  test "status meta and datetime cover active archived present and fallback states" do
    active_label, active_classes = admin_survey_status_meta(surveys(:fall_2025))
    assert_equal "Active", active_label
    assert_includes active_classes, "emerald"

    archived = surveys(:spring_2025)
    archived.update_column(:is_active, false)
    archived_label, archived_classes = admin_survey_status_meta(archived)
    assert_equal "Archived", archived_label
    assert_includes archived_classes, "amber"

    time = Time.zone.local(2026, 6, 2, 9, 30)
    assert_match "2026", admin_survey_datetime(time)
    assert_equal "Not set", admin_survey_datetime(nil, fallback: "Not set")
  ensure
    archived&.update_column(:is_active, true)
  end

  test "resolved builder target level returns explicit when question or survey context is missing" do
    question = Question.new(question_text: "Example", program_target_level: 4)

    assert_equal 4, resolved_builder_target_level(question: question, survey: nil)
    assert_nil resolved_builder_target_level(question: nil, survey: surveys(:fall_2025))

    blank_title = Question.new(question_text: " ", program_target_level: 3)
    assert_equal 3, resolved_builder_target_level(question: blank_title, survey: surveys(:fall_2025))
  end

  test "resolved builder target level uses configured exact fallback and any-year records" do
    survey = surveys(:fall_2025)
    title = Reports::DataAggregator::COMPETENCY_TITLES.first
    question = Question.new(question_text: title, program_target_level: 2)

    SurveyTrackAssignment.find_or_create_by!(survey: survey, track: "Residential")
    CompetencyTargetLevel.where(program_semester: survey.program_semester, track: "Residential", competency_title: title).delete_all

    CompetencyTargetLevel.create!(
      program_semester: survey.program_semester,
      track: "Residential",
      class_of: nil,
      competency_title: title,
      target_level: 3
    )
    assert_equal 3, resolved_builder_target_level(question: question, survey: survey)

    CompetencyTargetLevel.create!(
      program_semester: survey.program_semester,
      track: "Residential",
      class_of: 2026,
      competency_title: title,
      target_level: 5
    )
    survey.offerings.create!(track: "Residential", class_of: 2026, stage: "initial")
    remove_instance_variable(:@_admin_competency_target_level_lookup) if defined?(@_admin_competency_target_level_lookup)

    assert_equal 5, resolved_builder_target_level(question: question, survey: survey)

    survey_without_class = surveys(:spring_2026_residential)
    SurveyTrackAssignment.find_or_create_by!(survey: survey_without_class, track: "Residential")
    CompetencyTargetLevel.create!(
      program_semester: survey_without_class.program_semester,
      track: "Residential",
      class_of: 2027,
      competency_title: title,
      target_level: 4
    )
    remove_instance_variable(:@_admin_competency_target_level_lookup) if defined?(@_admin_competency_target_level_lookup)

    assert_equal 4, resolved_builder_target_level(question: question, survey: survey_without_class)
  end
end
