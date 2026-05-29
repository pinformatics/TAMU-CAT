# Admin-only feature allowing an admin to temporarily sign in as a student.
#
# While impersonating, the app is enforced read-only and provides an exit
# endpoint that restores the original admin session.
class ImpersonationsController < ApplicationController
  before_action :require_admin!, only: %i[new create]
  before_action :require_impersonating!, only: %i[destroy]

  helper_method :impersonating?, :impersonator_user

  def new
    @students = User.students.order(:name, :email)
    @advisors = User.advisors.order(:name, :email)
  end

  def create
    raw_identifier = impersonation_params[:user_id].to_s.strip

    student_user = if raw_identifier.match?(/\A\d+\z/)
      User.students.find_by(id: raw_identifier)
    else
      # Combobox submits email values.
      email = raw_identifier[/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i]
      email.present? ? User.students.find_by(email: email) : User.students.find_by(name: raw_identifier)
    end

    unless student_user
      redirect_to new_impersonation_path, alert: "Student not found."
      return
    end

    impersonator_id = current_user.id

    sign_in(student_user, event: :authentication)
    session[:impersonator_user_id] = impersonator_id
    session[:impersonation_kind] = "student"

    redirect_to student_dashboard_path, notice: "Now viewing as #{student_user.display_name}."
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
    redirect_to admin_dashboard_path, notice: "Exited student view."
  end

  private

  def impersonation_params
    params.require(:impersonation).permit(:user_id)
  end

  def require_admin!
    return if current_user&.role_admin?

    redirect_to dashboard_path, alert: "Admin access is required to open this page."
  end

  def require_impersonating!
    return if impersonating?

    redirect_to dashboard_path, alert: "Not currently viewing as a student."
  end

  def impersonating?
    session[:impersonator_user_id].present?
  end

  def impersonator_user
    return nil unless impersonating?

    @impersonator_user ||= User.find_by(id: session[:impersonator_user_id])
  end
end
