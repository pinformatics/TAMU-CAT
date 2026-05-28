require "test_helper"

class Assignments::SurveysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @survey = surveys(:fall_2025)
    sign_in users(:advisor)
  end

  test "index renders successfully" do
    get assignments_surveys_path
    assert_response :success
    assert_includes response.body, @survey.title
  end

  test "index orders surveys newest first" do
    older = surveys(:fall_2025)
    newer = surveys(:spring_2025)

    older.update_columns(created_at: 2.days.ago)
    newer.update_columns(created_at: Time.current)

    get assignments_surveys_path
    assert_response :success

    older_idx = response.body.index(older.title)
    newer_idx = response.body.index(newer.title)

    assert_not_nil older_idx
    assert_not_nil newer_idx
    assert_operator newer_idx, :<, older_idx
  end

  test "show filters students by survey track" do
    @survey.update!(track: "Residential")

    get assignments_survey_path(@survey)
    assert_response :success
    assert_includes response.body, users(:student).name
    refute_includes response.body, users(:other_student).name
  end

  test "show infers track from title when track attribute is blank" do
    sign_in users(:admin)

    @survey.update!(track: nil, title: "Executive Something")

    get assignments_survey_path(@survey)
    assert_response :success

    assert_includes response.body, users(:other_student).name
    refute_includes response.body, users(:student).name
  end

  test "show leaves bulk due date blank by default" do
    @survey.update!(available_until: Time.zone.local(2035, 2, 15, 18, 0))

    get assignments_survey_path(@survey)
    assert_response :success

    assert_match(/id="bulk_due_date"/, response.body)
    refute_match(/id="bulk_due_date"[^>]*value="\d{4}-\d{2}-\d{2}T\d{2}:\d{2}"/, response.body)
  end

  test "show displays survey default close date when assignment has no individual deadline" do
    student = students(:student)
    survey_deadline = Time.zone.local(2035, 2, 15, 18, 0)
    @survey.update!(available_until: survey_deadline)

    assignment = SurveyAssignment.find_or_initialize_by(survey: @survey, student: student)
    assignment.advisor ||= advisors(:advisor)
    assignment.assigned_at ||= Time.current
    assignment.available_until = nil
    assignment.save!

    get assignments_survey_path(@survey)
    assert_response :success
    expected_date = survey_deadline.to_date
    expected_deadline = "#{expected_date.strftime('%B')} #{expected_date.day}, #{expected_date.year}"
    assert_includes response.body, expected_deadline
  end

  test "admin show displays survey availability settings" do
    sign_in users(:admin)

    @survey.update!(
      available_from: Time.zone.local(2035, 1, 5, 15, 0),
      available_until: Time.zone.local(2035, 2, 15, 18, 0)
    )

    get assignments_survey_path(@survey)

    assert_response :success
    assert_includes response.body, "Survey Availability"
    assert_includes response.body, "Save Availability"
    assert_match(/id="survey_available_from"[^>]*value="2035-01-05T15:00"/, response.body)
    assert_match(/id="survey_available_until"[^>]*value="2035-02-15T18:00"/, response.body)
    assert_includes response.body, edit_admin_survey_path(@survey)
  end

  test "availability action updates survey dates and inherited assignments" do
    sign_in users(:admin)

    previous_start = Time.zone.local(2035, 1, 5, 15, 0)
    previous_deadline = Time.zone.local(2035, 2, 15, 18, 0)
    next_start = Time.zone.local(2035, 1, 12, 9, 30)
    next_deadline = Time.zone.local(2035, 3, 1, 17, 45)
    @survey.update!(available_from: previous_start, available_until: previous_deadline)

    inherited_assignment = SurveyAssignment.find_or_initialize_by(survey: @survey, student: students(:student))
    inherited_assignment.advisor ||= advisors(:advisor)
    inherited_assignment.assigned_at ||= Time.current
    inherited_assignment.available_from = previous_start
    inherited_assignment.available_until = previous_deadline
    inherited_assignment.save!

    custom_assignment = SurveyAssignment.find_or_initialize_by(survey: @survey, student: students(:other_student))
    custom_assignment.advisor ||= advisors(:other_advisor)
    custom_assignment.assigned_at ||= Time.current
    custom_start = previous_start + 2.days
    custom_deadline = previous_deadline + 2.days
    custom_assignment.available_from = custom_start
    custom_assignment.available_until = custom_deadline
    custom_assignment.save!

    patch availability_assignments_survey_path(@survey), params: {
      survey: {
        available_from: "2035-01-12T09:30",
        available_until: "2035-03-01T17:45"
      }
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_equal next_start, @survey.reload.available_from
    assert_equal next_deadline, @survey.available_until
    assert_equal next_start, inherited_assignment.reload.available_from
    assert_equal next_deadline, inherited_assignment.available_until
    assert_equal custom_start, custom_assignment.reload.available_from
    assert_equal custom_deadline, custom_assignment.available_until
  end

  test "advisor cannot update survey availability defaults" do
    previous_deadline = @survey.available_until

    patch availability_assignments_survey_path(@survey), params: {
      survey: {
        available_until: "2035-03-01T17:45"
      }
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_equal previous_deadline.to_i, @survey.reload.available_until.to_i
  end

  test "assign creates student questions and enqueues notification" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all

    assert_enqueued_jobs 1, only: SurveyNotificationJob do
      assert_difference "StudentQuestion.count", @survey.questions.count do
        assert_difference "SurveyAssignment.count", 1 do
          post assign_assignments_survey_path(@survey), params: { student_id: students(:student).student_id }
        end
      end
    end

    assert_redirected_to assignments_surveys_path
  end

  test "assign parses available_until and falls back when I18n timestamp formatting fails" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all

    I18n.stub(:l, ->(*) { raise I18n::InvalidLocale.new(:xx) }) do
      post assign_assignments_survey_path(@survey), params: {
        student_id: students(:student).student_id,
        available_until: "2030-01-01"
      }
    end

    assert_redirected_to assignments_surveys_path
    assignment = SurveyAssignment.find_by!(survey_id: @survey.id, student_id: students(:student).student_id)
    assert_equal Date.new(2030, 1, 1), assignment.available_until.to_date
    assert_match "Assigned", flash[:notice]
  end

  test "assign rejects custom student deadline earlier than survey deadline" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all

    survey_deadline = 10.days.from_now.change(hour: 23, min: 59, sec: 0)
    @survey.update!(available_until: survey_deadline)

    post assign_assignments_survey_path(@survey), params: {
      student_id: students(:student).student_id,
      available_until: 1.day.from_now.change(hour: 9, min: 0, sec: 0).strftime("%Y-%m-%d %H:%M")
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "cannot be earlier than the survey due date", flash[:alert].to_s.downcase
    refute SurveyAssignment.exists?(survey_id: @survey.id, student_id: students(:student).student_id)
  end

  test "assign_all handles eligible students" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all
    @survey.update!(track: "Residential")

    assert_enqueued_jobs 1, only: SurveyNotificationJob do
      assert_difference "StudentQuestion.count", @survey.questions.count do
        assert_difference "SurveyAssignment.count", 1 do
          post assign_all_assignments_survey_path(@survey)
        end
      end
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Assigned", flash[:notice]
  end

  test "assign_all respects selected student ids" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all
    @survey.update!(track: "Residential")

    selected_student = students(:student)
    excluded_student = students(:other_student)

    post assign_all_assignments_survey_path(@survey), params: {
      track: "Residential",
      student_ids: [ selected_student.student_id ]
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert SurveyAssignment.exists?(survey_id: @survey.id, student_id: selected_student.student_id)
    refute SurveyAssignment.exists?(survey_id: @survey.id, student_id: excluded_student.student_id)
  end

  test "assign_all updates selected existing assignments and creates missing ones" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all

    sign_in users(:admin)

    existing_student = students(:student)
    new_student = students(:other_student)

    existing_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: existing_student,
      advisor: advisors(:advisor),
      assigned_at: 3.days.ago,
      available_until: 3.days.from_now
    )

    post assign_all_assignments_survey_path(@survey), params: {
      student_ids: [ existing_student.student_id, new_student.student_id ],
      available_until: "2033-05-01 12:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Assigned", flash[:notice]

    expected_deadline = Time.zone.local(2033, 5, 1, 12, 0)
    assert_equal expected_deadline, existing_assignment.reload.available_until

    created_assignment = SurveyAssignment.find_by!(survey: @survey, student: new_student)
    assert_equal expected_deadline, created_assignment.available_until
    assert_operator StudentQuestion.where(student: new_student, question_id: @survey.questions.select(:id)).count, :>, 0
  end

  test "assign_all rejects custom deadline earlier than survey deadline" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all

    sign_in users(:admin)
    survey_deadline = Time.zone.local(2034, 7, 20, 23, 59)
    @survey.update!(available_until: survey_deadline)

    post assign_all_assignments_survey_path(@survey), params: {
      student_ids: [ students(:student).student_id ],
      available_until: "2034-07-10 10:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "cannot be earlier than the survey due date", flash[:alert].to_s.downcase
    refute SurveyAssignment.exists?(survey_id: @survey.id, student_id: students(:student).student_id)
  end

  test "assign_all uses survey default deadline when no custom deadline is provided" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all

    sign_in users(:admin)
    survey_deadline = Time.zone.local(2034, 9, 1, 18, 30)
    @survey.update!(available_until: survey_deadline)

    post assign_all_assignments_survey_path(@survey), params: {
      student_ids: [ students(:student).student_id ]
    }

    assert_redirected_to assignments_survey_path(@survey)
    assignment = SurveyAssignment.find_by!(survey_id: @survey.id, student_id: students(:student).student_id)
    assert_equal survey_deadline.to_i, assignment.available_until.to_i
  end

  test "assign_all alerts when no students match" do
    @survey.update!(track: "Executive")
    post assign_all_assignments_survey_path(@survey)

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "No students available", flash[:alert]
  end

  test "unassign removes assignments and notifies" do
    StudentQuestion.delete_all
    Notification.delete_all

    student = students(:student)
    StudentQuestion.create!(
      student: student,
      question: questions(:fall_q1),
      advisor_id: advisors(:advisor).advisor_id
    )
    SurveyAssignment.where(survey: @survey, student: student).delete_all
    SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current
    )

    assert_difference "StudentQuestion.count", -@survey.questions.count do
      assert_difference "Notification.count", 1 do
        delete unassign_assignments_survey_path(@survey), params: { student_id: student.student_id }
      end
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Unassigned", flash[:notice]
    notification = Notification.find_by!(user: student.user, title: "Survey Unassigned")
    assert_equal "The survey '#{@survey.title}' was removed from your assignments.", notification.message
    refute_includes notification.message, users(:advisor).name
  end

  test "unassigning multiple surveys creates distinct notifications" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all
    Notification.delete_all

    student = students(:student)

    other_survey = Survey.create!(
      title: "Temp Survey For Unassign Notifications",
      program_semester: program_semesters(:fall_2025),
      description: "Temp survey for notification regression coverage",
      is_active: true,
      available_until: 30.days.from_now.change(hour: 23, min: 59, sec: 0),
      categories_attributes: {
        "0" => {
          name: "Temp Category",
          questions_attributes: {
            "0" => {
              question_text: "Temp question?",
              question_order: 1,
              question_type: "short_answer",
              is_required: true,
              has_evidence_field: false,
              answer_options: nil
            }
          }
        }
      }
    )

    [ @survey, other_survey ].each do |survey|
      survey.questions.find_each do |question|
        StudentQuestion.create!(
          student: student,
          question: question,
          advisor_id: advisors(:advisor).advisor_id
        )
      end

      SurveyAssignment.create!(
        survey: survey,
        student: student,
        advisor: advisors(:advisor),
        assigned_at: Time.current
      )
    end

    assert_difference "Notification.count", 2 do
      delete unassign_assignments_survey_path(@survey), params: { student_id: student.student_id }
      delete unassign_assignments_survey_path(other_survey), params: { student_id: student.student_id }
    end

    notifications = Notification.where(user: student.user, title: "Survey Unassigned").order(:id)
    assert_equal 2, notifications.size
    assert_equal [ @survey.id, other_survey.id ].sort, notifications.map(&:notifiable_id).sort
    assert notifications.all? { |n| n.notifiable_type == "Survey" }
  end

  test "unassign is blocked for completed assignments" do
    StudentQuestion.delete_all
    Notification.delete_all
    SurveyAssignment.delete_all

    student = students(:student)
    @survey.questions.find_each do |question|
      StudentQuestion.create!(
        student: student,
        question: question,
        advisor_id: advisors(:advisor).advisor_id
      )
    end

    SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      completed_at: Time.current
    )

    assert_no_difference "StudentQuestion.count" do
      assert_no_difference "Notification.count" do
        delete unassign_assignments_survey_path(@survey), params: { student_id: student.student_id }
      end
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Cannot unassign a completed survey", flash[:alert]
    assert SurveyAssignment.find_by(survey: @survey, student: student).completed_at?
  end

  test "unassign removes assignment even when responses were deleted" do
    StudentQuestion.delete_all
    Notification.delete_all
    SurveyAssignment.delete_all

    student = students(:student)
    SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current
    )

    assert_no_difference "StudentQuestion.count" do
      assert_difference "Notification.count", 1 do
        assert_difference "SurveyAssignment.count", -1 do
          delete unassign_assignments_survey_path(@survey), params: { student_id: student.student_id }
        end
      end
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Unassigned", flash[:notice]
    assert_nil SurveyAssignment.find_by(survey: @survey, student: student)
  end

  test "show hides unassign action for completed surveys" do
    student = students(:student)
    SurveyAssignment.where(survey: @survey, student: student).delete_all
    SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      completed_at: Time.current
    )

    get assignments_survey_path(@survey)
    assert_response :success
    assert_includes response.body, "Completed"
    refute_includes response.body, "/unassign\""
  end

  test "unassign_selected removes only incomplete selected assignments" do
    StudentQuestion.delete_all
    Notification.delete_all
    SurveyAssignment.delete_all
    sign_in users(:admin)

    incomplete_student = students(:student)
    completed_student = students(:completed_student)

    @survey.questions.find_each do |question|
      StudentQuestion.create!(
        student: incomplete_student,
        question: question,
        advisor_id: advisors(:advisor).advisor_id
      )

      StudentQuestion.create!(
        student: completed_student,
        question: question,
        advisor_id: advisors(:advisor).advisor_id
      )
    end

    SurveyAssignment.create!(
      survey: @survey,
      student: incomplete_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current
    )

    SurveyAssignment.create!(
      survey: @survey,
      student: completed_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      completed_at: Time.current
    )

    assert_difference "SurveyAssignment.count", -1 do
      assert_difference "Notification.count", 1 do
        delete unassign_selected_assignments_survey_path(@survey), params: {
          track: "Residential",
          student_ids: [ incomplete_student.student_id, completed_student.student_id ]
        }
      end
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Unassigned", flash[:notice]
    assert_match "Skipped 1 completed assignment", flash[:notice]
    assert_nil SurveyAssignment.find_by(survey: @survey, student: incomplete_student)
    assert SurveyAssignment.find_by(survey: @survey, student: completed_student).completed_at?
  end

  test "unassign_selected works for selected students without track filter" do
    StudentQuestion.delete_all
    Notification.delete_all
    SurveyAssignment.delete_all

    sign_in users(:admin)

    first_student = students(:student)
    second_student = students(:other_student)

    [ first_student, second_student ].each do |student|
      @survey.questions.find_each do |question|
        StudentQuestion.create!(
          student: student,
          question: question,
          advisor_id: advisors(:advisor).advisor_id
        )
      end

      SurveyAssignment.create!(
        survey: @survey,
        student: student,
        advisor: advisors(:advisor),
        assigned_at: Time.current
      )
    end

    assert_difference "SurveyAssignment.count", -2 do
      assert_difference "Notification.count", 2 do
        delete unassign_selected_assignments_survey_path(@survey), params: {
          student_ids: [ first_student.student_id, second_student.student_id ]
        }
      end
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Unassigned", flash[:notice]
    assert_nil SurveyAssignment.find_by(survey: @survey, student: first_student)
    assert_nil SurveyAssignment.find_by(survey: @survey, student: second_student)
  end

  test "unassign_selected removes assigned selections and ignores selected unassigned students" do
    StudentQuestion.delete_all
    Notification.delete_all
    SurveyAssignment.delete_all

    sign_in users(:admin)

    assigned_student = students(:student)
    unassigned_student = students(:other_student)

    @survey.questions.find_each do |question|
      StudentQuestion.create!(
        student: assigned_student,
        question: question,
        advisor_id: advisors(:advisor).advisor_id
      )
    end

    SurveyAssignment.create!(
      survey: @survey,
      student: assigned_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current
    )

    assert_difference "SurveyAssignment.count", -1 do
      assert_difference "Notification.count", 1 do
        delete unassign_selected_assignments_survey_path(@survey), params: {
          student_ids: [ assigned_student.student_id, unassigned_student.student_id ]
        }
      end
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Unassigned", flash[:notice]
    assert_nil SurveyAssignment.find_by(survey: @survey, student: assigned_student)
    assert_nil SurveyAssignment.find_by(survey: @survey, student: unassigned_student)
  end

  test "unassign_selected alerts when selected students are only completed assignments" do
    StudentQuestion.delete_all
    Notification.delete_all
    SurveyAssignment.delete_all

    sign_in users(:admin)

    completed_student = students(:completed_student)

    @survey.questions.find_each do |question|
      StudentQuestion.create!(
        student: completed_student,
        question: question,
        advisor_id: advisors(:advisor).advisor_id
      )
    end

    completed_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: completed_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      completed_at: Time.current
    )

    assert_no_difference "SurveyAssignment.count" do
      assert_no_difference "Notification.count" do
        delete unassign_selected_assignments_survey_path(@survey), params: {
          student_ids: [ completed_student.student_id ]
        }
      end
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "No incomplete assignments matched", flash[:alert]
    assert completed_assignment.reload.completed_at.present?
  end

  test "extend_deadline updates an incomplete assignment" do
    SurveyAssignment.delete_all

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )

    patch extend_deadline_assignments_survey_path(@survey), params: {
      student_id: student.student_id,
      new_available_until: "2030-02-10 17:30"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Changed", flash[:notice]
    assert_equal Time.zone.local(2030, 2, 10, 17, 30), assignment.reload.available_until
  end

  test "extend_deadline rejects date earlier than survey deadline" do
    SurveyAssignment.delete_all

    survey_deadline = Time.zone.local(2035, 9, 15, 23, 59)
    @survey.update!(available_until: survey_deadline)

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: survey_deadline + 2.days
    )

    patch extend_deadline_assignments_survey_path(@survey), params: {
      student_id: student.student_id,
      new_available_until: "2035-09-10 10:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "cannot be earlier than the survey due date", flash[:alert].to_s.downcase
    assert_equal (survey_deadline + 2.days).to_i, assignment.reload.available_until.to_i
  end

  test "extend_deadline is blocked for completed assignments" do
    SurveyAssignment.delete_all

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      completed_at: Time.current,
      available_until: 2.days.from_now
    )

    original_deadline = assignment.available_until

    patch extend_deadline_assignments_survey_path(@survey), params: {
      student_id: student.student_id,
      new_available_until: "2030-02-10 17:30"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Cannot change deadline for a completed survey", flash[:alert]
    assert_equal original_deadline.to_i, assignment.reload.available_until.to_i
  end

  test "extend_group_deadline updates selected assignments including completed ones" do
    SurveyAssignment.delete_all

    residential_student = students(:student)
    executive_student = students(:other_student)

    residential_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: residential_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      completed_at: Time.current,
      available_until: 2.days.from_now
    )

    executive_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: executive_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )

    patch extend_group_deadline_assignments_survey_path(@survey), params: {
      track: "Residential",
      student_ids: [ residential_student.student_id ],
      new_available_until: "2031-04-11 09:15"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Changed", flash[:notice]
    assert_equal Time.zone.local(2031, 4, 11, 9, 15), residential_assignment.reload.available_until
    assert_not_equal Time.zone.local(2031, 4, 11, 9, 15), executive_assignment.reload.available_until
    assert residential_assignment.completed_at.present?
  end

  test "extend_group_deadline assigns selected unassigned students with new deadline" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all

    sign_in users(:admin)

    residential_student = students(:student)
    unassigned_residential_student = students(:completed_student)

    existing_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: residential_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )

    patch extend_group_deadline_assignments_survey_path(@survey), params: {
      track: "Residential",
      student_ids: [ residential_student.student_id, unassigned_residential_student.student_id ],
      new_available_until: "2032-01-02 10:45"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Changed", flash[:notice]

    expected_deadline = Time.zone.local(2032, 1, 2, 10, 45)
    assert_equal expected_deadline, existing_assignment.reload.available_until

    created_assignment = SurveyAssignment.find_by!(survey: @survey, student: unassigned_residential_student)
    assert_equal expected_deadline, created_assignment.available_until
    assert_operator StudentQuestion.where(student: unassigned_residential_student, question_id: @survey.questions.select(:id)).count, :>, 0
  end

  test "extend_group_deadline updates only selected students without track filter" do
    SurveyAssignment.delete_all

    sign_in users(:admin)

    selected_student = students(:student)
    unselected_student = students(:other_student)

    selected_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: selected_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )

    unselected_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: unselected_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )

    patch extend_group_deadline_assignments_survey_path(@survey), params: {
      student_ids: [ selected_student.student_id ],
      new_available_until: "2032-08-20 14:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Changed", flash[:notice]

    expected_deadline = Time.zone.local(2032, 8, 20, 14, 0)
    assert_equal expected_deadline, selected_assignment.reload.available_until
    assert_not_equal expected_deadline, unselected_assignment.reload.available_until
  end

  test "extend_group_deadline alerts for invalid deadline input" do
    SurveyAssignment.delete_all

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )

    original_deadline = assignment.available_until

    patch extend_group_deadline_assignments_survey_path(@survey), params: {
      student_ids: [ student.student_id ],
      new_available_until: "not-a-date"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Please provide a valid group deadline", flash[:alert]
    assert_equal original_deadline.to_i, assignment.reload.available_until.to_i
  end

  test "extend_group_deadline rejects date earlier than survey deadline" do
    SurveyAssignment.delete_all

    survey_deadline = Time.zone.local(2036, 2, 20, 23, 59)
    @survey.update!(available_until: survey_deadline)

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: survey_deadline + 1.day
    )

    patch extend_group_deadline_assignments_survey_path(@survey), params: {
      student_ids: [ student.student_id ],
      new_available_until: "2036-02-15 09:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "cannot be earlier than the survey due date", flash[:alert].to_s.downcase
    assert_equal (survey_deadline + 1.day).to_i, assignment.reload.available_until.to_i
  end

  test "extend_group_deadline uses survey default deadline when input is blank" do
    SurveyAssignment.delete_all

    sign_in users(:admin)

    selected_student = students(:student)
    survey_default_deadline = Time.zone.local(2036, 6, 1, 16, 0)
    @survey.update!(available_until: survey_default_deadline)

    selected_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: selected_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )

    patch extend_group_deadline_assignments_survey_path(@survey), params: {
      student_ids: [ selected_student.student_id ],
      new_available_until: ""
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Changed", flash[:notice]
    assert_equal survey_default_deadline.to_i, selected_assignment.reload.available_until.to_i
  end

  test "extend_group_deadline with blank input sets no deadline when survey has no default" do
    SurveyAssignment.delete_all

    sign_in users(:admin)
    @survey.update!(available_until: nil)

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 3.days.from_now
    )

    patch extend_group_deadline_assignments_survey_path(@survey), params: {
      student_ids: [ student.student_id ],
      new_available_until: ""
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "No deadline", flash[:notice]
    assert_nil assignment.reload.available_until
  end

  test "extend_group_deadline respects combined track and year filters" do
    SurveyAssignment.delete_all

    sign_in users(:admin)

    included_student = students(:student)
    excluded_student = students(:completed_student)
    excluded_student.update_columns(program_year: included_student.program_year.to_i + 1)

    included_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: included_student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )

    excluded_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: excluded_student,
      advisor: advisors(:other_advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )

    patch extend_group_deadline_assignments_survey_path(@survey), params: {
      track: "Residential",
      program_year: included_student.program_year,
      student_ids: [ included_student.student_id, excluded_student.student_id ],
      new_available_until: "2037-01-15 11:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    expected_deadline = Time.zone.local(2037, 1, 15, 11, 0)
    assert_equal expected_deadline.to_i, included_assignment.reload.available_until.to_i
    assert_not_equal expected_deadline.to_i, excluded_assignment.reload.available_until.to_i
  end

  test "reopen clears completion for selected assignments" do
    SurveyAssignment.delete_all

    first_student = students(:student)
    second_student = students(:other_student)

    first_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: first_student,
      advisor: advisors(:advisor),
      assigned_at: 10.days.ago,
      completed_at: 1.day.ago,
      available_until: 2.days.ago
    )

    second_assignment = SurveyAssignment.create!(
      survey: @survey,
      student: second_student,
      advisor: advisors(:advisor),
      assigned_at: 10.days.ago,
      completed_at: 1.day.ago,
      available_until: 2.days.ago
    )

    patch reopen_assignments_survey_path(@survey), params: {
      track: "Residential",
      student_ids: [ first_student.student_id ],
      new_available_until: "2034-09-12 08:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Re-opened", flash[:notice]

    first_assignment.reload
    second_assignment.reload

    assert_nil first_assignment.completed_at
    assert_equal Time.zone.local(2034, 9, 12, 8, 0), first_assignment.available_until
    assert second_assignment.completed_at.present?
  end

  test "reopen rejects invalid extension deadline input" do
    SurveyAssignment.delete_all

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: 10.days.ago,
      completed_at: 1.day.ago,
      available_until: 2.days.ago
    )

    patch reopen_assignments_survey_path(@survey), params: {
      student_ids: [ student.student_id ],
      new_available_until: "not-a-date"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "Please provide a valid extension deadline", flash[:alert]
    assert assignment.reload.completed_at.present?
  end

  test "reopen rejects extension deadline earlier than survey deadline" do
    SurveyAssignment.delete_all

    survey_deadline = Time.zone.local(2037, 5, 10, 23, 59)
    @survey.update!(available_until: survey_deadline)

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: 10.days.ago,
      completed_at: 1.day.ago,
      available_until: survey_deadline + 1.day
    )

    patch reopen_assignments_survey_path(@survey), params: {
      student_ids: [ student.student_id ],
      new_available_until: "2037-05-01 10:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "cannot be earlier than the survey due date", flash[:alert].to_s.downcase
    assert assignment.reload.completed_at.present?
  end

  test "assign is blocked when survey is archived" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all
    @survey.update!(is_active: false)

    assert_no_difference "StudentQuestion.count" do
      assert_no_difference "SurveyAssignment.count" do
        post assign_assignments_survey_path(@survey), params: { student_id: students(:student).student_id }
      end
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "survey is archived", flash[:alert].to_s.downcase
  end

  test "unassign is blocked when survey is archived" do
    StudentQuestion.delete_all
    SurveyAssignment.delete_all

    student = students(:student)
    SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current
    )
    @survey.update!(is_active: false)

    assert_no_difference "SurveyAssignment.count" do
      delete unassign_assignments_survey_path(@survey), params: { student_id: student.student_id }
    end

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "survey is archived", flash[:alert].to_s.downcase
  end

  test "extend_deadline is blocked when survey is archived" do
    SurveyAssignment.delete_all

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: 2.days.from_now
    )
    original_deadline = assignment.available_until
    @survey.update!(is_active: false)

    patch extend_deadline_assignments_survey_path(@survey), params: {
      student_id: student.student_id,
      new_available_until: "2032-01-20 10:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "survey is archived", flash[:alert].to_s.downcase
    assert_equal original_deadline.to_i, assignment.reload.available_until.to_i
  end

  test "reopen is blocked when survey is archived" do
    SurveyAssignment.delete_all

    student = students(:student)
    assignment = SurveyAssignment.create!(
      survey: @survey,
      student: student,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      completed_at: Time.current,
      available_until: 2.days.ago
    )
    @survey.update!(is_active: false)

    patch reopen_assignments_survey_path(@survey), params: {
      student_ids: [ student.student_id ],
      new_available_until: "2032-01-20 10:00"
    }

    assert_redirected_to assignments_survey_path(@survey)
    assert_match "survey is archived", flash[:alert].to_s.downcase
    assert assignment.reload.completed_at.present?
  end
end
