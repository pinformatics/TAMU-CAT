require "test_helper"

class DataModelHealthCheckTest < ActiveSupport::TestCase
  test "returns grouped health report" do
    report = DataModelHealthCheck.new.call

    assert report[:generated_at].present?
    assert report[:sections].any? { |section| section.key == :students }
    assert report[:sections].any? { |section| section.key == :advisor_assignments }
    assert report[:sections].any? { |section| section.key == :competency_references }
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

  private

  def find_check(report, key)
    report[:sections].flat_map(&:checks).find { |check| check.key == key }
  end
end
