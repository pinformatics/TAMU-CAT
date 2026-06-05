require "test_helper"

class CourseCompetencyTargetTest < ActiveSupport::TestCase
  test "requires one target level per course offering and competency" do
    semester = program_semesters(:fall_2025)
    offering = CourseOffering.find_or_create_from_code!("PHPM-633-700", program_semester: semester)
    competency = create_competency!("Configured Course Target")

    target = CourseCompetencyTarget.create!(
      course_offering: offering,
      competency: competency,
      target_level: 4
    )

    assert_equal "PHPM-633-700", target.course_code
    assert_equal competency.title, target.competency_title
    assert_equal semester.name, target.semester_name

    duplicate = CourseCompetencyTarget.new(
      course_offering: offering,
      competency: competency,
      target_level: 5
    )

    refute duplicate.valid?
    assert_includes duplicate.errors[:competency_id], "has already been taken"
  end

  test "validates target level range" do
    offering = CourseOffering.find_or_create_from_code!("PHPM-634-700", program_semester: program_semesters(:fall_2025))
    competency = create_competency!("Configured Course Target Range")

    [ nil, 0, 6 ].each do |level|
      target = CourseCompetencyTarget.new(
        course_offering: offering,
        competency: competency,
        target_level: level
      )

      refute target.valid?, "Expected #{level.inspect} to be invalid"
    end
  end

  test "display helpers return nil when associations are missing" do
    target = CourseCompetencyTarget.new

    assert_nil target.course_code
    assert_nil target.course_title
    assert_nil target.course_name
    assert_nil target.competency_title
    assert_nil target.semester_name
  end

  test "schema is folded into the v6 foundation migration" do
    assert ActiveRecord::Base.connection.table_exists?(:course_competency_targets)
    refute File.exist?(Rails.root.join("db/migrate/20260602103000_create_course_competency_targets.rb"))

    migration = Rails.root.join("db/migrate/20260520160000_add_phase_two_data_model_foundations.rb").read
    assert_includes migration, "def create_course_competency_targets"
    assert_includes migration, "create_table :course_competency_targets"
  end

  private

  def create_competency!(title)
    domain = Domain.find_or_create_by!(name: "Course Target Test Domain") do |record|
      record.position = 200
    end

    Competency.find_or_create_by!(title: title) do |record|
      record.domain = domain
      record.position = 200
    end
  end
end
