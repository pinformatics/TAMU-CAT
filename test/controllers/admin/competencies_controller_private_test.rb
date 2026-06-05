require "test_helper"
require "csv"

class Admin::CompetenciesControllerPrivateTest < ActionController::TestCase
  tests Admin::CompetenciesController

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in users(:admin)
  end

  test "remembered filter params store clear and reuse session filters" do
    @controller.params = ActionController::Parameters.new(
      q: "student",
      competencies: [ " Communication ", "", "Systems Thinking" ]
    )

    stored = @controller.send(:remembered_competency_filter_params)
    assert_equal "student", stored["q"]
    assert_equal [ "Communication", "Systems Thinking" ], stored["competencies"]
    assert_equal stored, session[Admin::CompetenciesController::FILTER_SESSION_KEY]

    @controller.remove_instance_variable(:@remembered_competency_filter_params)
    @controller.params = ActionController::Parameters.new
    assert_equal stored, @controller.send(:remembered_competency_filter_params)

    @controller.remove_instance_variable(:@remembered_competency_filter_params)
    @controller.params = ActionController::Parameters.new(clear_filters: "1")
    assert_equal({}, @controller.send(:remembered_competency_filter_params))
    assert_nil session[Admin::CompetenciesController::FILTER_SESSION_KEY]
  end

  test "filter helpers compact query and detect filter requests" do
    @controller.params = ActionController::Parameters.new
    refute @controller.send(:competency_filter_request?)

    @controller.params = ActionController::Parameters.new(domain: "Leadership")
    assert @controller.send(:competency_filter_request?)

    query = @controller.send(:competency_filter_query, {
      q: "student",
      track: "",
      program_year: "2026",
      advisor_id: nil,
      semester: "Fall 2025",
      domain: "Leadership",
      student_status: "all",
      competencies: [ "Communication" ]
    })

    assert_equal "student", query["q"]
    assert_equal "2026", query["program_year"]
    assert_equal [ "Communication" ], query["competencies"]
    refute query.key?("track")
    refute query.key?("advisor_id")
  end

  test "accessible scope and guards cover admin advisor student and anonymous users" do
    assert_includes @controller.send(:accessible_student_scope).map(&:student_id), students(:student).student_id

    @controller.stub(:current_user, users(:advisor)) do
      @controller.stub(:current_advisor_profile, advisors(:advisor)) do
        ids = @controller.send(:accessible_student_scope).map(&:student_id)
        assert_includes ids, students(:student).student_id
        refute_includes ids, students(:other_student).student_id
      end
    end

    @controller.stub(:current_user, OpenStruct.new(role_admin?: false, role_advisor?: true, role_student?: false)) do
      @controller.stub(:current_advisor_profile, nil) do
        assert_empty @controller.send(:accessible_student_scope).to_a
      end
    end

    captured = nil
    @controller.stub(:redirect_to, ->(*args, **kwargs) { captured = [ args, kwargs ]; true }) do
      @controller.stub(:current_user, nil) do
        @controller.send(:require_competency_access!)
        assert_equal dashboard_path, captured.first.first
        assert_equal ApplicationController::STAFF_ONLY_MESSAGE, captured.second[:alert]
      end

      @controller.stub(:current_user, users(:student)) do
        @controller.send(:require_competency_access!)
        assert_equal dashboard_path, captured.first.first
        assert_equal ApplicationController::STAFF_ONLY_MESSAGE, captured.second[:alert]
      end
    end
  end

  test "competencies csv handles empty domains students and missing ratings" do
    payload = {
      domains: [
        { name: "Domain", competencies: [ { title: "Communication" } ] }
      ],
      students: [
        { id: 1, name: "Ada", email: "ada@example.com", ratings: {} }
      ],
      filters: {},
      course_competency_rule_label: "Max"
    }

    csv = CSV.parse(@controller.send(:competencies_csv, payload), headers: true)

    assert_equal "Ada", csv.first["Student Name"]
    assert_equal "All semesters", csv.first["Semester Filter"]
    assert_equal "Domain", csv.first["Communication Domain"]
    assert_nil csv.first["Communication Self Rating"]
  end
end
