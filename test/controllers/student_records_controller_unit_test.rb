require "test_helper"

class StudentRecordsControllerUnitTest < ActiveSupport::TestCase
  test "required_question? applies yes/no and flexibility scale exceptions" do
    controller = StudentRecordsController.new

    required_question = Struct.new(:required?, :choice_question?, :answer_option_values, :question_text).new(true, false, [], "")
    assert_equal true, controller.send(:required_question?, required_question)

    yes_no = Struct.new(:required?, :choice_question?, :answer_option_values, :question_text).new(false, true, [ "Yes", "No" ], "")
    assert_equal false, controller.send(:required_question?, yes_no)

    flexibility = Struct.new(:required?, :choice_question?, :answer_option_values, :question_text).new(false, true, %w[1 2 3 4 5], "How flexible are you?")
    assert_equal false, controller.send(:required_question?, flexibility)

    other_choice = Struct.new(:required?, :choice_question?, :answer_option_values, :question_text).new(false, true, %w[A B C], "")
    assert_equal true, controller.send(:required_question?, other_choice)
  end

  test "semester_sort_key handles nil and known terms" do
    controller = StudentRecordsController.new

    assert_equal [ 0, 0 ], controller.send(:semester_sort_key, nil)
    assert_equal [ 2025, 3 ], controller.send(:semester_sort_key, "Fall 2025")
    assert_equal [ 2025, 1 ], controller.send(:semester_sort_key, "Spring 2025")
    assert_equal [ 2025, 2 ], controller.send(:semester_sort_key, "Summer 2025")
  end

  test "normalizers reject unknown status sort track and year values" do
    controller = StudentRecordsController.new

    assert_nil controller.send(:normalize_status_filter, "waiting")
    assert_equal "name_asc", controller.send(:normalize_sort_key, "surprise")
    assert_nil controller.send(:normalize_program_year_filter, "Class of 2026")
    assert_equal "2026", controller.send(:normalize_program_year_filter, "2026")
  end

  test "sort_student_record_rows handles status track year and date sorts" do
    controller = StudentRecordsController.new
    student = students(:student)
    other_student = students(:other_student)
    student.update!(track: "Residential", program_year: 2027)
    other_student.update!(track: "Executive", program_year: 2026)

    rows = [
      { student: student, status: "Assigned", available_until: Time.zone.parse("2026-02-01"), completed_at: nil },
      { student: other_student, status: "Completed", available_until: Time.zone.parse("2026-01-01"), completed_at: Time.zone.parse("2026-01-05") },
      { student: nil, status: "Unassigned", available_until: nil, completed_at: nil }
    ]

    controller.instance_variable_set(:@sort_key, "status")
    assert_equal [ "Completed", "Assigned", "Unassigned" ], controller.send(:sort_student_record_rows, rows).map { |row| row[:status] }

    controller.instance_variable_set(:@sort_key, "track")
    assert_equal [ other_student, student, nil ], controller.send(:sort_student_record_rows, rows).map { |row| row[:student] }

    controller.instance_variable_set(:@sort_key, "program_year_asc")
    assert_equal [ other_student, student, nil ], controller.send(:sort_student_record_rows, rows).map { |row| row[:student] }

    controller.instance_variable_set(:@sort_key, "program_year_desc")
    assert_equal [ student, other_student, nil ], controller.send(:sort_student_record_rows, rows).map { |row| row[:student] }

    controller.instance_variable_set(:@sort_key, "due_asc")
    assert_equal [ other_student, student, nil ], controller.send(:sort_student_record_rows, rows).map { |row| row[:student] }

    controller.instance_variable_set(:@sort_key, "due_desc")
    assert_equal [ student, other_student, nil ], controller.send(:sort_student_record_rows, rows).map { |row| row[:student] }

    controller.instance_variable_set(:@sort_key, "completed_desc")
    assert_equal [ other_student, student, nil ], controller.send(:sort_student_record_rows, rows).map { |row| row[:student] }
  end

  test "load_employment_export_lookup extracts normalized employment fields" do
    controller = StudentRecordsController.new
    student = students(:student)
    survey = surveys(:fall_2025)

    employment = Category.create!(
      survey: survey,
      name: "Employment Information",
      description: "Employment details"
    )

    employed_question = employment.questions.create!(
      question_text: "Are you currently employed?",
      question_order: 1,
      question_type: "multiple_choice",
      is_required: true,
      answer_options: [ "Yes", "No" ].to_json
    )
    employer_question = employment.questions.create!(
      question_text: "If yes, where are you employed? (name and address)",
      question_order: 2,
      question_type: "short_answer",
      is_required: false
    )
    title_question = employment.questions.create!(
      question_text: "What is your title?",
      question_order: 3,
      question_type: "short_answer",
      is_required: false
    )
    hours_question = employment.questions.create!(
      question_text: "How many hours per week do you work on average?",
      question_order: 4,
      question_type: "short_answer",
      is_required: false
    )
    flexibility_question = employment.questions.create!(
      question_text: "How flexible are your work hours?",
      question_order: 5,
      question_type: "multiple_choice",
      is_required: false,
      answer_options: [
        [ "1 - No flexibility", "1" ],
        [ "5 - Very flexible", "5" ],
        { label: "Other", value: "0", requires_text: true }
      ].to_json
    )

    StudentQuestion.create!(student: student, question: employed_question, response_value: "Yes")
    StudentQuestion.create!(student: student, question: employer_question, response_value: "St. Joseph Health, Bryan, TX")
    StudentQuestion.create!(student: student, question: title_question, response_value: "Graduate Intern")
    StudentQuestion.create!(student: student, question: hours_question, response_value: "32")
    StudentQuestion.create!(
      student: student,
      question: flexibility_question,
      response_value: { answer: "0", text: "Hybrid with occasional weekends" }.to_json
    )

    lookup = controller.send(:load_employment_export_lookup, [ student.student_id ], [ survey.id ])
    row = lookup[[ student.student_id, survey.id ]]

    assert_equal "Yes", row[:currently_employed]
    assert_equal "St. Joseph Health, Bryan, TX", row[:employer]
    assert_equal "Graduate Intern", row[:job_title]
    assert_equal "32", row[:hours_per_week]
    assert_equal "Hybrid with occasional weekends", row[:work_schedule_flexibility]
  end

  test "employment field and answer helpers cover hash array and unknown branches" do
    controller = StudentRecordsController.new
    question = Struct.new(:choice_question?, :answer_option_pairs).new(
      true,
      [
        [ "1 - No flexibility", "1" ],
        [ "Other", "0" ]
      ]
    )
    response = Struct.new(:question, :answer)

    assert_nil controller.send(:employment_field_key_for, "Favorite color?")
    assert_equal "1 - No flexibility: Tuesdays only", controller.send(:format_employment_answer, response.new(question, { "answer" => "1", "text" => "Tuesdays only" }))
    assert_equal "1 - No flexibility", controller.send(:format_employment_answer, response.new(question, { "answer" => "1" }))
    assert_equal "A, B", controller.send(:format_employment_answer, response.new(question, [ "A", "", "B" ]))
    assert_nil controller.send(:format_employment_answer, response.new(question, ""))
  end

  test "build_student_records_workbook includes employment columns and values" do
    controller = StudentRecordsController.new
    student = students(:student)
    survey = surveys(:fall_2025)

    workbook = controller.send(
      :build_student_records_workbook,
      [
        {
          semester: "Fall 2025",
          surveys: [
            {
              survey: survey,
              rows: [
                {
                  student: student,
                  advisor: student.advisor,
                  status: "Completed",
                  completed_at: Time.zone.parse("2025-10-01 08:00"),
                  feedback_status_label: "Submitted",
                  feedback_status_timestamp: Time.zone.parse("2025-10-02 08:00"),
                  employment_data: {
                    currently_employed: "Yes",
                    employer: "St. Joseph Health, Bryan, TX",
                    job_title: "Graduate Intern",
                    hours_per_week: "32",
                    work_schedule_flexibility: "Hybrid"
                  }
                }
              ]
            }
          ]
        }
      ]
    )

    sheet = workbook.workbook.worksheets.first
    headers = sheet.rows[3].cells.map(&:value)
    values = sheet.rows[4].cells.map(&:value)

    assert_includes headers, "Employment Status"
    assert_includes headers, "Employer (Name and Address)"
    assert_includes headers, "Job Title"
    assert_includes headers, "Avg Hours/Week"
    assert_includes headers, "Work Schedule Flexibility"

    assert_includes values, "Yes"
    assert_includes values, "St. Joseph Health, Bryan, TX"
    assert_includes values, "Graduate Intern"
    assert_includes values, 32
    assert_includes values, "Hybrid"
  end
end
