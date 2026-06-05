require "test_helper"

class ApplicationControllerTest < ActiveSupport::TestCase
  test "current_student memoizes the student's profile" do
    controller = ApplicationController.new
    user = users(:student)

    controller.singleton_class.define_method(:current_user) { user }
    first = controller.send(:current_student)
    second = controller.send(:current_student)

    assert_same first, second
    assert_equal students(:student), first
  ensure
    controller.singleton_class.send(:remove_method, :current_user)
  end

  test "current profile helpers handle anonymous users" do
    controller = ApplicationController.new

    controller.singleton_class.define_method(:current_user) { nil }

    assert_nil controller.send(:current_student)
    assert_nil controller.send(:current_advisor_profile)
  ensure
    controller.singleton_class.send(:remove_method, :current_user) if controller.singleton_class.method_defined?(:current_user)
  end

  test "current_advisor_profile memoizes advisor profile" do
    controller = ApplicationController.new
    user = users(:advisor)

    controller.singleton_class.define_method(:current_user) { user }
    first = controller.send(:current_advisor_profile)
    second = controller.send(:current_advisor_profile)

    assert_same first, second
    assert_equal advisors(:advisor), first
  ensure
    controller.singleton_class.send(:remove_method, :current_user)
  end

  test "load_notification_state sets unread counts and unread nav notifications" do
    controller = ApplicationController.new
    user = users(:student)
    Notification.create!(user: user, title: "Read nav item", message: "Should stay out of the nav menu.", read_at: Time.current)

    controller.singleton_class.define_method(:current_user) { user }
    controller.send(:load_notification_state)

    assert_equal user.notifications.unread.count, controller.instance_variable_get(:@unread_notification_count)
    recent_notifications = controller.instance_variable_get(:@recent_notifications)
    assert_equal ApplicationController::NAV_NOTIFICATION_LIMIT, recent_notifications.limit_value
    assert_equal ApplicationController::NAV_NOTIFICATION_LIMIT, controller.instance_variable_get(:@notification_menu_limit)
    assert recent_notifications.to_a.all? { |notification| !notification.read? }
  ensure
    controller.singleton_class.send(:remove_method, :current_user)
  end

  test "load_notification_state hides nav notifications when in app notifications are disabled" do
    controller = ApplicationController.new
    user = users(:student)
    user.update!(in_app_notifications_enabled: false)
    Notification.create!(user: user, title: "Muted nav item", message: "Should stay hidden.")

    controller.singleton_class.define_method(:current_user) { user }
    controller.send(:load_notification_state)

    assert_equal 0, controller.instance_variable_get(:@unread_notification_count)
    assert_equal [], controller.instance_variable_get(:@recent_notifications).to_a
    assert_equal ApplicationController::NAV_NOTIFICATION_LIMIT, controller.instance_variable_get(:@notification_menu_limit)
  ensure
    controller.singleton_class.send(:remove_method, :current_user) if controller.singleton_class.method_defined?(:current_user)
  end

  test "fallback semester label returns formatted timestamp" do
    controller = ApplicationController.new
    label = controller.send(:fallback_semester_label)

    assert_match(/\A[A-Z][a-z]+ \d{4}\z/, label)
  end

  test "safe return param allows only internal relative paths" do
    controller = ApplicationController.new

    [
      [ "/dashboard", "/dashboard" ],
      [ "", nil ],
      [ "https://evil.example", nil ],
      [ "//evil.example", nil ]
    ].each do |value, expected|
      controller.singleton_class.define_method(:params) { ActionController::Parameters.new(return_to: value) }
      result = controller.send(:safe_return_to_param)
      expected.nil? ? assert_nil(result) : assert_equal(expected, result)
      controller.singleton_class.send(:remove_method, :params)
    end
  end

  test "app time zone uses env override and default" do
    controller = ApplicationController.new

    previous = ENV["APP_TIME_ZONE"]
    ENV["APP_TIME_ZONE"] = "Eastern Time (US & Canada)"
    assert_equal "Eastern Time (US & Canada)", controller.send(:app_time_zone_name)

    ENV.delete("APP_TIME_ZONE")
    assert_equal "Central Time (US & Canada)", controller.send(:app_time_zone_name)
  ensure
    ENV["APP_TIME_ZONE"] = previous if previous
    ENV.delete("APP_TIME_ZONE") unless previous
  end

  test "ferpa cache headers prevent browser storage" do
    controller = ApplicationController.new
    response = ActionDispatch::Response.new

    controller.singleton_class.define_method(:response) { response }
    controller.send(:set_ferpa_cache_headers)

    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.headers["Cache-Control"], "private"
    assert_equal "no-cache", response.headers["Pragma"]
    assert_equal "0", response.headers["Expires"]
  ensure
    controller.singleton_class.send(:remove_method, :response) if controller.singleton_class.method_defined?(:response)
  end

  test "ferpa sensitive parameters are filtered from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "uin" => "123456789",
      "student_email" => "student@example.edu",
      "answers" => { "1" => "private answer" },
      "raw_grade" => "98",
      "safe_filter" => "Spring 2026"
    )

    assert_equal "[FILTERED]", filtered["uin"]
    assert_equal "[FILTERED]", filtered["student_email"]
    assert_equal "[FILTERED]", filtered["answers"]
    assert_equal "[FILTERED]", filtered["raw_grade"]
    assert_equal "Spring 2026", filtered["safe_filter"]
  end

  test "impersonation helpers read session and memoize impersonator" do
    controller = ApplicationController.new
    session_hash = {
      impersonator_user_id: users(:admin).id,
      impersonation_kind: "advisor"
    }

    controller.singleton_class.define_method(:session) { session_hash }
    assert_equal true, controller.send(:impersonating?)
    assert_equal users(:admin), controller.send(:impersonator_user)
    assert_equal "advisor", controller.send(:impersonation_kind)

    session_hash.clear
    controller.remove_instance_variable(:@impersonator_user) if controller.instance_variable_defined?(:@impersonator_user)
    assert_equal false, controller.send(:impersonating?)
    assert_nil controller.send(:impersonator_user)
  ensure
    controller.singleton_class.send(:remove_method, :session) if controller.singleton_class.method_defined?(:session)
  end

  test "maintenance whitelist covers auth assets health and regular paths" do
    controller = ApplicationController.new

    controller.singleton_class.define_method(:maintenance_path) { "/maintenance" }
    [
      [ "/maintenance", true ],
      [ "/up", true ],
      [ "/sign_in", true ],
      [ "/sign_out", true ],
      [ "/users/auth/google_oauth2", true ],
      [ "/assets/application.css", true ],
      [ "/student/dashboard", false ]
    ].each do |path, expected|
      request = Struct.new(:path).new(path)
      controller.singleton_class.define_method(:request) { request }
      assert_equal expected, controller.send(:maintenance_mode_whitelisted_path?)
      controller.singleton_class.send(:remove_method, :request)
    end
  ensure
    controller.singleton_class.send(:remove_method, :maintenance_path) if controller.singleton_class.method_defined?(:maintenance_path)
  end

  test "record export audit skips anonymous users records metadata and swallows failures" do
    controller = ApplicationController.new
    request = Struct.new(:format, :fullpath).new(Struct.new(:symbol).new(:csv), "/reports.csv")
    params = ActionController::Parameters.new(
      controller: "reports",
      action: "index",
      format: "csv",
      track: "Residential",
      token: "signed-download-token",
      answers: { "1" => "private answer" }
    )

    controller.singleton_class.define_method(:current_user) { nil }
    assert_nil controller.send(:record_export_audit!, export_type: "report", description: "Exported report")
    controller.singleton_class.send(:remove_method, :current_user)

    admin_user = users(:admin)
    controller.singleton_class.define_method(:current_user) { admin_user }
    controller.singleton_class.define_method(:controller_name) { "reports" }
    controller.singleton_class.define_method(:action_name) { "index" }
    controller.singleton_class.define_method(:request) { request }
    controller.singleton_class.define_method(:params) { params }

    recorded = nil
    AdminActivityLog.stub(:record!, ->(**kwargs) { recorded = kwargs }) do
      controller.send(:record_export_audit!, export_type: "report", description: "Exported report", metadata: { extra: true })
    end
    assert_equal admin_user, recorded[:admin]
    assert_equal "student_data_export", recorded[:action]
    assert_equal true, recorded[:metadata][:extra]
    assert_equal "Residential", recorded[:metadata][:filters]["track"]
    assert_equal "[FILTERED]", recorded[:metadata][:filters]["token"]
    assert_equal "[FILTERED]", recorded[:metadata][:filters]["answers"]

    AdminActivityLog.stub(:record!, ->(*) { raise StandardError, "audit failed" }) do
      assert_nothing_raised do
        controller.send(:record_export_audit!, export_type: "report", description: "Exported report")
      end
    end
  ensure
    %i[current_user controller_name action_name request params].each do |method_name|
      controller.singleton_class.send(:remove_method, method_name) if controller.singleton_class.method_defined?(method_name)
    end
  end

  test "student profile completion gate skips whitelisted contexts" do
    controller = ApplicationController.new
    request = Struct.new(:path).new("/account")

    [
      [ "dashboards", "switch_role", "/anything" ],
      [ "accounts", "edit", "/account/edit" ],
      [ "sessions", "destroy", "/users/sign_out" ],
      [ "surveys", "show", "/switch_role" ]
    ].each do |controller_name, action_name, path|
      request.path = path
      controller.singleton_class.define_method(:controller_name) { controller_name }
      controller.singleton_class.define_method(:action_name) { action_name }
      controller.singleton_class.define_method(:request) { request }
      controller.singleton_class.define_method(:impersonating?) { false }
      assert_nil controller.send(:check_student_profile_complete)
      %i[controller_name action_name request impersonating?].each do |method_name|
        controller.singleton_class.send(:remove_method, method_name)
      end
    end
  end

  test "student profile completion gate redirects incomplete students outside test env" do
    controller = ApplicationController.new
    student_user = users(:student)
    student = students(:student)
    student.major = nil
    captured = nil

    controller.singleton_class.define_method(:controller_name) { "surveys" }
    controller.singleton_class.define_method(:action_name) { "show" }
    controller.singleton_class.define_method(:request) { Struct.new(:path).new("/surveys/1") }
    controller.singleton_class.define_method(:impersonating?) { false }
    controller.singleton_class.define_method(:user_signed_in?) { true }
    controller.singleton_class.define_method(:current_user) { student_user }
    controller.singleton_class.define_method(:current_student) { student }
    controller.singleton_class.define_method(:edit_account_path) { "/account/edit" }
    controller.singleton_class.define_method(:redirect_to) { |*args, **kwargs| captured = [ args, kwargs ]; true }

    Rails.stub(:env, ActiveSupport::StringInquirer.new("development")) do
      controller.send(:check_student_profile_complete)
    end

    assert_equal "/account/edit", captured.first.first
    assert_match "complete your profile", captured.second[:alert]
  ensure
    %i[controller_name action_name request impersonating? user_signed_in? current_user current_student edit_account_path redirect_to].each do |method_name|
      controller.singleton_class.send(:remove_method, method_name) if controller.singleton_class.method_defined?(method_name)
    end
  end

  test "student profile completion gate returns for signed out nonstudent nil and complete profiles" do
    controller = ApplicationController.new
    request = Struct.new(:path).new("/surveys/1")
    complete_student = students(:student)
    complete_student.update!(major: "Public Health", track: "Residential", program_year: 2026, uin: "123456789")
    base_methods = {
      controller_name: "surveys",
      action_name: "show",
      request: request,
      impersonating?: false
    }

    cases = [
      { user_signed_in?: false, current_user: nil, current_student: nil },
      { user_signed_in?: true, current_user: users(:advisor), current_student: nil },
      { user_signed_in?: true, current_user: users(:student), current_student: nil },
      { user_signed_in?: true, current_user: users(:student), current_student: complete_student }
    ]

    Rails.stub(:env, ActiveSupport::StringInquirer.new("development")) do
      cases.each do |case_methods|
        base_methods.merge(case_methods).each do |method_name, value|
          controller.singleton_class.define_method(method_name) { value }
        end

        assert_nil controller.send(:check_student_profile_complete)

        base_methods.merge(case_methods).each_key do |method_name|
          controller.singleton_class.send(:remove_method, method_name)
        end
      end
    end
  end

  test "maintenance redirect skips admin users and redirects regular users" do
    controller = ApplicationController.new
    request = Struct.new(:path).new("/surveys")
    captured = nil
    admin_user = users(:admin)
    student_user = users(:student)

    controller.singleton_class.define_method(:request) { request }
    controller.singleton_class.define_method(:maintenance_path) { "/maintenance" }
    controller.singleton_class.define_method(:redirect_to) { |path| captured = path; true }

    SiteSetting.stub(:maintenance_enabled?, true) do
      controller.singleton_class.define_method(:current_user) { admin_user }
      assert_nil controller.send(:redirect_for_maintenance_mode)
      controller.singleton_class.send(:remove_method, :current_user)

      controller.singleton_class.define_method(:current_user) { student_user }
      controller.send(:redirect_for_maintenance_mode)
      assert_equal "/maintenance", captured
    end
  ensure
    %i[request maintenance_path redirect_to current_user].each do |method_name|
      controller.singleton_class.send(:remove_method, method_name) if controller.singleton_class.method_defined?(method_name)
    end
  end

  test "read only impersonation guard allows safe and exit requests" do
    controller = ApplicationController.new
    request = Struct.new(:get_value, :head_value) do
      def get? = get_value
      def head? = head_value
    end

    [
      [ false, false, false, "surveys", "submit" ],
      [ true, true, false, "surveys", "submit" ],
      [ true, false, true, "surveys", "submit" ],
      [ true, false, false, "impersonations", "destroy" ],
      [ true, false, false, "advisor_impersonations", "destroy" ],
      [ true, false, false, "sessions", "destroy" ]
    ].each do |impersonating, get_value, head_value, controller_name, action_name|
      controller.singleton_class.define_method(:impersonating?) { impersonating }
      controller.singleton_class.define_method(:request) { request.new(get_value, head_value) }
      controller.singleton_class.define_method(:controller_name) { controller_name }
      controller.singleton_class.define_method(:action_name) { action_name }
      assert_nil controller.send(:enforce_read_only_when_impersonating)
      %i[impersonating? request controller_name action_name].each do |method_name|
        controller.singleton_class.send(:remove_method, method_name)
      end
    end
  end

  test "read only impersonation guard redirects by impersonated role" do
    controller = ApplicationController.new
    request = Struct.new(:get?, :head?).new(false, false)

    [
      [ "advisor", "/advisor_dashboard" ],
      [ "admin", "/admin_dashboard" ],
      [ "student", "/student_dashboard" ],
      [ nil, "/student_dashboard" ]
    ].each do |role, expected_path|
      captured = nil
      user = OpenStruct.new(role: role)
      controller.singleton_class.define_method(:impersonating?) { true }
      controller.singleton_class.define_method(:request) { request }
      controller.singleton_class.define_method(:controller_name) { "surveys" }
      controller.singleton_class.define_method(:action_name) { "submit" }
      controller.singleton_class.define_method(:current_user) { user }
      controller.singleton_class.define_method(:advisor_dashboard_path) { "/advisor_dashboard" }
      controller.singleton_class.define_method(:admin_dashboard_path) { "/admin_dashboard" }
      controller.singleton_class.define_method(:student_dashboard_path) { "/student_dashboard" }
      controller.singleton_class.define_method(:redirect_back) { |fallback_location:, alert:| captured = [ fallback_location, alert ]; true }

      controller.send(:enforce_read_only_when_impersonating)

      assert_equal expected_path, captured.first
      assert_equal "Read-only while impersonating.", captured.second
      %i[impersonating? request controller_name action_name current_user advisor_dashboard_path admin_dashboard_path student_dashboard_path redirect_back].each do |method_name|
        controller.singleton_class.send(:remove_method, method_name)
      end
    end
  end
end
