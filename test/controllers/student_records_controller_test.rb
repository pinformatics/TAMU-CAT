require "test_helper"

class StudentRecordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
  end

  test "admin can see all students and feedback summaries" do
    sign_in @admin

    get student_records_path
    assert_response :success
    assert_includes response.body, "Student Records"
    assert_match(/Completion.*Feedback.*Advisor Feedback.*Actions/m, response.body)
    assert_not_includes response.body, "Course Competencies"
    assert_includes response.body, users(:student).name
    assert_includes response.body, users(:other_student).name
    assert_includes response.body, students(:student).program_year.to_s
    assert_includes response.body, "Submitted"
  end

  test "admin can export current student records view as xlsx" do
    sign_in @admin

    get export_student_records_excel_path(q: users(:student).name)
    assert_response :success
    assert_equal "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", response.media_type
    assert_includes response.headers["Content-Disposition"], ".xlsx"
  end

  test "advisor only sees their assigned students" do
    sign_in @advisor

    get student_records_path
    assert_response :success
    assert_includes response.body, users(:student).name
    assert_not_includes response.body, users(:other_student).name
    assert_includes response.body, "No student records for this survey are assigned to you."

    # Advisors can view Student Records but should not see admin-only edit/delete actions.
    assert_not_includes response.body, 'aria-label="More actions"'
    assert_not_includes response.body, "Delete this student's survey responses?"
  end

  test "student records hide archived students by default and allow historical filter" do
    archived_student = students(:other_student)
    archived_student.archive!(archived_by: @admin, reason: "Historical records test")
    sign_in @admin

    get student_records_path

    assert_response :success
    assert_not_includes response.body, archived_student.user.name

    get student_records_path(student_status: "all")

    assert_response :success
    assert_includes response.body, archived_student.user.name
  end

  test "admin can filter students by search query" do
    sign_in @admin

    get student_records_path(q: users(:student).name)
    assert_response :success
    assert_includes response.body, users(:student).name
    assert_not_includes response.body, users(:other_student).name
  end

  test "admin can filter to a single survey" do
    sign_in @admin

    target = surveys(:fall_2025)
    other = surveys(:spring_2025)

    get student_records_path(survey_id: target.id)
    assert_response :success
    assert_includes response.body, target.title
    # Other surveys still appear in the Survey dropdown options; ensure they do
    # not render as a survey section.
    assert_not_includes response.body, ">#{other.title}</span>"
  end

  test "student records only lists students for survey track" do
    sign_in @admin

    residential_survey = surveys(:fall_2025)
    executive_survey = surveys(:fall_2025_executive)
    mismatch_student = students(:other_student)

    SurveyAssignment.find_or_create_by!(survey: residential_survey, student: mismatch_student) do |assignment|
      assignment.advisor = advisors(:other_advisor)
      assignment.assigned_at = Time.current
    end

    get student_records_path(survey_id: residential_survey.id)
    assert_response :success
    assert_includes response.body, users(:student).name
    assert_includes response.body, users(:other_student).name

    get student_records_path(survey_id: executive_survey.id)
    assert_response :success
    assert_not_includes response.body, users(:student).name
    assert_not_includes response.body, users(:other_student).name
    assert_includes response.body, "No student records match this survey yet."
  end

  test "admin can filter surveys by keyword" do
    sign_in @admin

    executive_title = surveys(:fall_2025_executive).title
    residential_title = surveys(:fall_2025).title

    get student_records_path(survey_query: "executive")
    assert_response :success
    assert_includes response.body, executive_title
    assert_not_includes response.body, residential_title
  end

  test "student records hide unassigned rows by default" do
    sign_in @admin

    get student_records_path
    assert_response :success
    assert_not_includes response.body, ">Unassigned</span>"
  end

  test "unassigned status filter renders no rows" do
    sign_in @admin

    get student_records_path(status: "unassigned")
    assert_response :success
    assert_not_includes response.body, ">Unassigned</span>"
    assert_includes response.body, "No student records match this survey yet."
  end

  test "admin can filter students by track" do
    sign_in @admin

    get student_records_path(track: "Executive")
    assert_response :success
    assert_includes response.body, users(:other_student).name
    assert_not_includes response.body, users(:student).name
  end

  test "admin can filter students by program year" do
    sign_in @admin

    get student_records_path(program_year: "2026")
    assert_response :success
    assert_includes response.body, users(:student).name
    assert_not_includes response.body, users(:other_student).name
  end

  test "archived survey row uses review-only response link and keeps admin response actions" do
    sign_in @admin

    survey = surveys(:fall_2025)
    student = students(:student)
    survey.update!(is_active: false)

    assignment = SurveyAssignment.find_or_initialize_by(survey_id: survey.id, student_id: student.student_id)
    assignment.advisor_id ||= student.advisor_id
    assignment.assigned_at ||= Time.current
    assignment.completed_at ||= Time.current
    assignment.save!

    survey_response = SurveyResponse.build(student: student, survey: survey)

    get student_records_path(survey_id: survey.id)
    assert_response :success

    assert_includes response.body, survey_response_path(survey_response)
    assert_not_includes response.body, new_feedback_path(survey_id: survey.id, student_id: student.student_id)
    assert_includes response.body, 'aria-label="More actions"'
    assert_includes response.body, "Edit Response"
  end

  test "advisor search stays within assigned scope" do
    sign_in @advisor

    get student_records_path(q: users(:other_student).email)
    assert_response :success
    assert_not_includes response.body, users(:other_student).name
  end

  test "unauthenticated user redirected" do
    get student_records_path
    assert_response :redirect
  end

  test "student users are redirected away" do
    sign_in users(:student)

    get student_records_path

    assert_redirected_to dashboard_path
    assert_match "Advisor or admin access required", flash[:alert]
  end

  test "student record status remains assigned until submission completed" do
    student = students(:student)
    survey = surveys(:fall_2025)
    question = survey.questions.first || survey.categories.first.questions.create!(
      question_text: "Fixture question",
      question_order: 1,
      question_type: "short_answer",
      is_required: true
    )

    StudentQuestion.where(student_id: student.student_id, question_id: question.id).delete_all
    StudentQuestion.create!(student_id: student.student_id, question: question, response_value: "Test response")

    controller = StudentRecordsController.new
    records = controller.send(:build_student_records, [ student ])
    row = find_row(records, student, survey)
    assert_not_nil row, "Expected to find a student row in records"
    assert_equal "Assigned", row[:status]
    assert_nil row[:completed_at]

    assignment = survey_assignments(:residential_assignment)
    assert_not_nil row[:available_until]
    assert_in_delta assignment.available_until.to_i, row[:available_until].to_i, 1
    completion_time = Time.current
    assignment.update!(completed_at: completion_time)

    controller_after = StudentRecordsController.new
    records_after = controller_after.send(:build_student_records, [ student ])
    row_after = find_row(records_after, student, survey)
    assert_not_nil row_after, "Expected to find updated student row"
    assert_equal "Completed", row_after[:status]
    assert_in_delta completion_time.to_i, row_after[:completed_at].to_i, 1
  end

  test "student record excludes rows when no assignment exists" do
    student = students(:student)
    survey = surveys(:spring_2026_residential)

    controller = StudentRecordsController.new
    records = controller.send(:build_student_records, [ student ])
    row = find_row(records, student, survey)
    assert_nil row, "Expected unassigned student row to be omitted from student records"
  end

  private

  def find_row(records, student, survey)
    Array(records).each do |semester_block|
      Array(semester_block[:surveys]).each do |survey_block|
        next unless survey_block[:survey].id == survey.id

        row = survey_block[:rows].find { |entry| entry[:student].student_id == student.student_id }
        return row if row
      end
    end
    nil
  end
end
