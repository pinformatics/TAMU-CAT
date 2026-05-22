require "test_helper"

class TargetLevels::DefaultApplierTest < ActiveSupport::TestCase
  setup do
    @semester = program_semesters(:fall_2025)
  end

  test "fills missing cohort target levels from defaults" do
    result = TargetLevels::DefaultApplier.new(
      program_semester_id: @semester.id,
      track: "Residential",
      class_of: 2026
    ).call

    assert_equal 17, result.created_count
    assert_equal 0, result.skipped_count
    assert_equal 17, CompetencyTargetLevel.where(
      program_semester: @semester,
      track: "Residential",
      class_of: 2026,
      program_year: nil
    ).count
  end

  test "does not overwrite existing cohort target levels" do
    title = Reports::DataAggregator::COMPETENCY_TITLES.first
    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: "Residential",
      class_of: 2026,
      program_year: nil,
      competency_title: title,
      target_level: 5
    )

    result = TargetLevels::DefaultApplier.new(
      program_semester_id: @semester.id,
      track: "Residential",
      class_of: 2026
    ).call

    assert_equal 16, result.created_count
    assert_equal 1, result.skipped_count
    assert_equal 5, CompetencyTargetLevel.find_by!(
      program_semester: @semester,
      track: "Residential",
      class_of: 2026,
      program_year: nil,
      competency_title: title
    ).target_level
  end

  test "raises when no defaults exist for track" do
    error = assert_raises(ArgumentError) do
      TargetLevels::DefaultApplier.new(
        program_semester_id: @semester.id,
        track: "Missing Track",
        class_of: 2026
      ).call
    end

    assert_includes error.message, "No default target levels found"
  end
end
