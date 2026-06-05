class Admin::CourseCompetencyTargetsController < Admin::BaseController
  before_action :set_course_competency_target, only: %i[update destroy]

  def create
    target = CourseCompetencyTarget.new(course_competency_target_record_attributes)
    target.save!

    redirect_to course_targets_tab_path(target.course_offering.program_semester_id),
                notice: "Course target saved."
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    redirect_to course_targets_tab_path(selected_semester_id),
                alert: e.message
  end

  def update
    @course_competency_target.update!(course_competency_target_record_attributes)

    redirect_to course_targets_tab_path(@course_competency_target.course_offering.program_semester_id),
                notice: "Course target updated."
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    redirect_to course_targets_tab_path(selected_semester_id || @course_competency_target&.course_offering&.program_semester_id),
                alert: e.message
  end

  def destroy
    semester_id = @course_competency_target.course_offering.program_semester_id
    @course_competency_target.destroy!

    redirect_to course_targets_tab_path(semester_id), notice: "Course target removed."
  end

  private

  def set_course_competency_target
    @course_competency_target = CourseCompetencyTarget.find(params[:id])
  end

  def course_competency_target_record_attributes
    {
      course_offering: resolved_course_offering,
      competency_id: target_params.fetch(:competency_id),
      target_level: target_params.fetch(:target_level)
    }
  end

  def resolved_course_offering
    semester = ProgramSemester.find(selected_semester_id)
    course_code = target_params[:course_code].to_s.strip
    course_title = target_params[:course_title].to_s.strip

    raise ArgumentError, "Course code is required." if course_code.blank?

    offering = CourseOffering.find_or_create_from_code!(
      course_code,
      program_semester: semester,
      source_name: course_title.presence
    )
    raise ArgumentError, "Course code must look like PHPM-633 or PHPM-633-700." if offering.blank?

    if course_title.present? && offering.course.title != course_title
      offering.course.update!(title: course_title)
    end

    offering
  end

  def target_params
    @target_params ||= params
      .require(:course_competency_target)
      .permit(:program_semester_id, :course_code, :course_title, :competency_id, :target_level)
  end

  def selected_semester_id
    target_params[:program_semester_id].presence
  end

  def course_targets_tab_path(semester_id)
    admin_program_setup_path(
      tab: "course_targets",
      course_target_program_semester_id: semester_id
    )
  end
end
