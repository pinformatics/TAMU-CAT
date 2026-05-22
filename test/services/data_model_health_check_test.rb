require "test_helper"

class DataModelHealthCheckTest < ActiveSupport::TestCase
  test "returns grouped health report" do
    report = DataModelHealthCheck.new.call

    assert report[:generated_at].present?
    assert report[:sections].any? { |section| section.key == :students }
    assert report[:sections].any? { |section| section.key == :advisor_assignments }
    assert report[:sections].any? { |section| section.key == :competency_references }
    assert report[:sections].any? { |section| section.key == :target_level_consistency }
    assert report[:sections].any? { |section| section.key == :course_references }
    assert_operator report[:issue_count], :>=, 0
  end

  test "flags current students without advisors" do
    student = students(:student)
    student.update!(advisor: nil)

    report = DataModelHealthCheck.new.call
    check = find_check(report, :current_without_advisor)

    assert_operator check.count, :>=, 1
    assert_equal :warning, check.severity
  end

  test "flags competency source rows without canonical competency links" do
    CompetencyTargetLevel.create!(
      competency_title: "Not A Real Competency",
      target_level: 3,
      track: "Residential",
      program_year: 2026,
      program_semester: program_semesters(:fall_2025)
    )

    report = DataModelHealthCheck.new.call
    check = find_check(report, :target_levels_missing_competency)

    assert_operator check.count, :>=, 1
    assert_equal :critical, check.severity
  end

  test "flags legacy target level cohort storage" do
    CompetencyTargetLevel.create!(
      competency_title: Reports::DataAggregator::COMPETENCY_TITLES.first,
      target_level: 3,
      track: "Residential",
      program_year: 2,
      program_semester: program_semesters(:fall_2025)
    )

    CompetencyTargetLevel.insert_all!(
      [
        {
          competency_title: Reports::DataAggregator::COMPETENCY_TITLES.second,
          target_level: 4,
          track: "Residential",
          class_of: 2,
          program_semester_id: program_semesters(:fall_2025).id,
          created_at: Time.current,
          updated_at: Time.current
        }
      ]
    )

    report = DataModelHealthCheck.new.call

    legacy_check = find_check(report, :target_levels_using_legacy_program_year)
    old_class_check = find_check(report, :target_levels_using_old_class_codes)

    assert_operator legacy_check.count, :>=, 1
    assert_equal :warning, legacy_check.severity
    assert_operator old_class_check.count, :>=, 1
    assert_equal :warning, old_class_check.severity
  end

  private

  def find_check(report, key)
    report[:sections].flat_map(&:checks).find { |check| check.key == key }
  end
end
