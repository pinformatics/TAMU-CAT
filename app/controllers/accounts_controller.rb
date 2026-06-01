class AccountsController < ApplicationController
  before_action :authenticate_user!
  before_action :load_account_context, only: %i[show edit update]

  # Shows the current user's account info
  def show
  end

  def edit
    return if student_account?

    redirect_to account_path, alert: "Account identity details are managed by your sign-in account and cannot be edited here."
  end

  # Identity information is read-only. Student program profile details can be
  # updated here so Account is the single profile entry point for students.
  def update
    unless student_account? && params[:student].present?
      redirect_to account_path, alert: "Account identity details are managed by your sign-in account and cannot be edited here."
      return
    end

    @student.assign_attributes(student_params)
    had_assignments = @student.survey_assignments.exists?

    if @student.valid?(:profile_completion)
      track_will_change = @student.will_save_change_to_track?
      program_year_will_change = @student.will_save_change_to_program_year?
      @student.save!(context: :profile_completion)

      if track_will_change || program_year_will_change || !had_assignments
        begin
          SurveyAssignments::AutoAssigner.call(student: @student)
        rescue StandardError => e
          Rails.logger.error("Account profile auto-assign failed for student #{@student.student_id}: #{e.class}: #{e.message}")
        end
      end

      redirect_to account_path, notice: "Student profile updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def load_account_context
    @user = current_user
    @student = current_student if student_account?

    return unless @student

    @advisors = Advisor.joins(:user).order("users.name ASC")
    @majors = Major.order(:name)
  end

  def student_account?
    current_user&.role_student? && current_student.present?
  end

  def student_params
    params.require(:student).permit(:uin, :major, :track, :program_year, :advisor_id)
  end
end
