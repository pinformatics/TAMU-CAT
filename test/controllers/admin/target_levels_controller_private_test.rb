require "test_helper"

class Admin::TargetLevelsControllerPrivateTest < ActionController::TestCase
  tests Admin::TargetLevelsController

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in users(:admin)
    @semester = program_semesters(:fall_2025)
    @source_semester = program_semesters(:spring_2026)
    @track = "Residential"
    @class_of = 2026
    @title = Reports::DataAggregator::COMPETENCY_TITLES.first
    @second_title = Reports::DataAggregator::COMPETENCY_TITLES.second
  end

  test "load selector options normalizes present and blank params" do
    @controller.params = ActionController::Parameters.new(
      program_semester_id: @semester.id.to_s,
      track: @track,
      class_of: " #{@class_of} "
    )

    @controller.send(:load_selector_options)

    assert_includes @controller.instance_variable_get(:@semesters), @semester
    assert_includes @controller.instance_variable_get(:@tracks), @track
    assert_equal @semester.id, @controller.instance_variable_get(:@selected_semester_id)
    assert_equal @track, @controller.instance_variable_get(:@selected_track)
    assert_equal @class_of, @controller.instance_variable_get(:@selected_class_of)

    @controller.params = ActionController::Parameters.new(program_semester_id: "", track: "", class_of: "")
    @controller.send(:load_selector_options)

    assert_nil @controller.instance_variable_get(:@selected_semester_id)
    assert_nil @controller.instance_variable_get(:@selected_track)
    assert_nil @controller.instance_variable_get(:@selected_class_of)
  end

  test "load targets returns empty state until all selectors are present" do
    @controller.instance_variable_set(:@selected_semester_id, @semester.id)
    @controller.instance_variable_set(:@selected_track, nil)
    @controller.instance_variable_set(:@selected_class_of, @class_of)

    @controller.send(:load_targets)

    assert_equal [], @controller.instance_variable_get(:@competencies)
    assert_equal({}, @controller.instance_variable_get(:@targets_by_title))
  end

  test "load targets prefers exact records and falls back to legacy target records" do
    CompetencyTargetLevel.where(program_semester: @semester, track: @track, competency_title: [ @title, @second_title ]).delete_all
    exact = CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @track,
      class_of: @class_of,
      competency_title: @title,
      target_level: 5
    )
    legacy = CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @track,
      class_of: nil,
      program_year: 2,
      competency_title: @second_title,
      target_level: 3
    )

    @controller.instance_variable_set(:@selected_semester_id, @semester.id)
    @controller.instance_variable_set(:@selected_track, @track)
    @controller.instance_variable_set(:@selected_class_of, @class_of)
    @controller.send(:load_targets)

    targets = @controller.instance_variable_get(:@targets_by_title)
    assert_equal exact.target_level, targets[@title]
    assert_equal legacy.target_level, targets[@second_title]
  end

  test "submitted students count handles blank context class filters and matches" do
    assert_equal 0, @controller.send(:submitted_students_count_for_context, semester_id: nil, track: @track, class_of: @class_of)
    assert_equal 0, @controller.send(:submitted_students_count_for_context, semester_id: @semester.id, track: nil, class_of: @class_of)

    survey_assignments(:completed_residential_assignment).update!(
      survey: surveys(:fall_2025),
      student: students(:completed_student),
      completed_at: 1.day.ago
    )

    assert_equal 1, @controller.send(:submitted_students_count_for_context, semester_id: @semester.id, track: @track, class_of: @class_of)
    assert_equal 1, @controller.send(:submitted_students_count_for_context, semester_id: @semester.id, track: @track, class_of: nil)
    assert_equal 0, @controller.send(:submitted_students_count_for_context, semester_id: @semester.id, track: @track, class_of: 2027)
  end

  test "copy source target records use exact records first then legacy fallbacks" do
    CompetencyTargetLevel.where(program_semester: @source_semester, track: @track, competency_title: [ @title, @second_title ]).delete_all
    exact = CompetencyTargetLevel.create!(
      program_semester: @source_semester,
      track: @track,
      class_of: @class_of,
      competency_title: @title,
      target_level: 4
    )
    CompetencyTargetLevel.insert_all!(
      [
        {
          program_semester_id: @source_semester.id,
          track: @track,
          class_of: 2,
          program_year: nil,
          competency_title: @second_title,
          target_level: 2,
          created_at: Time.current,
          updated_at: Time.current
        }
      ]
    )
    legacy = CompetencyTargetLevel.find_by!(
      program_semester: @source_semester,
      track: @track,
      class_of: 2,
      program_year: nil,
      competency_title: @second_title
    )
    CompetencyTargetLevel.create!(
      program_semester: @source_semester,
      track: @track,
      class_of: @class_of,
      competency_title: Reports::DataAggregator::COMPETENCY_TITLES.third,
      target_level: 5
    )

    @controller.instance_variable_set(:@selected_semester_id, @source_semester.id)
    @controller.instance_variable_set(:@selected_track, @track)
    @controller.instance_variable_set(:@selected_class_of, @class_of)

    records = @controller.send(:copy_source_target_records)

    assert_includes records, exact
    assert_includes records, legacy
    assert_equal [ @title, @second_title, Reports::DataAggregator::COMPETENCY_TITLES.third ], records.first(3).map(&:competency_title)
  end

  test "copy target records counts changed and unchanged targets" do
    current_semester = @semester
    CompetencyTargetLevel.where(program_semester: current_semester, track: @track, class_of: @class_of, competency_title: [ @title, @second_title ]).delete_all
    unchanged_source = CompetencyTargetLevel.create!(
      program_semester: @source_semester,
      track: @track,
      class_of: @class_of,
      competency_title: @title,
      target_level: 4
    )
    changed_source = CompetencyTargetLevel.create!(
      program_semester: @source_semester,
      track: @track,
      class_of: @class_of,
      competency_title: @second_title,
      target_level: 3
    )
    CompetencyTargetLevel.create!(
      program_semester: current_semester,
      track: @track,
      class_of: @class_of,
      competency_title: @title,
      target_level: 4
    )

    @controller.instance_variable_set(:@selected_track, @track)
    @controller.instance_variable_set(:@selected_class_of, @class_of)

    result = @controller.send(:copy_target_records_to_current!, [ unchanged_source, changed_source ], current_semester)

    assert_equal({ changed: 1, unchanged: 1 }, result)
    assert_equal 3, CompetencyTargetLevel.find_by!(
      program_semester: current_semester,
      track: @track,
      class_of: @class_of,
      competency_title: @second_title
    ).target_level
  end

  test "legacy cohort helpers cover modern mapped and unmapped years" do
    assert_equal [ 2026, 2 ], @controller.send(:legacy_program_year_candidates, 2026)
    assert_equal [ 2027, 1 ], @controller.send(:legacy_program_year_candidates, 2027)
    assert_equal [ 2028 ], @controller.send(:legacy_program_year_candidates, 2028)

    assert_equal [ 2 ], @controller.send(:legacy_class_of_candidates, 2026)
    assert_equal [ 1 ], @controller.send(:legacy_class_of_candidates, 2027)
    assert_equal [], @controller.send(:legacy_class_of_candidates, 2028)

    assert_match "CASE program_year", @controller.send(:legacy_program_year_order_sql, 2026)
    assert_equal "program_year = 2028 DESC", @controller.send(:legacy_program_year_order_sql, 2028)
  end

  test "selected context path preserves current target selectors" do
    @controller.instance_variable_set(:@selected_semester_id, @semester.id)
    @controller.instance_variable_set(:@selected_track, @track)
    @controller.instance_variable_set(:@selected_class_of, @class_of)

    assert_equal(
      admin_program_setup_path(tab: "targets", program_semester_id: @semester.id, track: @track, class_of: @class_of),
      @controller.send(:selected_context_path)
    )
  end
end
