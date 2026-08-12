require "test_helper"

class AdvisorMeetingRecapTest < ActiveSupport::TestCase
  setup do
    @student = students(:other_student)
    @advisor = advisors(:other_advisor)
    @program_semester = program_semesters(:fall_2025)
  end

  test "valid with a meeting type and at least one note field" do
    recap = AdvisorMeetingRecap.new(
      student: @student,
      advisor: @advisor,
      program_semester: @program_semester,
      meeting_type: "midpoint",
      academic_advising_notes: "Made good progress."
    )

    assert recap.valid?
  end

  test "invalid without a recognized meeting type" do
    recap = AdvisorMeetingRecap.new(
      student: @student,
      advisor: @advisor,
      program_semester: @program_semester,
      meeting_type: "kickoff",
      general_notes: "Notes"
    )

    assert_not recap.valid?
    assert_includes recap.errors[:meeting_type], "is not included in the list"
  end

  test "invalid when all three note fields are blank" do
    recap = AdvisorMeetingRecap.new(
      student: @student,
      advisor: @advisor,
      program_semester: @program_semester,
      meeting_type: "midpoint"
    )

    assert_not recap.valid?
    assert_includes recap.errors[:base], "Enter notes in at least one field before saving."
  end

  test "enforces one recap per student, semester, and meeting type" do
    existing = advisor_meeting_recaps(:student_initial_fall_2025)

    duplicate = AdvisorMeetingRecap.new(
      student: existing.student,
      advisor: existing.advisor,
      program_semester: existing.program_semester,
      meeting_type: existing.meeting_type,
      general_notes: "Second attempt"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:meeting_type], "has already been taken"

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  test "meeting_type_label returns a friendly label" do
    recap = advisor_meeting_recaps(:student_initial_fall_2025)
    assert_equal "Initial", recap.meeting_type_label
  end
end
