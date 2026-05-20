require "test_helper"

class StudentLifecycleTest < ActiveSupport::TestCase
  test "graduate marks student historical without archiving the record" do
    student = students(:student)

    student.graduate!(at: Time.zone.local(2026, 5, 20, 10, 0, 0))

    assert student.graduated?
    assert_equal "graduated", student.status
    assert_not student.archived?
  end

  test "archive hides student from current records while preserving owner and reason" do
    student = students(:student)
    admin = users(:admin)

    student.archive!(archived_by: admin, reason: "Graduated cohort")

    assert student.archived?
    assert_equal admin, student.archived_by
    assert_equal "Graduated cohort", student.archive_reason
    assert_not_includes Student.current_records, student
  end

  test "reactivate clears historical lifecycle metadata" do
    student = students(:student)
    admin = users(:admin)

    student.archive!(archived_by: admin, reason: "Historical test")
    student.reactivate!

    assert student.current_record?
    assert_equal "active", student.status
    assert_nil student.graduated_at
    assert_nil student.archived_at
    assert_nil student.archived_by
    assert_nil student.archive_reason
  end

  test "lifecycle filter keeps current screens active by default and can include history" do
    archived_student = students(:other_student)
    archived_student.archive!(archived_by: users(:admin), reason: "Historical test")

    assert_includes Student.with_lifecycle_filter("current"), students(:student)
    assert_not_includes Student.with_lifecycle_filter("current"), archived_student
    assert_includes Student.with_lifecycle_filter("archived"), archived_student
    assert_includes Student.with_lifecycle_filter("all"), archived_student
  end
end
