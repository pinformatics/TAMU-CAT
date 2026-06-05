require "test_helper"

class Assignments::SurveysControllerPrivateTest < ActionController::TestCase
  tests Assignments::SurveysController

  setup do
    @survey = surveys(:fall_2025)
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in users(:admin)
    @controller.instance_variable_set(:@survey, @survey)
  end

  test "assignable students and bulk student filters respect role track and year" do
    assert_includes @controller.send(:assignable_students).map(&:student_id), students(:student).student_id

    @survey.update!(track: "Residential")
    assert_includes @controller.send(:eligible_students_for_track).map(&:student_id), students(:student).student_id
    refute_includes @controller.send(:eligible_students_for_track).map(&:student_id), students(:other_student).student_id

    filtered = @controller.send(:students_for_bulk_action, track_filter: "Residential", year_filter: students(:student).program_year.to_s)
    assert_operator filtered.count, :positive?
    assert filtered.all? { |student| student.track_key == "residential" && student.program_year == students(:student).program_year }

    @survey.update!(track: nil, title: "Executive Final Survey")
    @controller.remove_instance_variable(:@survey_track_key) if @controller.instance_variable_defined?(:@survey_track_key)
    inferred = @controller.send(:students_for_bulk_action, track_filter: "", year_filter: "")
    assert_operator inferred.count, :positive?
    assert inferred.all? { |student| student.track_key == "executive" }

    @survey.update!(track: nil, title: "General Final Survey")
    @controller.remove_instance_variable(:@survey_track_key) if @controller.instance_variable_defined?(:@survey_track_key)
    assert_operator @controller.send(:students_for_bulk_action, track_filter: "", year_filter: "").count, :>=, 2

    sign_out users(:admin)
    sign_in users(:advisor)
    advisor_ids = @controller.send(:assignable_students).map(&:student_id)
    assert_equal users(:advisor).advisor_profile.advisees.map(&:student_id).sort, advisor_ids.sort
  end

  test "selected ids and datetime helpers normalize blank invalid and fallback values" do
    set_controller_params(student_ids: [ "1, 2", "", [ "2", " 3 " ], nil ])
    assert_equal [ "1", "2", "3" ], @controller.send(:selected_student_ids)

    assert_nil @controller.send(:datetime_local_value, nil)
    time = Time.zone.local(2030, 1, 2, 3, 4)
    assert_equal "2030-01-02T03:04", @controller.send(:datetime_local_value, time)
    assert_equal I18n.l(time, format: :long), @controller.send(:format_timestamp, time)

    I18n.stub(:l, ->(*) { raise I18n::InvalidLocale.new(:xx) }) do
      assert_equal time.to_fs(:long), @controller.send(:format_timestamp, time)
      assert_equal Time.current.to_fs(:long), @controller.send(:timestamp_str)
    end
  end

  test "date parsers handle valid blank invalid and memoized parameters" do
    set_controller_params(
      available_from: "2030-01-02 03:04",
      available_until: "bad date",
      new_available_until: ""
    )

    assert_equal Time.zone.parse("2030-01-02 03:04"), @controller.send(:parsed_available_from)
    assert_nil @controller.send(:parsed_available_until)
    assert_nil @controller.send(:parsed_extension_available_until)

    set_controller_params(available_from: "changed")
    assert_equal Time.zone.parse("2030-01-02 03:04"), @controller.send(:parsed_available_from)

    @controller.remove_instance_variable(:@parsed_extension_available_until)
    set_controller_params(new_available_until: "2030-02-03 04:05")
    assert_equal Time.zone.parse("2030-02-03 04:05"), @controller.send(:parsed_extension_available_until)
  end

  test "survey datetime parser redirects only for invalid submitted values" do
    set_controller_params(survey: { available_from: "", available_until: "2031-04-05 09:30" })

    assert_nil @controller.send(:parsed_survey_datetime, :available_from)
    assert_equal Time.zone.parse("2031-04-05 09:30"), @controller.send(:parsed_survey_datetime, :available_until)

    set_controller_params(survey: { available_from: "not a date" })
    @controller.stub(:redirect_to, nil) do
      assert_nil @controller.send(:parsed_survey_datetime, :available_from)
    end
  end

  test "deadline and mutation guards return correct allowed denied states" do
    @survey.update!(available_until: Time.zone.local(2030, 5, 1, 12, 0), is_active: true)

    assert_equal true, @controller.send(:ensure_deadline_not_before_survey!, nil)
    assert_equal true, @controller.send(:ensure_deadline_not_before_survey!, Time.zone.local(2030, 5, 1, 12, 0))

    @controller.stub(:redirect_to, nil) do
      assert_equal false, @controller.send(:ensure_deadline_not_before_survey!, Time.zone.local(2030, 4, 1, 12, 0))
    end

    assert_nil @controller.send(:ensure_survey_active_for_mutation!)
    @survey.update!(is_active: false)
    @controller.stub(:redirect_to, nil) do
      assert_nil @controller.send(:ensure_survey_active_for_mutation!)
    end

    assert_nil @controller.send(:require_admin_for_survey_availability!)
    sign_out users(:admin)
    sign_in users(:advisor)
    @controller.stub(:redirect_to, nil) do
      assert_nil @controller.send(:require_admin_for_survey_availability!)
    end
  end

  test "inherited assignment sync covers nil exact date and survey offering updates" do
    assignment_nil = survey_assignments(:residential_assignment)
    assignment_nil.update!(available_from: nil, available_until: nil)
    previous_deadline = Time.zone.local(2030, 4, 1, 12, 0)
    assignment_date = SurveyAssignment.create!(
      survey: @survey,
      student: students(:other_student),
      advisor: advisors(:other_advisor),
      assigned_at: Time.current,
      available_from: previous_deadline,
      available_until: previous_deadline
    )

    @controller.send(
      :sync_inherited_assignment_column!,
      scope: SurveyAssignment.where(survey_id: @survey.id),
      column: :available_from,
      previous_value: nil,
      new_value: Time.zone.local(2030, 3, 1, 12, 0)
    )
    assert_equal Time.zone.local(2030, 3, 1, 12, 0), assignment_nil.reload.available_from

    @controller.send(
      :sync_inherited_assignment_column!,
      scope: SurveyAssignment.where(survey_id: @survey.id),
      column: :available_until,
      previous_value: previous_deadline,
      new_value: Time.zone.local(2030, 6, 1, 12, 0)
    )
    assert_equal Time.zone.local(2030, 6, 1, 12, 0), assignment_date.reload.available_until

    @survey.update!(available_from: Time.zone.local(2030, 7, 1, 12, 0), available_until: Time.zone.local(2030, 8, 1, 12, 0))
    SurveyOffering.stub(:data_source_ready?, false) do
      assert_nil @controller.send(:sync_inherited_availability!, previous_available_from: Time.zone.local(2029, 1, 1), previous_available_until: Time.zone.local(2029, 2, 1))
    end
  end

  test "survey track key detects explicit executive residential and no-track states" do
    @survey.update!(track: "Executive", title: "Residential in title")
    @controller.remove_instance_variable(:@survey_track_key) if @controller.instance_variable_defined?(:@survey_track_key)
    assert_equal "executive", @controller.send(:survey_track_key)

    @survey.update!(track: nil, title: "Residential Midpoint Survey")
    @controller.remove_instance_variable(:@survey_track_key)
    assert_equal "residential", @controller.send(:survey_track_key)

    @survey.update!(track: nil, title: "General Survey")
    @controller.remove_instance_variable(:@survey_track_key)
    assert_nil @controller.send(:survey_track_key)
    assert_equal Student.count, @controller.send(:students_for_bulk_action, track_filter: "", year_filter: "").count
    assert_equal Student.count, @controller.send(:students_for_bulk_action, track_filter: "not-a-track", year_filter: "").count
  end

  test "upsert assignment applies survey defaults parsed overrides and offering defaults" do
    student = students(:student)
    SurveyAssignment.where(survey: @survey, student: student).delete_all
    @survey.update!(
      available_from: Time.zone.local(2030, 1, 1, 8, 0),
      available_until: Time.zone.local(2030, 2, 1, 17, 0)
    )
    set_controller_params(
      available_from: "2030-01-05 09:30",
      available_until: "2030-02-05 18:45"
    )

    assignment, created = @controller.send(:upsert_assignment_for, student)

    assert created
    assert assignment.manual? if assignment.respond_to?(:manual?)
    assert_equal Time.zone.local(2030, 1, 5, 9, 30), assignment.available_from
    assert_equal Time.zone.local(2030, 2, 5, 18, 45), assignment.available_until
    assert_nil assignment.completed_at

    offering = Struct.new(:class_of, :available_from, :available_until)
    offerings = Struct.new(:rows) do
      def where(*_args) = self
      def exists? = rows.any?
      def find(&block) = rows.find(&block)
      def first = rows.first
    end
    offering_start = Time.zone.local(2030, 3, 1, 9, 0)
    offering_end = Time.zone.local(2030, 4, 1, 17, 0)
    @controller.remove_instance_variable(:@parsed_available_from)
    @controller.remove_instance_variable(:@parsed_available_until)
    set_controller_params({})
    assignment.destroy!

    SurveyOffering.stub(:data_source_ready?, true) do
      SurveyOffering.stub(:for_student, offerings.new([ offering.new(student.program_year, offering_start, offering_end) ])) do
        assignment, = @controller.send(:upsert_assignment_for, student)

        assert_equal offering_start, assignment.available_from
        assert_equal offering_end, assignment.available_until
      end
    end
  end

  test "sync inherited availability updates offerings when source is ready" do
    offering = SurveyOffering.create!(
      survey: @survey,
      track: "Residential",
      stage: "midpoint",
      class_of: students(:student).program_year,
      available_from: Time.zone.local(2030, 1, 1, 8, 0),
      available_until: Time.zone.local(2030, 2, 1, 17, 0)
    )
    @survey.update!(
      available_from: Time.zone.local(2030, 5, 1, 8, 0),
      available_until: Time.zone.local(2030, 6, 1, 17, 0)
    )

    SurveyOffering.stub(:data_source_ready?, true) do
      @controller.send(
        :sync_inherited_availability!,
        previous_available_from: Time.zone.local(2029, 1, 1),
        previous_available_until: Time.zone.local(2029, 2, 1)
      )
    end

    assert_equal @survey.available_from.to_i, offering.reload.available_from.to_i
    assert_equal @survey.available_until.to_i, offering.reload.available_until.to_i
  end

  private

  def set_controller_params(params_hash)
    @controller.instance_variable_set(:@_params, ActionController::Parameters.new(params_hash))
  end
end
