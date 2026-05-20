require "test_helper"

class CourseOfferingTest < ActiveSupport::TestCase
  test "parses department course and section from source code" do
    parsed = CourseOffering.parse_source_code("PHPM-633-700")

    assert_equal "PHPM", parsed[:department_code]
    assert_equal "633", parsed[:course_number]
    assert_equal "700", parsed[:section_number]
    assert_equal "PHPM-633-700", parsed[:source_code]
  end

  test "finds or creates normalized catalog and offering records" do
    offering = CourseOffering.find_or_create_from_code!(
      "PHPM_633_700",
      program_semester: program_semesters(:spring_2026),
      source_name: "Outcomes-26_SPRING_PHPM_633_700__HEALTH_LAW__ETHICS.csv"
    )

    assert_equal "PHPM-633-700", offering.source_code
    assert_equal "700", offering.section_number
    assert_equal "633", offering.course.number
    assert_equal "PHPM", offering.course.department.code
    assert_equal "Public Hlth Pol & Mgmt", offering.course.department.name
    assert_equal "Health Law and Ethics", offering.course.title
  end
end
