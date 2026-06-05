require "test_helper"

class DashboardsControllerPrivateTest < ActionController::TestCase
  tests DashboardsController

  setup do
    @admin = users(:admin)
    @student = students(:student)
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in @admin
  end

  test "normalizes member ids from string array and unsupported values" do
    assert_equal [ 1, 2, 3 ], @controller.send(:normalize_member_ids, "1, 2  0 nope 3")
    assert_equal [ 4, 5 ], @controller.send(:normalize_member_ids, [ "4", "", "5", "5", "-1" ])
    assert_equal [], @controller.send(:normalize_member_ids, nil)
  end

  test "resolves dashboard paths for every role fallback" do
    assert_equal student_dashboard_path, @controller.send(:dashboard_path_for_role, User.roles[:student])
    assert_equal advisor_dashboard_path, @controller.send(:dashboard_path_for_role, User.roles[:advisor])
    assert_equal admin_dashboard_path, @controller.send(:dashboard_path_for_role, User.roles[:admin])
    assert_equal dashboard_path, @controller.send(:dashboard_path_for_role, "unknown")
  end

  test "lifecycle attributes cover all status transitions" do
    active = @controller.send(:lifecycle_status_attributes, "active", "reason")
    assert_equal "active", active[:status]
    assert_nil active[:graduated_at]
    assert_nil active[:archived_at]
    assert_nil active[:archived_by]
    assert_nil active[:archive_reason]

    graduated = @controller.send(:lifecycle_status_attributes, "graduated", nil)
    assert_equal "graduated", graduated[:status]
    assert_not_nil graduated[:graduated_at]
    assert_nil graduated[:archived_at]

    archived = @controller.send(:lifecycle_status_attributes, "archived", "cleanup")
    assert_equal "archived", archived[:status]
    assert_equal @admin, archived[:archived_by]
    assert_equal "cleanup", archived[:archive_reason]

    %w[inactive withdrawn].each do |status|
      attrs = @controller.send(:lifecycle_status_attributes, status, nil)
      assert_equal status, attrs[:status]
      assert_nil attrs[:graduated_at]
      assert_nil attrs[:archived_at]
    end

    assert_equal({ status: "custom" }, @controller.send(:lifecycle_status_attributes, "custom", nil))
  end

  test "survey record counts handles all students empty advisor scope and selected ids" do
    assert_operator @controller.send(:survey_record_counts)[:assigned], :>=, 1
    assert_equal({ assigned: 0, completed: 0 }, @controller.send(:survey_record_counts, student_ids: []))

    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current)
    counts = @controller.send(:survey_record_counts, student_ids: [ assignment.student_id ])

    assert_equal 1, counts[:assigned]
    assert_equal 1, counts[:completed]
  end

  test "loads advisor lookup only when ids are present" do
    assert_equal({}, @controller.send(:build_advisor_lookup, [ "", nil ]))

    lookup = @controller.send(:build_advisor_lookup, [ advisors(:advisor).advisor_id.to_s, "bad" ])
    assert_equal advisors(:advisor), lookup[advisors(:advisor).advisor_id]
  end

  test "assignment group update records updates noops and failures" do
    successes = []
    failures = []
    @student.update!(assignment_group: "A") if @student.respond_to?(:assignment_group=)

    @controller.send(:apply_assignment_group_update, @student, "A", successes, failures)
    assert_empty successes
    assert_empty failures

    @controller.send(:apply_assignment_group_update, @student, "B", successes, failures)
    assert_includes successes.join(" "), "A"
    assert_includes successes.join(" "), "B"
    assert_equal "B", @student.reload.assignment_group if @student.respond_to?(:assignment_group)

    broken_student = Student.find(@student.student_id)
    def broken_student.update!(*)
      raise StandardError, "cannot save group"
    end

    @controller.send(:apply_assignment_group_update, broken_student, "C", successes, failures)
    assert_includes failures.join(" "), "cannot save group"
  end

  test "student display label falls back from name to email to id" do
    user_with_name = Struct.new(:name, :email).new("Named Student", "named@example.edu")
    user_with_email = Struct.new(:name, :email).new("", "email@example.edu")
    label_student = Struct.new(:user, :student_id).new(user_with_name, 123)
    email_student = Struct.new(:user, :student_id).new(user_with_email, 456)
    id_student = Struct.new(:user, :student_id).new(nil, 789)

    assert_equal "Named Student", @controller.send(:student_display_label, label_student)
    assert_equal "email@example.edu", @controller.send(:student_display_label, email_student)
    assert_equal "Student #789", @controller.send(:student_display_label, id_student)
  end

  test "build assignment group options combines sources and falls back on errors" do
    options = @controller.send(:build_assignment_group_select_options)
    assert_equal [ "Unassigned", "" ], options.first

    SurveyOffering.stub(:data_source_ready?, -> { raise StandardError, "missing table" }) do
      assert_equal [ [ "Unassigned", "" ] ], @controller.send(:build_assignment_group_select_options)
    end
  end

  test "required question and load students handle nil advisor and admin paths" do
    assert_equal false, @controller.send(:required_question?, nil)
    assert_includes @controller.send(:load_students).map(&:student_id), @student.student_id

    sign_out @admin
    advisor_user = users(:advisor)
    sign_in advisor_user
    scoped_ids = @controller.send(:load_students).map(&:student_id)

    assert_includes scoped_ids, students(:student).student_id
    refute_includes scoped_ids, students(:other_student).student_id
  end

  test "normalizes student update hashes and selected ids" do
    raw = ActionController::Parameters.new({ @student.student_id.to_s => "residential", "bad" => "executive" })

    assert_equal(
      { @student.student_id.to_s => "residential", "bad" => "executive" },
      @controller.send(:normalize_student_updates, raw)
    )
    assert_equal({}, @controller.send(:normalize_student_updates, nil))
    assert_equal({}, @controller.send(:normalize_student_updates, ""))
    assert_equal [ 1, 2, 3 ], @controller.send(:normalize_student_ids, "1, 2 nope 3 0 -1")
    assert_equal [ 4, 5 ], @controller.send(:normalize_student_ids, [ "4", "5", "5", "", nil ])
    assert_equal [], @controller.send(:normalize_student_ids, 7)
  end

  test "apply track update handles blank invalid unchanged success and failure" do
    successes = []
    failures = []
    @student.update!(track: nil)

    @controller.send(:apply_track_update, @student, "", successes, failures)
    assert_empty successes
    assert_empty failures

    @student.update!(track: "residential")
    @controller.send(:apply_track_update, @student, "", successes, failures)
    assert_includes failures.last, "track selection is required"

    @controller.send(:apply_track_update, @student, "not-a-track", successes, failures)
    assert_includes failures.last, "invalid track selection"

    @student.update!(track: "residential")
    @controller.send(:apply_track_update, @student, "residential", successes, failures)
    assert_empty successes

    new_track = (Student.tracks.keys - [ "residential" ]).first || "executive"
    @controller.send(:apply_track_update, @student, new_track, successes, failures)
    assert_includes successes.last, new_track.titleize

    broken_student = Student.find(@student.student_id)
    def broken_student.update!(*)
      raise StandardError, "track save failed"
    end
    @controller.send(:apply_track_update, broken_student, "residential", successes, failures)
    assert_includes failures.last, "track save failed"
  end

  test "apply advisor update handles missing unchanged assignment clearing and failure" do
    successes = []
    failures = []
    advisor = advisors(:advisor)
    other_advisor = advisors(:other_advisor)
    lookup = { advisor.advisor_id => advisor, other_advisor.advisor_id => other_advisor }
    @student.update!(advisor: advisor)

    @controller.send(:apply_advisor_update, @student, "999999", lookup, successes, failures)
    assert_includes failures.last, "advisor not found"

    @controller.send(:apply_advisor_update, @student, advisor.advisor_id.to_s, lookup, successes, failures)
    assert_empty successes

    @controller.send(:apply_advisor_update, @student, other_advisor.advisor_id.to_s, lookup, successes, failures)
    assert_includes successes.last, other_advisor.display_name

    @controller.send(:apply_advisor_update, @student, "", lookup, successes, failures)
    assert_includes successes.last, "Unassigned"
    assert_nil @student.reload.advisor_id

    broken_student = Student.find(@student.student_id)
    def broken_student.update!(*)
      raise StandardError, "advisor save failed"
    end
    @controller.send(:apply_advisor_update, broken_student, advisor.advisor_id.to_s, lookup, successes, failures)
    assert_includes failures.last, "advisor save failed"
  end

  test "apply status update handles blank invalid unchanged success and failure" do
    successes = []
    failures = []
    @student.update!(status: "active", graduated_at: nil, archived_at: nil)

    @controller.send(:apply_status_update, @student, "", nil, successes, failures)
    assert_empty successes
    assert_empty failures

    @controller.send(:apply_status_update, @student, "not-real", nil, successes, failures)
    assert_includes failures.last, "invalid lifecycle status"

    @controller.send(:apply_status_update, @student, "active", nil, successes, failures)
    assert_empty successes

    @controller.send(:apply_status_update, @student, "graduated", "done", successes, failures)
    assert_includes successes.last, "Graduated"
    assert_equal "graduated", @student.reload.status

    broken_student = Student.find(@student.student_id)
    def broken_student.update!(*)
      raise StandardError, "status save failed"
    end
    @controller.send(:apply_status_update, broken_student, "active", nil, successes, failures)
    assert_includes failures.last, "status save failed"
  end

  test "profile admin and role switch guards cover allowed and denied paths" do
    assert_nil @controller.send(:ensure_profile_present)
    assert_equal true, @controller.send(:ensure_admin!)

    sign_out @admin
    sign_in users(:student)
    @controller.stub(:redirect_to, nil) do
      assert_equal false, @controller.send(:ensure_admin!)
    end

    sign_out users(:student)
    sign_in users(:advisor)
    @controller.stub(:redirect_to, nil) do
      assert_equal false, @controller.send(:ensure_admin!)
    end

    assert_nil @controller.send(:ensure_role_switch_allowed)
  end

  test "surveys for student handles nil and auto assignment errors" do
    assert_equal 0, @controller.send(:surveys_for_student, nil).count

    SurveyAssignments::AutoAssigner.stub(:call, ->(**) { raise StandardError, "assign failed" }) do
      assert_equal 0, @controller.send(:surveys_for_student, @student).count
    end
  end

  test "student profile warnings report each missing field and skip complete students" do
    complete = Struct.new(:track_key, :program_year, :advisor_id, :uin, :current_record?, :user, :student_id).new(
      "residential",
      2026,
      advisors(:advisor).advisor_id,
      "111111111",
      true,
      Struct.new(:name, :email).new("Complete Student", "complete@example.edu"),
      100
    )
    missing = Struct.new(:track_key, :program_year, :advisor_id, :uin, :current_record?, :user, :student_id).new(
      nil,
      nil,
      nil,
      "",
      true,
      Struct.new(:name, :email).new("", "missing@example.edu"),
      101
    )

    warnings = @controller.send(:build_student_profile_warnings, [ complete, missing ])
    keys = warnings.map { |warning| warning[:key] }

    assert_equal %i[missing_track missing_class_year missing_advisor missing_uin], keys
    assert warnings.all? { |warning| warning[:students] == [ "missing@example.edu" ] }
    assert_empty @controller.send(:build_student_profile_warnings, [ complete ])
  end

  test "dashboard notification scope follows in-app notification preference" do
    notification = Notification.create!(
      user: @admin,
      title: "Coverage Notice",
      message: "Visible when enabled"
    )

    @controller.stub(:in_app_notifications_enabled_for?, false) do
      assert_equal 0, @controller.send(:dashboard_notifications_scope).count
    end

    @controller.stub(:in_app_notifications_enabled_for?, true) do
      assert_includes @controller.send(:dashboard_notifications_scope), notification
    end
  end

  test "ensure profile present creates missing student and advisor profiles" do
    student_user = User.create!(name: "No Profile Student", email: "profile-student@example.edu", uid: "profile-student-uid", role: :student)
    advisor_user = User.create!(name: "No Profile Advisor", email: "profile-advisor@example.edu", uid: "profile-advisor-uid", role: :advisor)
    student_user.student_profile&.destroy!
    advisor_user.advisor_profile&.destroy!
    student_user.reload
    advisor_user.reload

    sign_out @admin
    sign_in student_user
    assert_difference -> { Student.count }, 1 do
      @controller.send(:ensure_profile_present)
    end
    assert_equal student_user.student_profile, @controller.instance_variable_get(:@current_student)

    sign_out student_user
    sign_in advisor_user
    assert_difference -> { Advisor.count }, 1 do
      @controller.send(:ensure_profile_present)
    end
    assert_equal advisor_user.advisor_profile, @controller.instance_variable_get(:@current_advisor)
  end

  test "surveys for student returns assigned surveys when auto assignment succeeds" do
    SurveyAssignments::AutoAssigner.stub(:call, true) do
      surveys = @controller.send(:surveys_for_student, @student)

      assert_includes surveys.map(&:id), surveys(:fall_2025).id
    end
  end

  test "destroy members handles empty selection missing users self protection and removals" do
    delete :destroy_members, params: { user_ids: "" }
    assert_redirected_to people_management_path(tab: "members")
    assert_match "No members were selected", flash[:alert]

    removable = User.create!(
      name: "Temporary Member",
      email: "temporary-member@example.edu",
      uid: "temporary-member-uid",
      role: :advisor
    )
    removable.advisor_profile&.destroy!

    assert_difference -> { User.count }, -1 do
      delete :destroy_members, params: { user_ids: [ @admin.id, 999_999, removable.id ] }
    end

    assert_redirected_to people_management_path(tab: "members")
    assert_match "Removed 1 member", flash[:notice]
    assert_match "cannot remove your own account", flash[:notice]
    assert_match "not found", flash[:notice]

    delete :destroy_members, params: { user_ids: [ @admin.id, 999_998 ] }
    assert_redirected_to people_management_path(tab: "members")
    assert_match "We could not remove", flash[:alert]
  end

  test "switch role covers invalid no-op success and failure paths" do
    post :switch_role, params: { role: "missing" }
    assert_redirected_to dashboard_path
    assert_match "Unrecognized", flash[:alert]

    post :switch_role, params: { role: @admin.role }
    assert_redirected_to @controller.send(:dashboard_path_for_role, @admin.role)
    assert_match "Already viewing", flash[:notice]

    role_user = User.create!(
      name: "Role Switcher",
      email: "role-switcher@example.edu",
      uid: "role-switcher-uid",
      role: :admin
    )
    sign_out @admin
    sign_in role_user

    post :switch_role, params: { role: "advisor" }
    assert_redirected_to advisor_dashboard_path
    assert_equal "advisor", role_user.reload.role

    SurveyAssignments::AutoAssigner.stub(:call, ->(**) { raise StandardError, "assignment failed" }) do
      post :switch_role, params: { role: "student" }
    end

    assert_redirected_to dashboard_path
    assert_match "could not switch roles", flash[:alert]
  end

  test "bulk student updates cover empty bulk missing records and mixed successes" do
    patch :update_student_advisors, params: {}
    assert_redirected_to people_management_path(tab: "students")
    assert_match "No student changes", flash[:alert]

    patch :update_student_advisors, params: { bulk_status: "graduated", selected_student_ids: "" }
    assert_redirected_to people_management_path(tab: "students")
    assert_match "Select at least one student", flash[:alert]

    advisor = advisors(:advisor)
    other_advisor = advisors(:other_advisor)
    @student.update!(
      advisor: advisor,
      track: "residential",
      program_year: 2026,
      assignment_group: "A",
      status: "active"
    )
    new_year = (ProgramYear.values.map(&:to_i) - [ 2026 ]).first || 2027

    patch :update_student_advisors, params: {
      advisor_updates: {
        @student.student_id => other_advisor.advisor_id,
        "999999" => other_advisor.advisor_id
      },
      track_updates: {
        @student.student_id => "executive",
        "999998" => "executive"
      },
      program_year_updates: {
        @student.student_id => new_year.to_s,
        "999997" => new_year.to_s
      },
      assignment_group_updates: {
        @student.student_id => "B",
        "999996" => "B"
      },
      status_updates: {
        @student.student_id => "graduated",
        "999995" => "graduated"
      },
      lifecycle_reason: "Coverage transition"
    }

    assert_redirected_to people_management_path(tab: "students")
    assert_match "Updated", flash[:notice]
    assert_match "not found", flash[:alert]
    @student.reload
    assert_equal other_advisor.advisor_id, @student.advisor_id
    assert_equal "executive", @student.track_key
    assert_equal new_year, @student.program_year
    assert_equal "B", @student.assignment_group
    assert_equal "graduated", @student.status
  end

  test "program year update handles blank invalid unchanged success and failure" do
    successes = []
    failures = []
    @student.update!(program_year: nil)

    @controller.send(:apply_program_year_update, @student, "", successes, failures)
    assert_empty successes
    assert_empty failures

    @student.update!(program_year: 2026)
    @controller.send(:apply_program_year_update, @student, "", successes, failures)
    assert_includes failures.last, "class year selection is required"

    @controller.send(:apply_program_year_update, @student, "abcd", successes, failures)
    assert_includes failures.last, "invalid class year selection"

    @controller.send(:apply_program_year_update, @student, "2026", successes, failures)
    assert_empty successes

    new_year = (ProgramYear.values.map(&:to_i) - [ 2026 ]).first || 2027
    @controller.send(:apply_program_year_update, @student, new_year.to_s, successes, failures)
    assert_includes successes.last, new_year.to_s

    broken_student = Student.find(@student.student_id)
    def broken_student.update!(*)
      raise StandardError, "year save failed"
    end
    @controller.send(:apply_program_year_update, broken_student, "2026", successes, failures)
    assert_includes failures.last, "year save failed"
  end

  test "management state helpers load searched members and students" do
    @controller.params = ActionController::Parameters.new(q: @admin.email)
    @controller.send(:load_member_management_state)
    users = @controller.instance_variable_get(:@users)
    assert_includes users.map(&:id), @admin.id
    assert_equal User.admins.count, @controller.instance_variable_get(:@role_counts)[:admin]

    @controller.params = ActionController::Parameters.new(q: users(:student).email, student_status: "all")
    @controller.send(:load_student_management_state)
    students = @controller.instance_variable_get(:@students)
    assert_includes students.map(&:student_id), students(:student).student_id
    assert_equal true, @controller.instance_variable_get(:@can_manage)
    assert @controller.instance_variable_get(:@advisor_select_options).any?
    assert @controller.instance_variable_get(:@program_year_select_options).any?
  end
end
