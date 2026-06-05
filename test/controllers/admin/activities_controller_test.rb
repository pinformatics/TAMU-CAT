require "test_helper"
require "ostruct"

class Admin::ActivitiesControllerTest < ActionController::TestCase
  tests Admin::ActivitiesController
  include Rails.application.routes.url_helpers

  test "private entry builders format fallback submission feedback and admin activity links" do
    controller = @controller
    now = Time.current
    admin = users(:admin)
    student = students(:student)
    advisor = users(:advisor)
    batch = GradeImportBatch.create!(uploaded_by: admin, status: "completed", summary: { "dry_run" => false })

    survey_log = OpenStruct.new(
      survey_title_snapshot: "",
      survey: nil,
      survey_id: 987,
      admin: nil,
      action: "copy_survey",
      description: "",
      created_at: now
    )
    submitted_version = OpenStruct.new(
      survey: nil,
      survey_id: 654,
      student: nil,
      student_id: 321,
      event: "submitted",
      created_at: now - 1.minute
    )
    revised_version = OpenStruct.new(
      survey: surveys(:fall_2025),
      survey_id: surveys(:fall_2025).id,
      student: student,
      student_id: student.student_id,
      event: "revised",
      created_at: now - 2.minutes
    )
    submitted_feedback = OpenStruct.new(
      survey: nil,
      survey_id: 111,
      student: student,
      student_id: student.student_id,
      advisor: advisor,
      advisor_id: advisor.id,
      submitted_at: now - 3.minutes,
      last_saved_at: now - 2.minutes
    )
    draft_feedback = OpenStruct.new(
      survey: surveys(:fall_2025),
      survey_id: surveys(:fall_2025).id,
      student: nil,
      student_id: 123,
      advisor: nil,
      advisor_id: 456,
      submitted_at: nil,
      last_saved_at: now - 4.minutes
    )

    admin_logs = [
      OpenStruct.new(action: "grade_import_action", subject: batch, admin: admin, created_at: now, description: "Committed import"),
      OpenStruct.new(action: "role_update", subject: nil, admin: nil, created_at: now, description: "Role updated"),
      OpenStruct.new(action: "advisor_assignment", subject: nil, admin: admin, created_at: now, description: "Advisor changed"),
      OpenStruct.new(action: "student_lifecycle_update", subject: nil, admin: admin, created_at: now, description: "Graduated")
    ]

    controller.instance_variable_set(:@survey_logs, [ survey_log ])
    controller.instance_variable_set(:@submission_logs, [ submitted_version, revised_version ])
    controller.instance_variable_set(:@feedback_submission_logs, [ submitted_feedback, draft_feedback ])
    controller.instance_variable_set(:@admin_activity_logs, admin_logs)

    entries = controller.send(:build_entries)

    assert entries.any? { |entry| entry[:title] == "Copy Survey: Survey #987" && entry[:actor] == "Admin" }
    assert entries.any? { |entry| entry[:title] == "Submitted: Student #321" && entry[:subtitle] == "Survey #654" }
    assert entries.any? { |entry| entry[:title] == "Revised: #{student.user.name}" && entry[:subtitle] == surveys(:fall_2025).title }
    assert entries.any? { |entry| entry[:title] == "Feedback submitted: #{student.user.name}" }
    assert entries.any? { |entry| entry[:title] == "Feedback changed: #{student.user.name}" }
    assert entries.any? { |entry| entry[:title] == "Feedback changed: Student #123" && entry[:actor] == "Advisor #456" }
    assert_equal admin_grade_import_batch_path(batch), entries.find { |entry| entry[:type] == "Grade Import" }[:link]
    assert entries.any? { |entry| entry[:link] == people_management_path }
    assert entries.any? { |entry| entry[:link] == people_management_path(tab: "students") }

    controller.instance_variable_set(:@search_query, "student #321")
    filtered = controller.send(:filtered_entries, entries)
    assert_equal [ "Submitted: Student #321" ], filtered.map { |entry| entry[:title] }

    controller.instance_variable_set(:@search_query, "")
    assert_equal entries, controller.send(:filtered_entries, entries)
  end
end
