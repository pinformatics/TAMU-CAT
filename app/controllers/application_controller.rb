# Base controller providing authentication and shared helpers for downstream
# controllers. Ensures users are signed in and exposes current profile
# accessors for views.
class ApplicationController < ActionController::Base
  NAV_NOTIFICATION_LIMIT = 5
  ADMIN_ONLY_MESSAGE = "This page is available only to administrators."
  STAFF_ONLY_MESSAGE = "This page is available only to administrators and advisors."
  ADVISOR_ONLY_MESSAGE = "This page is available only to advisors."
  STUDENT_ONLY_MESSAGE = "This page is available only to students."

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  around_action :use_app_time_zone
  before_action :set_ferpa_cache_headers
  before_action :redirect_for_maintenance_mode
  before_action :authenticate_user!
  before_action :enforce_read_only_when_impersonating
  before_action :check_student_profile_complete
  before_action :load_notification_state, if: :user_signed_in?
  rescue_from ActionController::InvalidAuthenticityToken, with: :handle_invalid_authenticity_token
  allow_browser versions: :modern

  helper_method :current_student, :current_advisor_profile, :impersonating?, :impersonator_user, :impersonation_kind, :safe_return_to_param

  # @return [Student, nil] the authenticated user's student profile, if present
  def current_student
    return @current_student if defined?(@current_student)
    @current_student = current_user&.student_profile
  end

  # @return [Advisor, nil] the authenticated user's advisor profile, if present
  def current_advisor_profile
    return @current_advisor if defined?(@current_advisor)
    @current_advisor = current_user&.advisor_profile
  end

  private

  # Ensures request-time parsing/rendering/comparisons use the same timezone
  # as admin-entered availability timestamps.
  def use_app_time_zone(&block)
    Time.use_zone(app_time_zone_name, &block)
  end

  def app_time_zone_name
    ENV.fetch("APP_TIME_ZONE", "Central Time (US & Canada)")
  end

  def set_ferpa_cache_headers
    response.headers["Cache-Control"] = "no-store, private, max-age=0, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
  end

  # Safely extracts a return_to path for back/cancel links.
  #
  # Only allows internal relative paths (e.g. "/student/dashboard").
  # Prevents protocol-relative URLs like "//evil.com".
  #
  # @return [String, nil]
  def safe_return_to_param
    value = params[:return_to].to_s
    return nil if value.blank?
    return nil unless value.start_with?("/") && !value.start_with?("//")

    value
  end

  # Redirects students to profile setup if their profile is incomplete
  def check_student_profile_complete
    # Never block the role switching endpoint
    if controller_name == "dashboards" && action_name == "switch_role"
      return
    end
    if request&.path == "/switch_role"
      return
    end

    # When an admin is viewing as a student, keep the experience read-only and
    # avoid forcing profile completion redirects.
    return if impersonating?

    # Allow dashboard root redirect to proceed; gating happens on specific dashboards
    if controller_name == "dashboards" && action_name == "show"
      return
    end
    return if Rails.env.test?
    return unless user_signed_in?
    return unless current_user.role_student?
    return if current_student.nil?
    return if current_student.profile_complete?
    return if controller_name == "accounts" # Account includes student profile fields
    return if controller_name == "sessions" # Allow logout

    redirect_to edit_account_path, alert: "Please complete your profile to continue."
  end

  # Preloads the notification count and recent records for the header dropdown.
  #
  # @return [void]
  def load_notification_state
    @notification_menu_limit = NAV_NOTIFICATION_LIMIT
    unless in_app_notifications_enabled_for?(current_user)
      @unread_notification_count = 0
      @recent_notifications = Notification.none
      return
    end

    notifications_scope = current_user.notifications
    @unread_notification_count = notifications_scope.unread.count
    @recent_notifications = notifications_scope.unread.recent.limit(NAV_NOTIFICATION_LIMIT)
  end

  def in_app_notifications_enabled_for?(user)
    return true unless user
    return true unless user.respond_to?(:in_app_notifications_enabled?)

    user.in_app_notifications_enabled?
  end

  # When enabled, redirects non-admin users to the maintenance page.
  # Admins can still sign in and access admin tools to disable maintenance.
  def redirect_for_maintenance_mode
    return unless SiteSetting.maintenance_enabled?
    return if maintenance_mode_whitelisted_path?

    if current_user&.role_admin?
      return
    end

    redirect_to maintenance_path
  end

  def maintenance_mode_whitelisted_path?
    path = request.path.to_s

    return true if path == maintenance_path
    return true if path == "/up"

    # Allow authentication flow even while maintenance is enabled.
    return true if path.start_with?("/sign_in")
    return true if path.start_with?("/sign_out")
    return true if path.start_with?("/users/auth")

    # Allow assets to load on the maintenance page.
    return true if path.start_with?("/assets/")

    false
  end

  # Fallback semester label used when there is no ProgramSemester configured yet.
  #
  # @return [String]
  def fallback_semester_label
    Time.zone.now.strftime("%B %Y")
  end

  def impersonating?
    session[:impersonator_user_id].present?
  end

  def impersonator_user
    return nil unless impersonating?

    @impersonator_user ||= User.find_by(id: session[:impersonator_user_id])
  end

  def impersonation_kind
    session[:impersonation_kind].to_s
  end

  def enforce_read_only_when_impersonating
    return unless impersonating?
    return if request.get? || request.head?

    # Allow exiting impersonation (and signing out) even while in read-only mode.
    return if controller_name == "impersonations" && action_name == "destroy"
    return if controller_name == "advisor_impersonations" && action_name == "destroy"
    return if controller_name == "sessions" && action_name == "destroy"

    fallback_location = case current_user&.role.to_s
    when "advisor"
      advisor_dashboard_path
    when "admin"
      admin_dashboard_path
    else
      student_dashboard_path
    end

    redirect_back fallback_location:, alert: "Read-only while impersonating."
  end

  def handle_invalid_authenticity_token(exception)
    payload = {
      request_id: request.request_id,
      method: request.request_method,
      path: request.fullpath,
      user_id: current_user&.id,
      user_email: current_user&.email,
      student_id: current_student&.student_id,
      referer: request.referer,
      origin: request.headers["Origin"],
      user_agent: request.user_agent,
      remote_ip: request.remote_ip
    }

    Rails.logger.warn("[CSRF] Invalid authenticity token: #{payload.to_json}")
    Rails.logger.warn("[CSRF] Exception: #{exception.class}: #{exception.message}")

    reset_session

    respond_to do |format|
      format.html do
        redirect_to new_user_session_path, alert: "Your session expired or became invalid. Please sign in again and resubmit your survey."
      end
      format.json { render json: { error: "Invalid authenticity token" }, status: :unprocessable_entity }
      format.any { head :unprocessable_entity }
    end
  end

  def record_export_audit!(export_type:, description:, subject: nil, metadata: {})
    return unless current_user

    AdminActivityLog.record!(
      admin: current_user,
      action: "student_data_export",
      description: description,
      subject: subject,
      metadata: {
        export_type: export_type,
        controller: controller_name,
        action: action_name,
        format: request.format.symbol,
        path: request.fullpath,
        filters: export_audit_filters
      }.merge(metadata || {})
    )
  rescue StandardError => e
    Rails.logger.warn("[ExportAudit] Failed to record export audit: #{e.class}: #{e.message}")
  end

  def export_audit_filters
    raw_filters = params.to_unsafe_h.except(
      "controller",
      "action",
      "format",
      "authenticity_token",
      "commit",
      "utf8"
    )

    ActiveSupport::ParameterFilter
      .new(Rails.application.config.filter_parameters)
      .filter(raw_filters)
  end
end
