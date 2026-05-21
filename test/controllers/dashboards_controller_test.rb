require "test_helper"
require "nokogiri"

class DashboardsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @student = users(:student)
    @advisor = users(:advisor)
    @other_student = users(:other_student)
  end

  test "switch_role blocked in production when disabled" do
    sign_in @student

    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      ENV["ENABLE_ROLE_SWITCH"] = nil
      post switch_role_path, params: { role: "advisor" }
      assert_redirected_to dashboard_path
      follow_redirect!
      assert_match "Role switching is only available", flash[:alert]
    end
  ensure
    ENV.delete("ENABLE_ROLE_SWITCH")
  end

  test "switch_role rejects invalid role" do
    sign_in @student
    post switch_role_path, params: { role: "invalid-role" }
    assert_redirected_to dashboard_path
    follow_redirect!
    assert_match "Unrecognized role selection.", flash[:alert]
  end

  test "switch_role redirects with notice when already viewing selected role" do
    sign_in @student

    post switch_role_path, params: { role: "student" }

    assert_redirected_to student_dashboard_path
    follow_redirect!
    assert_match(/already viewing/i, flash[:notice].to_s)
  end

  test "show redirects based on role" do
    sign_in @student
    get dashboard_path
    assert_redirected_to student_dashboard_path

    sign_in @advisor
    get dashboard_path
    assert_redirected_to advisor_dashboard_path

    sign_in @admin
    get dashboard_path
    assert_redirected_to admin_dashboard_path
  end

  test "show falls back to student dashboard for unknown role" do
    user = @student
    user.update_column(:role, "mystery")

    sign_in user
    get dashboard_path
    assert_redirected_to student_dashboard_path
  ensure
    user.update_column(:role, "student")
  end

  test "switch_role updates user role when allowed" do
    sign_in @admin
    post switch_role_path, params: { role: "student" }
    assert_redirected_to student_dashboard_path
    @admin.reload
    assert_equal "student", @admin.role
  ensure
    @admin.update!(role: "admin")
  end

  test "manage_members requires admin" do
    sign_in @student
    get manage_members_path
    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_redirected_to dashboard_path
    follow_redirect!
    assert_nil flash[:alert]
  end

  test "manage_members shows an alert for advisors" do
    sign_in @advisor

    get manage_members_path

    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_redirected_to dashboard_path
    follow_redirect!
    assert_match(/access denied/i, flash[:alert].to_s)
  end

  test "people_management requires admin for students" do
    sign_in @student

    get people_management_path

    assert_redirected_to dashboard_path
    follow_redirect!
    assert_nil flash[:alert]
  end

  test "people_management requires admin for advisors" do
    sign_in @advisor

    get people_management_path

    assert_redirected_to dashboard_path
    follow_redirect!
    assert_match(/access denied/i, flash[:alert].to_s)
  end

  test "people_management loads members tab for admin" do
    sign_in @admin

    get people_management_path, params: { tab: "members" }

    assert_response :success
    assert_includes response.body, "People Management"
    assert_includes response.body, "Member Management"
  end

  test "people_management loads students tab for admin" do
    sign_in @admin

    get people_management_path, params: { tab: "students" }

    assert_response :success
    assert_includes response.body, "People Management"
    assert_includes response.body, "Student Advisor Management"
    assert_includes response.body, "Bulk lifecycle update"
  end

  test "people_management students tab filters lifecycle status" do
    sign_in @admin
    student = students(:student)
    student.graduate!(at: Time.current)

    get people_management_path, params: { tab: "students" }

    assert_response :success
    names = Nokogiri::HTML.parse(response.body).css(".user-name-cell .c-value").map { |node| node.text.strip }
    refute_includes names, student.user.name

    get people_management_path, params: { tab: "students", student_status: "graduated" }

    assert_response :success
    names = Nokogiri::HTML.parse(response.body).css(".user-name-cell .c-value").map { |node| node.text.strip }
    assert_includes names, student.user.name
    assert_includes response.body, "Graduated"
  end

  test "manage_members lists users for admin" do
    sign_in @admin
    get manage_members_path
    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_response :success
    assert_includes response.body, @student.email
  end

  test "manage_members supports searching" do
    sign_in @admin

    get manage_members_path, params: { q: "student@example.com" }

    assert_redirected_to people_management_path(tab: "members", q: "student@example.com")
    follow_redirect!
    assert_response :success
    assert_includes response.body, "student@example.com"
  end

  test "update_roles handles empty submission" do
    sign_in @admin
    patch update_roles_path, params: { role_updates: {} }
    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_match "No role changes were submitted", flash[:alert]
  end

  test "update_roles processes successes and failures" do
    sign_in @admin
    payload = {
      @admin.id => "student", # cannot change own role
      999999 => "advisor",    # user missing
      @student.id => "invalid", # invalid role
      @other_student.id => "advisor" # valid update
    }

    patch update_roles_path, params: { role_updates: payload }
    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
  assert_match "Updated", flash[:notice]
  assert_match "cannot change your own role", flash[:notice]
    assert_equal "advisor", @other_student.reload.role
  ensure
    @other_student.update!(role: "student")
  end

  test "update_roles logs admin activity" do
    sign_in @admin
    payload = { @other_student.id => "advisor" }

    assert_difference -> { AdminActivityLog.count }, 1 do
      patch update_roles_path, params: { role_updates: payload }
    end

    activity = AdminActivityLog.order(created_at: :desc).first
    assert_equal "role_update", activity.action
    assert_equal @admin, activity.admin
  ensure
    @other_student.update!(role: "student")
  end

  test "update_roles returns alert when all updates fail" do
    sign_in @admin

    payload = {
      @admin.id => "student",     # cannot change own role
      999999 => "advisor",        # user missing
      @student.id => "not-a-role" # invalid role
    }

    patch update_roles_path, params: { role_updates: payload }

    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_match(/role update errors/i, flash[:alert].to_s)
  end

  test "update_roles reports no changes needed" do
    sign_in @admin

    patch update_roles_path, params: { role_updates: { @student.id => "student" } }

    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_match(/no role changes were needed/i, flash[:notice].to_s)
  end

  test "destroy_member removes selected member" do
    sign_in @admin

    assert_difference -> { User.count }, -1 do
      delete remove_member_path(@other_student)
    end

    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_match(/removed member/i, flash[:notice].to_s)
  end

  test "destroy_member prevents removing current admin" do
    sign_in @admin

    assert_no_difference -> { User.count } do
      delete remove_member_path(@admin)
    end

    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_match(/cannot remove your own account/i, flash[:alert].to_s)
  end

  test "destroy_members removes selected members in batch" do
    sign_in @admin

    assert_difference -> { User.count }, -1 do
      delete remove_members_path, params: { user_ids: [ @other_student.id ] }
    end

    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_match(/removed 1 member/i, flash[:notice].to_s)
  end

  test "destroy_member removes member even when survey response versions reference assignments" do
    sign_in @admin

    student_profile = students(:student)
    assignment = survey_assignments(:residential_assignment)

    SurveyResponseVersion.create!(
      student_id: student_profile.student_id,
      survey: surveys(:fall_2025),
      survey_assignment: assignment,
      event: "test_snapshot",
      answers: { "q1" => "3" }
    )

    assert_difference -> { User.count }, -1 do
      delete remove_member_path(users(:student))
    end

    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_match(/removed member/i, flash[:notice].to_s)
  end

  test "destroy_member requires admin (blocks students)" do
    sign_in @student

    assert_no_difference -> { User.count } do
      delete remove_member_path(@other_student)
    end

    assert_redirected_to dashboard_path
    follow_redirect!
    assert_nil flash[:alert] # Students get silent redirect
  end

  test "destroy_member requires admin (blocks advisors)" do
    sign_in @advisor

    assert_no_difference -> { User.count } do
      delete remove_member_path(@other_student)
    end

    assert_redirected_to dashboard_path
    follow_redirect!
    assert_match(/access denied/i, flash[:alert].to_s)
  end

  test "destroy_members requires admin (blocks students)" do
    sign_in @student

    assert_no_difference -> { User.count } do
      delete remove_members_path, params: { user_ids: [ @other_student.id ] }
    end

    assert_redirected_to dashboard_path
    follow_redirect!
    assert_nil flash[:alert] # Students get silent redirect
  end

  test "destroy_members requires admin (blocks advisors)" do
    sign_in @advisor

    assert_no_difference -> { User.count } do
      delete remove_members_path, params: { user_ids: [ @other_student.id ] }
    end

    assert_redirected_to dashboard_path
    follow_redirect!
    assert_match(/access denied/i, flash[:alert].to_s)
  end

  test "debug_users returns expected json" do
    sign_in @admin
    get debug_users_path
    assert_response :success

    payload = JSON.parse(response.body)
    assert payload.key?("users")
    assert payload.key?("role_counts")
  end

  test "manage_students redirects advisors to admin-only people workspace" do
    sign_in @advisor

    get manage_students_path

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_redirected_to dashboard_path
    follow_redirect!
    assert_match(/access denied/i, flash[:alert].to_s)
  end

  test "manage_students for admin shows assignment controls" do
    sign_in @admin

    get manage_students_path

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Save Changes"
    assert_includes response.body, "advisor-management-form"
    assert_includes response.body, "track_updates"
  end

  test "manage_students supports searching" do
    sign_in @admin

    get manage_students_path, params: { q: students(:student).user.email }

    assert_redirected_to people_management_path(tab: "students", q: students(:student).user.email)
    follow_redirect!
    assert_response :success
    assert_includes response.body, students(:student).user.email
  end

  test "advisor dashboard recreates missing advisor profile" do
    advisor_user = users(:advisor)
    Advisor.where(advisor_id: advisor_user.id).delete_all
    advisor_user.reload

    sign_in advisor_user

    assert_difference -> { Advisor.where(advisor_id: advisor_user.id).count }, 1 do
      get advisor_dashboard_path
    end

    assert_response :success
  end

  test "advisor dashboard includes competencies tile" do
    sign_in @advisor

    get advisor_dashboard_path

    assert_response :success
    assert_includes response.body, "Competencies"
    assert_includes response.body, admin_competencies_path
  end

  test "advisor dashboard does not show students needing attention on main dashboard" do
    sign_in @advisor

    get advisor_dashboard_path

    assert_response :success
    refute_includes response.body, "Students Needing Attention"
    refute_includes response.body, "Detailed competencies"
  end

  test "update_student_advisor updates assignment" do
    sign_in @admin
    student = students(:student)
    StudentAdvisorAssignment.delete_all

    patch update_student_advisor_path(student), params: { student: { advisor_id: advisors(:other_advisor).advisor_id } }

    assert_redirected_to people_management_path(tab: "students")
    assert_match "Advisor updated successfully", flash[:notice]
    assert_equal advisors(:other_advisor).advisor_id, student.reload.advisor_id

    assignments = student.advisor_assignments.order(:starts_on, :id).to_a
    assert_equal 2, assignments.size
    assert_equal advisors(:advisor), assignments.first.advisor
    assert_not_nil assignments.first.ends_on
    assert_equal advisors(:other_advisor), assignments.second.advisor
    assert_equal @admin, assignments.second.assigned_by
    assert assignments.second.current?
  ensure
    student.update!(advisor: advisors(:advisor))
  end

  test "update_student_advisor logs admin activity" do
    sign_in @admin
    student = students(:student)

    assert_difference -> { AdminActivityLog.count }, 1 do
      patch update_student_advisor_path(student), params: { student: { advisor_id: advisors(:other_advisor).advisor_id } }
    end

    activity = AdminActivityLog.order(created_at: :desc).first
    assert_equal "advisor_assignment", activity.action
    assert_equal @admin, activity.admin
    assert_equal student, activity.subject
  ensure
    student.update!(advisor: advisors(:advisor))
  end

  test "update_student_advisors applies bulk changes" do
    sign_in @admin

    student = students(:student)
    other_student = students(:other_student)
    StudentAdvisorAssignment.delete_all

    payload = {
      student.student_id => advisors(:other_advisor).advisor_id,
      other_student.student_id => ""
    }

    patch update_student_advisors_path, params: { advisor_updates: payload }
    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match "Updated", flash[:notice]
    assert_equal advisors(:other_advisor).advisor_id, student.reload.advisor_id

    current_assignment = student.advisor_assignments.current.first
    assert_equal advisors(:other_advisor), current_assignment.advisor
    assert_equal @admin, current_assignment.assigned_by
    assert_empty other_student.advisor_assignments.current
  ensure
    student.update!(advisor: advisors(:advisor))
    other_student.update!(advisor: advisors(:other_advisor))
  end

  test "update_student_advisors changes track and logs activity" do
    sign_in @admin

    student = students(:student)
    original_track = student.track_key

    assert_difference -> { AdminActivityLog.where(action: "track_update").count }, 1 do
      patch update_student_advisors_path, params: { track_updates: { student.student_id => "executive" } }
    end

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match "Updated 1 track", flash[:notice]
    assert_equal "Executive", student.reload.track
  ensure
    student.update!(track: original_track)
  end

  test "update_student_advisors updates lifecycle status and logs activity" do
    sign_in @admin

    student = students(:student)

    assert_difference -> { AdminActivityLog.where(action: "student_lifecycle_update").count }, 1 do
      patch update_student_advisors_path, params: { status_updates: { student.student_id => "graduated" } }
    end

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/updated 1 student lifecycle status/i, flash[:notice].to_s)
    assert_equal "graduated", student.reload.status
    assert_not_nil student.graduated_at
  end

  test "update_student_advisors archives selected students in bulk with reason" do
    sign_in @admin

    student = students(:student)

    patch update_student_advisors_path, params: {
      selected_student_ids: [ student.student_id ],
      bulk_status: "archived",
      lifecycle_reason: "Graduated cohort cleanup"
    }

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/updated 1 student lifecycle status/i, flash[:notice].to_s)
    student.reload
    assert_equal "archived", student.status
    assert_equal @admin, student.archived_by
    assert_equal "Graduated cohort cleanup", student.archive_reason
  end

  test "bulk lifecycle update requires selected students" do
    sign_in @admin

    patch update_student_advisors_path, params: { bulk_status: "archived" }

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/select at least one student/i, flash[:alert].to_s)
  end

  test "update_student_advisors rejects invalid lifecycle status" do
    sign_in @admin

    student = students(:student)

    patch update_student_advisors_path, params: { status_updates: { student.student_id => "sabbatical" } }

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/lifecycle update errors/i, flash[:alert].to_s)
    assert_match(/invalid lifecycle status/i, flash[:alert].to_s)
    assert_equal "active", student.reload.status
  end

  test "update_student_advisors rejects invalid track selection" do
    sign_in @admin

    student = students(:student)

    patch update_student_advisors_path, params: { track_updates: { student.student_id => "not-a-track" } }

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/track update errors/i, flash[:alert].to_s)
    assert_match(/invalid track selection/i, flash[:alert].to_s)
  end

  test "update_student_advisors rejects blank track selection when currently assigned" do
    sign_in @admin

    student = students(:student)

    patch update_student_advisors_path, params: { track_updates: { student.student_id => "" } }

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/track update errors/i, flash[:alert].to_s)
    assert_match(/track selection is required/i, flash[:alert].to_s)
  end

  test "update_student_advisors returns alert when no changes submitted" do
    sign_in @admin

    patch update_student_advisors_path, params: {}

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/no student changes were submitted/i, flash[:alert].to_s)
  end

  test "update_student_advisors reports missing students in both advisor and track updates" do
    sign_in @admin

    missing_id = "999999999"

    patch update_student_advisors_path, params: {
      advisor_updates: { missing_id => advisors(:advisor).advisor_id },
      track_updates: { missing_id => "executive" }
    }

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/student ##{missing_id} not found/i, flash[:alert].to_s)
  end

  test "update_student_advisors reports advisor not found" do
    sign_in @admin

    student = students(:student)

    patch update_student_advisors_path, params: { advisor_updates: { student.student_id => "999999" } }

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/advisor update errors/i, flash[:alert].to_s)
    assert_match(/advisor not found/i, flash[:alert].to_s)
  end

  test "student dashboard recreates missing profile" do
    user = users(:student)
    Student.where(student_id: user.id).delete_all
    user.reload

    sign_in user

    assert_difference -> { Student.where(student_id: user.id).count }, 1 do
      get student_dashboard_path
    end

    assert_response :success
  end

  test "student dashboard lists recent notifications" do
    user = users(:student)
    sign_in user

    Notification.delete_all
    Notification.create!(user: user, title: "Welcome", message: "Your dashboard now shows real alerts.")

    get student_dashboard_path

    assert_response :success
    assert_includes response.body, "Welcome"
  end

  test "student dashboard only shows surveys assigned to the student" do
    Student.find(@student.id).update!(program_year: 2026) if Student.find_by(student_id: @student.id)&.program_year.blank?
    sign_in @student

    get student_dashboard_path

    assert_response :success
    assert_includes response.body, "Fall 2025 Health Assessment"
    refute_includes response.body, "Spring 2025 Health Assessment"

    assignment = survey_assignments(:residential_assignment)
    expected_due = "Due: #{I18n.l(assignment.available_until.in_time_zone, format: :long)}"
    assert_includes response.body, expected_due
  end

  test "student dashboard prioritizes assignment custom deadline over survey deadline" do
    sign_in @student

    student_profile = students(:student)
    survey = surveys(:fall_2025)
    assignment = SurveyAssignment.find_or_create_by!(survey_id: survey.id, student_id: student_profile.student_id) do |record|
      record.advisor_id = student_profile.advisor_id
      record.assigned_at = Time.current
    end

    survey.update!(available_until: Time.zone.local(2033, 1, 10, 9, 0))
    assignment.update!(available_until: Time.zone.local(2033, 2, 15, 17, 30), manual: true)

    get student_dashboard_path

    assert_response :success
    assert_includes response.body, "Due: #{I18n.l(assignment.available_until.in_time_zone, format: :long)}"
    assert_not_includes response.body, "Due: #{I18n.l(survey.available_until.in_time_zone, format: :long)}"
  end

  test "student dashboard falls back to survey deadline when assignment deadline is blank" do
    sign_in @student

    student_profile = students(:student)
    survey = surveys(:fall_2025)
    assignment = SurveyAssignment.find_or_create_by!(survey_id: survey.id, student_id: student_profile.student_id) do |record|
      record.advisor_id = student_profile.advisor_id
      record.assigned_at = Time.current
    end

    survey_deadline = Time.zone.local(2034, 3, 20, 14, 45)
    survey.update!(available_until: survey_deadline)
    assignment.update!(available_until: nil)

    get student_dashboard_path

    assert_response :success
    assert_includes response.body, "Due: #{I18n.l(survey_deadline.in_time_zone, format: :long)}"
  end

  test "student dashboard hides past-due incomplete surveys" do
    sign_in @student

    student_profile = students(:student)
    survey = Survey.new(
      title: "Past Due Hidden Survey #{SecureRandom.hex(4)}",
      program_semester: program_semesters(:fall_2025),
      description: "",
      is_active: true,
      available_until: 1.day.ago
    )
    category = survey.categories.build(name: "Category", description: "")
    category.questions.build(
      question_text: "Question",
      question_order: 1,
      question_type: "short_answer",
      is_required: false
    )
    survey.save!

    assignment = SurveyAssignment.create!(
      survey: survey,
      student: student_profile,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      completed_at: nil,
      available_until: 1.day.ago
    )

    past_due = 1.day.ago.change(sec: 0)
    assignment.update!(completed_at: nil, available_until: past_due)

    get student_dashboard_path

    assert_response :success
    refute_includes response.body, survey.title
    refute_includes response.body, survey_path(survey)
  end

  test "student dashboard hides incomplete surveys before available_from" do
    sign_in @student

    student_profile = students(:student)
    survey = Survey.new(
      title: "Future Start Hidden Survey #{SecureRandom.hex(4)}",
      program_semester: program_semesters(:fall_2025),
      description: "",
      is_active: true
    )
    category = survey.categories.build(name: "Category", description: "")
    category.questions.build(
      question_text: "Question",
      question_order: 1,
      question_type: "short_answer",
      is_required: false
    )
    survey.save!

    future_start = 2.days.from_now.change(sec: 0)

    SurveyAssignment.create!(
      survey: survey,
      student: student_profile,
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      completed_at: nil,
      available_from: future_start,
      available_until: future_start + 10.days
    )

    get student_dashboard_path

    assert_response :success
    refute_includes response.body, survey.title
    refute_includes response.body, survey_path(survey)
  end

  test "student dashboard hides incomplete survey after exact available_until timestamp" do
    sign_in @student

    assignment = survey_assignments(:residential_assignment)
    survey = assignment.survey

    travel_to Time.zone.local(2036, 3, 20, 20, 0, 0) do
      assignment.update!(
        completed_at: nil,
        available_from: Time.zone.local(2036, 3, 18, 14, 15, 0),
        available_until: Time.zone.local(2036, 3, 20, 14, 15, 0)
      )

      get student_dashboard_path

      assert_response :success
      refute_includes response.body, survey.title
      refute_includes response.body, survey_path(survey)
    end
  end

  test "student dashboard shows completed surveys regardless of availability window" do
    sign_in @student

    assignment = survey_assignments(:residential_assignment)
    survey = assignment.survey

    assignment.update!(
      completed_at: Time.current,
      available_from: 2.days.from_now,
      available_until: 2.days.ago
    )

    get student_dashboard_path

    assert_response :success
    assert_includes response.body, survey.title
    assert_includes response.body, "Completed"
  end

  test "student dashboard disables edit for archived completed surveys" do
    sign_in @student

    student_profile = students(:student)
    survey = surveys(:fall_2025)
    assignment = SurveyAssignment.find_or_create_by!(survey_id: survey.id, student_id: student_profile.student_id) do |record|
      record.advisor_id = student_profile.advisor_id
      record.assigned_at = 1.day.ago
    end

    assignment.update!(completed_at: Time.current, available_until: 2.days.from_now)
    survey.update!(is_active: false)

    get student_dashboard_path

    assert_response :success
    assert_includes response.body, "Archived"
    assert_includes response.body, "Completed"
    assert_select "span[aria-disabled='true']", text: /Edit/, minimum: 1
  ensure
    survey.update!(is_active: true) if survey&.persisted?
  end

  test "student dashboard shows completion and survey lifecycle status tags" do
    sign_in @student

    student_profile = students(:student)
    semester = program_semesters(:fall_2025)

    in_progress_survey = Survey.new(
      title: "In Progress Status Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      description: "",
      is_active: true
    )
    in_progress_category = in_progress_survey.categories.build(name: "Category", description: "")
    in_progress_question = in_progress_category.questions.build(
      question_text: "Question",
      question_order: 1,
      question_type: "short_answer",
      is_required: false
    )
    in_progress_survey.save!

    not_started_survey = Survey.new(
      title: "Not Started Status Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      description: "",
      is_active: true
    )
    not_started_category = not_started_survey.categories.build(name: "Category", description: "")
    not_started_category.questions.build(
      question_text: "Question",
      question_order: 1,
      question_type: "short_answer",
      is_required: false
    )
    not_started_survey.save!

    SurveyAssignment.find_or_create_by!(survey_id: in_progress_survey.id, student_id: student_profile.student_id) do |record|
      record.advisor_id = student_profile.advisor_id
      record.assigned_at = 1.day.ago
    end

    SurveyAssignment.find_or_create_by!(survey_id: not_started_survey.id, student_id: student_profile.student_id) do |record|
      record.advisor_id = student_profile.advisor_id
      record.assigned_at = 1.day.ago
    end

    StudentQuestion.find_or_create_by!(student_id: student_profile.student_id, question_id: in_progress_question.id) do |record|
      record.advisor_id = student_profile.advisor_id
      record.answer = "Partial response"
    end

    get student_dashboard_path

    assert_response :success
    assert_includes response.body, "Not Started"
    assert_includes response.body, "In Progress"
    assert_includes response.body, "Active"
  end

  test "student dashboard renders even when auto-assigner raises" do
    sign_in @student

    SurveyAssignments::AutoAssigner.stub(:call, ->(student:) { raise "boom" }) do
      get student_dashboard_path
      assert_response :success
    end
  end

  test "student dashboard redirects when current_student is missing" do
    sign_in @advisor

    get student_dashboard_path

    assert_redirected_to dashboard_path
    follow_redirect!
    assert_match "Student profile not found", flash[:alert].to_s
  end

  test "update_student_advisors reports no changes when payload matches current state" do
    sign_in @admin

    student = students(:student)

    patch update_student_advisors_path, params: {
      advisor_updates: { student.student_id => student.advisor_id.to_s },
      track_updates: { student.student_id => student.track_key }
    }

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/no student changes were needed/i, flash[:notice].to_s)
  end

  test "update_student_advisors ignores blank track when student track is already blank" do
    sign_in @admin

    student = students(:student)
    student.update!(track: nil)

    patch update_student_advisors_path, params: {
      track_updates: { student.student_id => "" }
    }

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/no student changes were needed/i, flash[:notice].to_s)
    assert_nil flash[:alert]
  ensure
    student.update!(track: "residential")
  end

  test "update_student_advisors reports failures when a track update raises" do
    sign_in @admin

    student = students(:student)

    AdminActivityLog.stub(:record!, ->(**_) { raise StandardError, "boom" }) do
      patch update_student_advisors_path, params: { track_updates: { student.student_id => "executive" } }
    end

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/track update errors/i, flash[:alert].to_s)
    assert_match(/boom/i, flash[:alert].to_s)
  end

  test "update_student_advisors reports failures when an advisor update raises" do
    sign_in @admin

    student = students(:student)
    new_advisor_id = advisors(:other_advisor).advisor_id

    original_update = Student.instance_method(:update!)
    Student.define_method(:update!) do |*_args|
      raise StandardError, "boom"
    end
    begin
      patch update_student_advisors_path, params: { advisor_updates: { student.student_id => new_advisor_id.to_s } }
    ensure
      Student.define_method(:update!, original_update)
    end

    assert_redirected_to people_management_path(tab: "students")
    follow_redirect!
    assert_match(/advisor update errors/i, flash[:alert].to_s)
    assert_match(/boom/i, flash[:alert].to_s)
  end

  test "admin activities page includes survey log entries" do
    sign_in @admin

    SurveyChangeLog.create!(
      survey: nil,
      admin: @admin,
      action: "preview",
      description: "",
      created_at: Time.current,
      updated_at: Time.current
    )

    get admin_activities_path
    assert_response :success
    assert_includes response.body, "Preview: Survey #"
  end

  test "admin activities page includes admin activity logs" do
    sign_in @admin

    AdminActivityLog.record!(
      admin: @admin,
      action: "student_lifecycle_update",
      description: "Lifecycle status updated for Student User: Active → Graduated"
    )

    get admin_activities_path

    assert_response :success
    assert_includes response.body, "Student Lifecycle Update"
    assert_includes response.body, "Lifecycle status updated for Student User"
  end

  test "update_roles reports failures when an update raises" do
    sign_in @admin

    target = User.find(@other_student.id)
    def target.update!(*_args)
      raise StandardError, "boom"
    end

    original = User.method(:find_by)
    User.stub(:find_by, ->(id:) { id.to_s == target.id.to_s ? target : original.call(id: id) }) do
      patch update_roles_path, params: { role_updates: { target.id => "advisor" } }
    end

    assert_redirected_to people_management_path(tab: "members")
    follow_redirect!
    assert_match(/role update errors/i, flash[:alert].to_s)
    assert_match(/boom/i, flash[:alert].to_s)
  end

  test "advisor dashboard handles admin impersonation" do
    Admin.find_or_create_by!(admin_id: @admin.id)
    @admin.update!(role: "advisor")
    sign_in @admin

    get advisor_dashboard_path
    assert_response :success
  assert_includes response.body, "Advisor Dashboard"
  ensure
    @admin.update!(role: "admin")
  end

  test "admin dashboard aggregates metrics" do
    sign_in @admin
    get admin_dashboard_path
    assert_response :success
  assert_includes response.body, "Admin Dashboard"
    assert_includes response.body, "Data Model Health"
  end

  test "advisor dashboard shows total reports count" do
    sign_in @advisor

    get advisor_dashboard_path
    assert_response :success

    reports_description = extract_feature_description(response.body, "Reports")
    assert_equal "1 generated", reports_description
  end

  test "advisor dashboard excludes graduated advisees from current workload counts" do
    students(:student).graduate!(at: Time.current)
    sign_in @advisor

    get advisor_dashboard_path

    assert_response :success
    assert_equal "0 generated", extract_feature_description(response.body, "Reports")
    assert_equal "0 assigned students", extract_feature_description(response.body, "Survey Records")
  end

  test "admin dashboard shows total reports count" do
    sign_in @admin

    get admin_dashboard_path
    assert_response :success

    reports_description = extract_feature_description(response.body, "Reports")
    assert_equal "3 generated", reports_description
  end

  test "admin dashboard includes recent activities tile" do
    sign_in @admin

    get admin_dashboard_path
    assert_response :success

    assert_includes response.body, "Recent Activities"
    assert_includes response.body, admin_activities_path
  end

  test "admin dashboard includes new navigation tiles" do
    sign_in @admin

    get admin_dashboard_path

    assert_response :success
    assert_includes response.body, "Program Configuration"
    assert_includes response.body, admin_program_setup_path
    assert_includes response.body, "People Management"
    assert_includes response.body, people_management_path
    assert_includes response.body, "Grade Imports"
    assert_includes response.body, admin_grade_import_batches_path
    assert_includes response.body, "Competencies"
    assert_includes response.body, admin_competencies_path
  end

  private

  def extract_feature_description(html, title)
    doc = Nokogiri::HTML.parse(html)

    # Current dashboard tile markup
    tile_node = doc.css(".c-tile").find do |tile|
      tile.at_css(".c-tile__title")&.text&.strip == title
    end
    tile_node&.at_css(".c-tile__description")&.text&.strip
  end
end
