require "test_helper"

class StudentRecordsControllerPrivateTest < ActionController::TestCase
  tests StudentRecordsController

  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = students(:student)
    @survey = surveys(:fall_2025)
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in @admin
  end

  test "staff access guard allows staff and redirects students" do
    assert_nil @controller.send(:require_staff_access!)

    sign_out @admin
    sign_in @advisor
    assert_nil @controller.send(:require_staff_access!)

    sign_out @advisor
    sign_in users(:student)
    @controller.stub(:redirect_to, ->(*, **) { true }) do
      assert_equal true, @controller.send(:require_staff_access!)
    end
  end

  test "survey track keys resolve track list legacy title and blank surveys" do
    survey = Struct.new(:track_list, :track, :title).new([ "Residential", "executive", "" ], nil, "")
    assert_equal [ "residential", "executive" ], @controller.send(:survey_track_keys, survey)

    legacy = Struct.new(:track, :title).new("Residential", "")
    assert_equal [ "residential" ], @controller.send(:survey_track_keys, legacy)

    executive = Struct.new(:track, :title).new(nil, "EMHA Executive Survey")
    residential = Struct.new(:track, :title).new(nil, "RMHA Residential Survey")
    other = Struct.new(:track, :title).new(nil, "General Survey")
    assert_equal [ "executive" ], @controller.send(:survey_track_keys, executive)
    assert_equal [ "residential" ], @controller.send(:survey_track_keys, residential)
    assert_equal [], @controller.send(:survey_track_keys, other)
  end

  test "filters normalize invalid all and allowed values" do
    assert_nil @controller.send(:normalize_status_filter, "")
    assert_nil @controller.send(:normalize_status_filter, "all")
    assert_equal "completed", @controller.send(:normalize_status_filter, "Completed")
    assert_equal "assigned", @controller.send(:normalize_status_filter, "assigned")
    assert_equal "unassigned", @controller.send(:normalize_status_filter, "unassigned")
    assert_nil @controller.send(:normalize_status_filter, "other")

    assert_equal "name_asc", @controller.send(:normalize_sort_key, "")
    assert_equal "name_asc", @controller.send(:normalize_sort_key, "bad")
    assert_equal "due_desc", @controller.send(:normalize_sort_key, "due_desc")

    assert_equal "Residential", @controller.send(:normalize_track_filter, "residential")
    assert_nil @controller.send(:normalize_track_filter, "not a track")
    assert_equal "2026", @controller.send(:normalize_program_year_filter, "2026")
    assert_nil @controller.send(:normalize_program_year_filter, "26")
  end

  test "student record row sorting covers every sort mode" do
    row_student = Struct.new(:user, :track, :program_year, :class_of)
    alpha = row_student.new(Struct.new(:name).new("Alpha"), "Executive", 2027, nil)
    beta = row_student.new(Struct.new(:name).new("Beta"), "Residential", nil, nil)
    rows = [
      { student: beta, status: "Assigned", available_until: 2.days.from_now, completed_at: nil },
      { student: alpha, status: "Completed", available_until: 1.day.from_now, completed_at: Time.current }
    ]

    {
      "name_asc" => "Alpha",
      "name_desc" => "Beta",
      "status" => "Alpha",
      "track" => "Alpha",
      "program_year_asc" => "Alpha",
      "program_year_desc" => "Alpha",
      "due_asc" => "Alpha",
      "due_desc" => "Beta",
      "completed_desc" => "Alpha"
    }.each do |sort_key, expected_first|
      @controller.instance_variable_set(:@sort_key, sort_key)
      assert_equal expected_first.downcase, @controller.send(:row_student_name, @controller.send(:sort_student_record_rows, rows).first)
    end

    assert_equal [], @controller.send(:sort_student_record_rows, [])
    assert_equal [ 2025, 3 ], @controller.send(:semester_sort_key, "Fall 2025")
    assert_equal [ 0, 0 ], @controller.send(:semester_sort_key, nil)
    assert_equal [ 2025, 0 ], @controller.send(:semester_sort_key, "Winter 2025")
    assert_equal 0, @controller.send(:status_sort_value, "Completed")
    assert_equal 3, @controller.send(:status_sort_value, "Unknown")
  end

  test "lookup helpers handle empty inputs and status branches" do
    assert_equal({}, @controller.send(:load_feedback_lookup, [], [ @survey.id ]))
    assert_equal({}, @controller.send(:load_assignment_lookup, [ @student.student_id ], []))
    assert_equal({}, @controller.send(:load_admin_update_lookup, [], []))
    assert_equal({}, @controller.send(:load_feedback_submission_lookup, [], []))
    assert_equal({}, @controller.send(:load_employment_export_lookup, [], []))

    feedback = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      category_id: @survey.categories.first.id,
      average_score: 4,
      comments: "Draft"
    )
    lookup = @controller.send(:load_feedback_lookup, [ @student.student_id ], [ @survey.id ])
    assert_includes lookup.dig(@student.student_id, @survey.id).map(&:id), feedback.id

    assert_equal [ "No Feedback", nil ], @controller.send(:feedback_status_for_row, feedbacks_for_pair: [], feedback_last_updated: nil, feedback_submission: nil)
    assert_equal [ "Draft", feedback.updated_at ], @controller.send(:feedback_status_for_row, feedbacks_for_pair: [ feedback ], feedback_last_updated: feedback.updated_at, feedback_submission: nil)
    submission = AdvisorFeedbackSubmission.find_or_initialize_by(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id
    )
    submission.update!(
      submitted_at: Time.current,
      last_saved_at: 1.minute.ago
    )
    assert_equal [ "Submitted", submission.submitted_at ], @controller.send(:feedback_status_for_row, feedbacks_for_pair: [ feedback ], feedback_last_updated: feedback.updated_at, feedback_submission: submission)
  end

  test "employment export helpers format every answer shape and workbook sheets" do
    question = Question.new(question_type: "dropdown", answer_options: [ [ "Other", "0" ], [ "Yes", "yes" ] ].to_json)
    response = Struct.new(:question, :answer)

    assert_equal :currently_employed, @controller.send(:employment_field_key_for, "Are you currently employed?")
    assert_equal :employer, @controller.send(:employment_field_key_for, "If yes, where are you employed?")
    assert_equal :job_title, @controller.send(:employment_field_key_for, "What is your title?")
    assert_equal :hours_per_week, @controller.send(:employment_field_key_for, "How many hours per week do you work on average?")
    assert_equal :work_schedule_flexibility, @controller.send(:employment_field_key_for, "How flexible are your work hours?")
    assert_nil @controller.send(:employment_field_key_for, "Unrelated")

    assert_nil @controller.send(:format_employment_answer, response.new(question, nil))
    assert_equal "Yes", @controller.send(:format_employment_answer, response.new(question, "yes"))
    assert_equal "custom", @controller.send(:format_employment_answer, response.new(question, { "answer" => "0", "text" => "custom" }))
    assert_equal "Yes: extra", @controller.send(:format_employment_answer, response.new(question, { "answer" => "yes", "text" => "extra" }))
    assert_equal "A, B", @controller.send(:format_employment_answer, response.new(question, [ "A", "", "B" ]))
    assert_nil @controller.send(:employment_choice_label, question, " ")
    assert_equal "missing", @controller.send(:employment_choice_label, question, "missing")

    used = {}
    assert_equal "Survey Records", @controller.send(:unique_worksheet_name, "Survey Records", used)
    assert_equal "Survey Records (2)", @controller.send(:unique_worksheet_name, "Survey Records", used)
    assert_equal "Sheet", @controller.send(:unique_worksheet_name, "[]:*?/\\", used)
  end
end
