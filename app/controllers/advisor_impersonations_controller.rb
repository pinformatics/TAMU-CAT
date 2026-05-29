# Admin-only feature allowing an admin to temporarily sign in as an advisor.
#
# While impersonating, the app is enforced read-only and provides an exit
# endpoint that restores the original admin session.
class AdvisorImpersonationsController < ApplicationController
  before_action :require_admin!, only: %i[new create]
  before_action :require_impersonating!, only: %i[destroy]

  def new
    @advisors = User.advisors.order(:name, :email)
  end

  def create
    advisor_user = User.advisors.find_by(id: advisor_impersonation_params[:user_id])

    unless advisor_user
      redirect_to new_advisor_impersonation_path, alert: "Advisor not found."
      return
    end

    impersonator_id = current_user.id

    sign_in(advisor_user, event: :authentication)
    session[:impersonator_user_id] = impersonator_id
    session[:impersonation_kind] = "advisor"

    redirect_to advisor_dashboard_path, notice: "Now viewing as #{advisor_user.display_name}."
  end

  def destroy
    impersonator_id = session.delete(:impersonator_user_id)
    session.delete(:impersonation_kind)
    impersonator = User.find_by(id: impersonator_id)

    unless impersonator
      sign_out(current_user)
      redirect_to new_user_session_path, alert: "Impersonation session expired. Please sign in again."
      return
    end

    sign_in(impersonator, event: :authentication)
    redirect_to admin_dashboard_path, notice: "Exited advisor view."
  end

  private

  def advisor_impersonation_params
    params.require(:advisor_impersonation).permit(:user_id)
  end

  def require_admin!
    return if current_user&.role_admin?

    redirect_to dashboard_path, alert: "Admin access is required to open this page."
  end

  def require_impersonating!
    return if impersonating?

    redirect_to dashboard_path, alert: "Not currently emulating an advisor."
  end
end
