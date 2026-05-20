require "test_helper"

class StudentAdvisorAssignmentTest < ActiveSupport::TestCase
  test "records current advisor assignment" do
    student = students(:student)
    StudentAdvisorAssignment.delete_all

    assignment = StudentAdvisorAssignment.record_advisor_change!(
      student: student,
      advisor_id: advisors(:advisor).advisor_id,
      assigned_by: users(:admin),
      starts_on: Date.new(2026, 5, 20)
    )

    assert assignment.current?
    assert_equal student, assignment.student
    assert_equal advisors(:advisor), assignment.advisor
    assert_equal users(:admin), assignment.assigned_by
    assert_equal Date.new(2026, 5, 20), assignment.starts_on
    assert_nil assignment.ends_on
  end

  test "closes previous assignment when advisor changes" do
    student = students(:student)
    StudentAdvisorAssignment.delete_all

    StudentAdvisorAssignment.record_advisor_change!(
      student: student,
      advisor_id: advisors(:advisor).advisor_id,
      starts_on: Date.new(2026, 1, 10)
    )

    StudentAdvisorAssignment.record_advisor_change!(
      student: student,
      advisor_id: advisors(:other_advisor).advisor_id,
      previous_advisor_id: advisors(:advisor).advisor_id,
      assigned_by: users(:admin),
      starts_on: Date.new(2026, 5, 20)
    )

    assignments = student.advisor_assignments.order(:starts_on, :id).to_a
    assert_equal 2, assignments.size
    assert_equal Date.new(2026, 5, 20), assignments.first.ends_on
    assert_equal advisors(:other_advisor), assignments.second.advisor
    assert assignments.second.current?
  end

  test "student advisor update syncs assignment history" do
    student = students(:student)
    StudentAdvisorAssignment.delete_all
    student.advisor_assignment_actor = users(:admin)

    student.update!(advisor: advisors(:other_advisor))

    assignments = student.advisor_assignments.order(:starts_on, :id).to_a
    assert_equal 2, assignments.size
    assert_equal advisors(:advisor), assignments.first.advisor
    assert_not_nil assignments.first.ends_on
    assert_equal advisors(:other_advisor), assignments.second.advisor
    assert_equal users(:admin), assignments.second.assigned_by
    assert assignments.second.current?
  end
end
