# Handles student profile setup and account information display
class StudentProfilesController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_student_role
  skip_before_action :check_student_profile_complete, only: [ :edit, :update ]

  # Show account information
  def show
    @student = current_student
  end

  # First-time profile setup form
  def edit
    @student = current_student
    @advisors = Advisor.joins(:user).order("users.name ASC")
    @majors = Major.order(:name)
  end

  # Update profile information
  def update
    @student = current_student
    @advisors = Advisor.joins(:user).order("users.name ASC")
    @majors = Major.order(:name)

    # Update student attributes
    @student.assign_attributes(student_params)
    had_assignments = @student.survey_assignments.exists?

    if @student.valid?(:profile_completion)
      track_will_change = @student.will_save_change_to_track?
      program_year_will_change = @student.will_save_change_to_program_year?
      @student.save!(context: :profile_completion) # This will also save the user and student changes

      if track_will_change || program_year_will_change || !had_assignments
        begin
          SurveyAssignments::AutoAssigner.call(student: @student)
        rescue StandardError => e
          Rails.logger.error("Profile auto-assign failed for student #{@student.student_id}: #{e.class}: #{e.message}")
        end
      end

      redirect_to student_dashboard_path, notice: "Profile completed successfully!"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def ensure_student_role
    unless current_user&.role_student?
      redirect_to root_path, alert: "You do not have permission to view that profile."
    end
  end

  def student_params
    params.require(:student).permit(:uin, :major, :track, :program_year, :advisor_id)
  end
end
