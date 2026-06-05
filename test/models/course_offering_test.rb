require "test_helper"

class CourseOfferingTest < ActiveSupport::TestCase
  test "parses department course and section from source code" do
    parsed = CourseOffering.parse_source_code("PHPM-633-700")

    assert_equal "PHPM", parsed[:department_code]
    assert_equal "633", parsed[:course_number]
    assert_equal "700", parsed[:section_number]
    assert_equal "PHPM-633-700", parsed[:source_code]
    assert_nil CourseOffering.parse_source_code("not-a-course")
  end

  test "finds or creates normalized catalog and offering records" do
    offering = CourseOffering.find_or_create_from_code!(
      "PHPM_633_700",
      program_semester: program_semesters(:spring_2026),
      source_name: "Outcomes-26_SPRING_PHPM_633_700__HEALTH_LAW__ETHICS.csv"
    )

    assert_equal "PHPM-633-700", offering.source_code
    assert_equal "PHPM-633-700", offering.course_code
    assert_equal "700", offering.section_number
    assert_equal "633", offering.course.number
    assert_equal "PHPM", offering.course.department.code
    assert_equal "Public Hlth Pol & Mgmt", offering.course.department.name
    assert_equal "Health Law and Ethics", offering.course.title
    assert_includes offering.display_name, "PHPM-633-700"
    refute offering.archived?
  end

  test "derives source code title fallback and archived state" do
    offering = CourseOffering.find_or_create_from_code!(
      "ABCD 123 001",
      program_semester: program_semesters(:fall_2025),
      source_name: "Outcomes-ABCD_123_001__SPECIAL_TOPICS.csv"
    )

    assert_equal "ABCD", offering.course.department.name
    assert_equal "Special Topics", offering.course.title
    assert_equal "ABCD-123-001", offering.display_code

    offering.update!(archived_at: Time.current)
    assert offering.archived?

    course = offering.course
    manual = CourseOffering.create!(course: course, section_number: " 002 ")
    assert_equal "002", manual.section_number
    assert_equal "#{course.catalog_code}-002", manual.source_code
  end

  test "display helpers tolerate blank source code section and course" do
    department = Department.create!(code: "TEST#{SecureRandom.hex(2).upcase}", name: "Test Department")
    course = Course.create!(department: department, number: "701", title: "Test Course")
    offering = CourseOffering.new(course: course, source_code: "", section_number: "")

    assert_equal course.catalog_code, offering.display_code
    assert_equal [ course.catalog_code, course.title ].compact_blank.join(" "), offering.display_name

    blank = CourseOffering.new(course: nil, source_code: "", section_number: "")
    assert_equal "", blank.display_code
    assert_equal "", blank.display_name
    assert_equal "", blank.course_code
  end

  test "source code parser and title extraction handle missing pieces" do
    parsed = CourseOffering.parse_source_code("PHPM633")

    assert_equal "PHPM-633", parsed[:source_code]
    assert_nil parsed[:section_number]
    assert_nil CourseOffering.title_from_source_name(parsed, "")
    assert_nil CourseOffering.title_from_source_name(parsed, "Outcomes-PHPM_633.csv")
  end
end
