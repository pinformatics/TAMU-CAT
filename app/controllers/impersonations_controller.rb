# Admin-only feature allowing an admin to temporarily sign in as a student.
#
# While impersonating, the app is enforced read-only and provides an exit
# endpoint that restores the original admin session.
class ImpersonationsController < ApplicationController
  before_action :require_admin!, only: %i[new create]
  before_action :require_impersonating!, only: %i[destroy]

  helper_method :impersonating?, :impersonator_user

  def new
    @students = User.students.includes(:student_profile).order(:name, :email)
    @advisors = User.advisors.order(:name, :email)
    @student_impersonation_options = @students.map { |user| student_impersonation_option(user) }
    @advisor_impersonation_options = @advisors.map { |user| user_impersonation_option(user) }
  end

  def create
    raw_identifier = impersonation_params[:user_id].to_s.strip
    student_user = find_student_user(raw_identifier)

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

  def user_impersonation_option(user)
    {
      value: user.id,
      label: user.full_name,
      description: user.email
    }
  end

  def student_impersonation_option(user)
    student = user.student_profile
    meta = [
      user.email,
      student&.uin.present? ? "UIN #{student.uin}" : nil
    ].compact_blank.join(" · ")

    {
      value: user.id,
      label: user.full_name,
      description: meta.presence || user.email
    }
  end

  def find_student_user(raw_identifier)
    return nil if raw_identifier.blank?

    if raw_identifier.match?(/\A\d+\z/)
      User.students.find_by(id: raw_identifier) ||
        User.students.joins(:student_profile).find_by(students: { uin: raw_identifier })
    else
      email = raw_identifier[/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i]
      return User.students.find_by(email: email) if email.present?

      uin = raw_identifier[/\b\d{9}\b/]
      return User.students.joins(:student_profile).find_by(students: { uin: uin }) if uin.present?

      User.students.find_by(name: raw_identifier)
    end
  end

  def require_admin!
    return if current_user&.role_admin?

    redirect_to dashboard_path, alert: ADMIN_ONLY_MESSAGE
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
