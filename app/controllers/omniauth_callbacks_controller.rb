# Handles authentication callbacks from external identity providers (Google)
# and enforces TAMU email restrictions while wiring users into Devise.
class OmniauthCallbacksController < Devise::OmniauthCallbacksController
  # Skip CSRF verification for OAuth callbacks since they come from external sources
  skip_before_action :verify_authenticity_token, only: [ :google_oauth2, :failure ]

  # Processes the Google OAuth callback, provisioning users as needed and
  # routing them to an appropriate dashboard based on role.
  #
  # @return [void]
  def google_oauth2
    # Get role from the request params stored when the user clicked login.
    role = request.env.fetch("omniauth.params", {})["role"]

    email = auth.info.email.to_s.downcase

    unless tamu_email?(email)
      Rails.logger.warn "Blocked OAuth login for non-TAMU email: #{email}"
      flash[:alert] = "Please sign in with your TAMU email (@tamu.edu)."
      redirect_to after_omniauth_failure_path_for(:user) and return
    end

    user = User.from_google(**from_google_params.merge(email:, role: role))

    if user.present?
      sign_out_all_scopes
      flash[:success] = t "devise.omniauth_callbacks.success", kind: "Google"
      sign_in(user, event: :authentication)
      ensure_track_survey_assignment_for(user)

      # Redirect based on role with fallback
      redirect_path = case user.role
      when "admin"
                       admin_dashboard_path
      when "advisor"
                       advisor_dashboard_path
      when "student"
                       student_dashboard_path
      else
                       case role
                       when "student"
                         student_dashboard_path
                       when "advisor"
                         advisor_dashboard_path
                       else
                         dashboard_path
                       end
      end

      redirect_to redirect_path
    else
      flash[:alert] = t "devise.omniauth_callbacks.failure", kind: "Google", reason: "#{auth.info.email} is not authorized."
      redirect_to after_omniauth_failure_path_for(:user)
    end
  end

  protected

  # Location to send a user after an OmniAuth failure.
  #
  # @return [String]
  def after_omniauth_failure_path_for(_scope)
    new_user_session_path
  end

  # Determines the path after a successful sign in, defaulting to the
  # dashboard if no stored location exists.
  #
  # @param resource_or_scope [Object]
  # @return [String]
  def after_sign_in_path_for(resource_or_scope)
    # This method is overridden by our custom logic above
    stored_location_for(resource_or_scope) || dashboard_path
  end

  private

  # Normalized attributes extracted from the omniauth payload.
  #
  # @return [Hash]
  def from_google_params
    @from_google_params ||= {
      uid: auth.uid,
      email: auth.info.email.to_s.downcase,
      name: auth.info.name,
      avatar_url: auth.info.image
    }
  end

  # Memoized OmniAuth payload for the current request.
  #
  # @return [OmniAuth::AuthHash]
  def auth
    @auth ||= request.env["omniauth.auth"]
  end

  def ensure_track_survey_assignment_for(user)
    return unless user&.role_student?

    student = user.student_profile
    return unless student

    SurveyAssignments::AutoAssigner.call(student: student)
  rescue StandardError => e
    Rails.logger.error(
      "OAuth auto-assign failed for user #{user&.id}: #{e.class}: #{e.message}"
    )
  end

  # Validates that an email address belongs to a TAMU domain.
  #
  # @param email [String]
  # @return [Boolean]
  def tamu_email?(email)
    return false if email.blank?

    normalized_email = email.downcase
    normalized_email.ends_with?("@tamu.edu") || normalized_email.ends_with?("@email.tamu.edu")
  end
end
