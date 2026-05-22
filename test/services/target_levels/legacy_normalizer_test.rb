require "test_helper"

class TargetLevels::LegacyNormalizerTest < ActiveSupport::TestCase
  setup do
    @semester = program_semesters(:fall_2025)
    @competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
  end

  test "copies old second-year program_year targets into class of 2026 records and removes legacy rows" do
    legacy = CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: "Residential",
      program_year: 2,
      class_of: nil,
      competency_title: @competency_title,
      target_level: 4
    )

    result = TargetLevels::LegacyNormalizer.new.call

    assert_equal 1, result.created_count
    assert_equal 1, result.removed_count
    assert_equal 0, result.skipped_count
    refute CompetencyTargetLevel.exists?(legacy.id)

    canonical = CompetencyTargetLevel.find_by!(
      program_semester: @semester,
      track: "Residential",
      program_year: nil,
      class_of: 2026,
      competency_title: @competency_title
    )
    assert_equal 4, canonical.target_level
  end

  test "keeps existing cohort record as authoritative while removing legacy duplicate" do
    canonical = CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: "Residential",
      program_year: nil,
      class_of: 2026,
      competency_title: @competency_title,
      target_level: 5
    )
    legacy = CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: "Residential",
      program_year: 2026,
      class_of: nil,
      competency_title: @competency_title,
      target_level: 3
    )

    result = TargetLevels::LegacyNormalizer.new.call

    assert_equal 0, result.created_count
    assert_equal 1, result.removed_count
    refute CompetencyTargetLevel.exists?(legacy.id)
    assert_equal 5, canonical.reload.target_level
  end

  test "normalizes accidentally inserted old class code records" do
    CompetencyTargetLevel.insert_all!(
      [
        {
          program_semester_id: @semester.id,
          track: "Residential",
          program_year: nil,
          class_of: 1,
          competency_title: @competency_title,
          target_level: 2,
          created_at: Time.current,
          updated_at: Time.current
        }
      ]
    )

    result = TargetLevels::LegacyNormalizer.new.call

    assert_equal 1, result.created_count
    assert_equal 1, result.removed_count
    assert CompetencyTargetLevel.exists?(
      program_semester: @semester,
      track: "Residential",
      class_of: 2027,
      program_year: nil,
      competency_title: @competency_title,
      target_level: 2
    )
    refute CompetencyTargetLevel.exists?(class_of: 1)
  end
end
