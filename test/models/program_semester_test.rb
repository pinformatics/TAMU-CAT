require "test_helper"

class ProgramSemesterTest < ActiveSupport::TestCase
  test "ordered follows academic calendar order instead of creation order" do
    fall_2031 = ProgramSemester.create!(name: "Fall 2031", created_at: 4.days.ago, updated_at: 4.days.ago)
    spring_2031 = ProgramSemester.create!(name: "Spring 2031", created_at: 1.day.ago, updated_at: 1.day.ago)
    fall_2030 = ProgramSemester.create!(name: "Fall 2030", created_at: Time.current, updated_at: Time.current)
    spring_2032 = ProgramSemester.create!(name: "Spring 2032", created_at: 2.days.ago, updated_at: 2.days.ago)

    ordered = ProgramSemester.where(id: [ fall_2031, spring_2031, fall_2030, spring_2032 ].map(&:id)).ordered.to_a

    assert_equal [ fall_2030, spring_2031, fall_2031, spring_2032 ], ordered
  end

  test "derives dates from standard semester names" do
    semester = ProgramSemester.create!(name: "Spring 2030")

    assert_equal Date.new(2030, 1, 1), semester.starts_on
    assert_equal Date.new(2030, 4, 30), semester.ends_on
  end
end
