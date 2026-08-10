class Admin::CourseCompetencyTargetsController < Admin::BaseController
  before_action :ensure_course_targets_ready
  before_action :set_course_competency_target, only: %i[update destroy]

  def create
    target = CourseCompetencyTarget.new(course_competency_target_record_attributes)
    target.save!

    redirect_to course_targets_tab_path(target.course_offering.program_semester_id),
                notice: "Course target saved."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError => e
    redirect_to course_targets_tab_path(selected_semester_id),
                alert: e.message
  end

  def update
    @course_competency_target.update!(course_competency_target_record_attributes)

    redirect_to course_targets_tab_path(@course_competency_target.course_offering.program_semester_id),
                notice: "Course target updated."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError => e
    redirect_to course_targets_tab_path(selected_semester_id || @course_competency_target&.course_offering&.program_semester_id),
                alert: e.message
  end

  def destroy
    semester_id = @course_competency_target.course_offering.program_semester_id
    @course_competency_target.destroy!

    redirect_to course_targets_tab_path(semester_id), notice: "Course target removed."
  end

  def import_matrix
    semester_id = matrix_import_params[:program_semester_id].presence
    file = matrix_import_params[:file]

    if semester_id.blank? || file.blank?
      redirect_to course_targets_tab_path(semester_id), alert: "Choose a semester and a workbook to import."
      return
    end

    semester = ProgramSemester.find(semester_id)
    result = Admin::CourseCompetencyMatrixImporter.call(file: file, program_semester: semester)

    flash[:notice] = import_matrix_summary(result)
    flash[:course_target_import_errors] = result.errors.first(20) if result.errors.present?

    redirect_to course_targets_tab_path(semester_id)
  rescue StandardError => e
    redirect_to course_targets_tab_path(semester_id), alert: "Could not read that workbook: #{e.message}"
  end

  private

  def import_matrix_summary(result)
    "Imported #{result.sheets_processed} sheet(s): #{result.created} created, " \
      "#{result.updated} updated, #{result.unchanged} unchanged" \
      "#{result.errors.present? ? ", #{result.errors.size} row(s) need attention" : ""}."
  end

  def matrix_import_params
    params.permit(:program_semester_id, :file)
  end

  def ensure_course_targets_ready
    return if CourseCompetencyTarget.data_source_ready?

    redirect_to course_targets_tab_path(params.dig(:course_competency_target, :program_semester_id).presence),
                alert: "Course target setup is waiting on the V6 database migration. Run the latest migrations, then try again."
  end

  def set_course_competency_target
    @course_competency_target = CourseCompetencyTarget.find(params[:id])
  end

  def course_competency_target_record_attributes
    {
      course_offering: resolved_course_offering,
      competency_id: target_params.fetch(:competency_id),
      target_level: target_params.fetch(:target_level),
      track: target_params[:track].presence
    }
  end

  def resolved_course_offering
    semester = ProgramSemester.find(selected_semester_id)
    offering_id = target_params[:course_offering_id].presence

    return existing_offering_for(offering_id, semester) if offering_id.present?

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

  def existing_offering_for(offering_id, semester)
    offering = CourseOffering.find(offering_id)
    raise ArgumentError, "Selected course does not belong to the chosen semester." unless offering.program_semester_id == semester.id

    offering
  end

  def target_params
    @target_params ||= params
      .require(:course_competency_target)
      .permit(:program_semester_id, :course_offering_id, :course_code, :course_title, :competency_id, :target_level, :track)
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
