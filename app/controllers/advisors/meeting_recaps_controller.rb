module Advisors
  # Lets the assigned advisor (or an admin) record a fixed-format recap of an
  # advising meeting (initial/midpoint/final) for a student in a given
  # program semester. Never exposed to students.
  class MeetingRecapsController < BaseController
    before_action :set_student, except: :index
    before_action :ensure_student_access!, except: :index
    before_action :set_recap, only: %i[edit update]

    def index
      @students = accessible_students
    end

    def new
      @program_semester = ProgramSemester.find_by(id: params[:program_semester_id])
      @meeting_type = params[:meeting_type].to_s

      unless @program_semester && AdvisorMeetingRecap::MEETING_TYPES.include?(@meeting_type)
        redirect_to advisors_student_path(@student), alert: "Choose a semester and meeting type to add a recap."
        return
      end

      @recap = @student.advisor_meeting_recaps.new(program_semester: @program_semester, meeting_type: @meeting_type)
    end

    def create
      @recap = @student.advisor_meeting_recaps.new(recap_create_params)
      @recap.advisor_id = resolved_advisor_id

      if @recap.advisor_id.blank?
        redirect_to advisors_student_path(@student), alert: "This student has no assigned advisor to save a recap for."
        return
      end

      if @recap.save
        redirect_to advisors_student_path(@student), notice: "Meeting recap saved."
      else
        @program_semester = @recap.program_semester
        @meeting_type = @recap.meeting_type
        render :new, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotUnique
      redirect_to advisors_student_path(@student), alert: "A recap for that semester and meeting type already exists."
    end

    def edit; end

    def update
      if @recap.update(recap_update_params)
        redirect_to advisors_student_path(@student), notice: "Meeting recap saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def accessible_students
      scope = if current_user&.role_admin?
        Student.all
      elsif current_user&.role_advisor?
        current_advisor_profile&.advisees || Student.none
      else
        Student.none
      end

      scope.current_records.includes(:user).left_outer_joins(:user).order(Arel.sql("LOWER(COALESCE(users.name, users.email, '')) ASC"))
    end

    def set_student
      @student = Student.find(params[:student_id])
    end

    def set_recap
      @recap = @student.advisor_meeting_recaps.find(params[:id])
    end

    def ensure_student_access!
      return if current_user&.role_admin?

      advisor_id = current_advisor_profile&.advisor_id
      return if advisor_id.present? && @student&.advisor_id == advisor_id

      redirect_to advisors_student_path(@student), alert: "This student is not assigned to you."
    end

    def resolved_advisor_id
      return current_advisor_profile&.advisor_id if current_user.role_advisor?

      @student.advisor_id.presence || Advisor.find_or_create_by!(advisor_id: current_user.id).advisor_id if current_user.role_admin?
    end

    def recap_create_params
      params.require(:advisor_meeting_recap).permit(
        :program_semester_id, :meeting_type,
        :academic_advising_notes, :career_advising_notes, :general_notes
      )
    end

    def recap_update_params
      params.require(:advisor_meeting_recap).permit(
        :academic_advising_notes, :career_advising_notes, :general_notes
      )
    end
  end
end
