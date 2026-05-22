# frozen_string_literal: true

class Admin::CourseGradeReleaseDatesController < Admin::BaseController
  def index
    @semesters = ProgramSemester.ordered
    @release_dates = CourseGradeReleaseDate.all.index_by(&:program_semester_id)
    @release_date_activity = AdminActivityLog
      .where(action: "course_release_date_update")
      .recent
      .limit(15)

    # Count surveys per semester
    @survey_counts = Survey.joins(:program_semester)
                           .group(:program_semester_id)
                           .count
  end

  def edit
    @release_date = CourseGradeReleaseDate.find(params[:id])
    @semester = @release_date.program_semester
  end

  def update
    @release_date = CourseGradeReleaseDate.find(params[:id])
    previous_release_date = @release_date.release_date
    if @release_date.update(release_date_params)
      record_release_date_audit!(
        semester: @release_date.program_semester,
        release_date: @release_date,
        previous_release_date: previous_release_date,
        new_release_date: @release_date.release_date,
        source: "single"
      )
      enqueue_course_release_notifications_if_released!(
        semester: @release_date.program_semester,
        previous_release_date: previous_release_date,
        new_release_date: @release_date.release_date
      )
      redirect_to admin_course_grade_release_dates_path, notice: "Course grade release date updated."
    else
      render :edit
    end
  end

  def new
    @semester = ProgramSemester.find(params[:semester_id])
    @release_date = CourseGradeReleaseDate.new(program_semester: @semester)
  end

  def create
    @semester = ProgramSemester.find(release_date_params[:program_semester_id])
    @release_date = CourseGradeReleaseDate.new(release_date_params)

    if @release_date.save
      record_release_date_audit!(
        semester: @release_date.program_semester,
        release_date: @release_date,
        previous_release_date: nil,
        new_release_date: @release_date.release_date,
        source: "single"
      )
      enqueue_course_release_notifications_if_released!(
        semester: @release_date.program_semester,
        previous_release_date: nil,
        new_release_date: @release_date.release_date
      )
      redirect_to admin_course_grade_release_dates_path, notice: "Course grade release date created."
    else
      render :new
    end
  end

  def bulk_update
    updates = bulk_release_date_params
    changed_count = 0

    ProgramSemester.where(id: updates.keys).find_each do |semester|
      previous = semester.course_grade_release_date&.release_date
      new_value = parse_release_date(updates[semester.id.to_s])
      next if release_dates_equal?(previous, new_value)

      release_date = semester.course_grade_release_date

      if new_value.present?
        release_date ||= semester.build_course_grade_release_date
        release_date.release_date = new_value
        release_date.save!
      else
        release_date&.destroy!
      end

      changed_count += 1
      record_release_date_audit!(
        semester: semester,
        release_date: release_date,
        previous_release_date: previous,
        new_release_date: new_value,
        source: "bulk"
      )
      enqueue_course_release_notifications_if_released!(
        semester: semester,
        previous_release_date: previous,
        new_release_date: new_value
      )
    end

    message = changed_count.positive? ? "Updated #{changed_count} release date#{'s' if changed_count != 1}." : "No release date changes were submitted."
    redirect_to admin_course_grade_release_dates_path, notice: message
  end

  def destroy
    @release_date = CourseGradeReleaseDate.find(params[:id])
    semester = @release_date.program_semester
    previous_release_date = @release_date.release_date
    @release_date.destroy
    record_release_date_audit!(
      semester: semester,
      release_date: nil,
      previous_release_date: previous_release_date,
      new_release_date: nil,
      source: "single"
    )
    enqueue_course_release_notifications_if_released!(
      semester: semester,
      previous_release_date: previous_release_date,
      new_release_date: nil
    )
    redirect_to admin_course_grade_release_dates_path, notice: "Course grade release date cleared."
  end

  private

  def release_date_params
    params.require(:course_grade_release_date).permit(:program_semester_id, :release_date)
  end

  def bulk_release_date_params
    raw = params[:release_dates]
    return {} unless raw.respond_to?(:permit)

    permitted_semester_ids = ProgramSemester.pluck(:id).map(&:to_s)
    raw.permit(*permitted_semester_ids).to_h
  end

  def parse_release_date(value)
    value = value.to_s.strip
    return nil if value.blank?

    Time.zone.parse(value)
  end

  def release_dates_equal?(left, right)
    return true if left.blank? && right.blank?
    return false if left.blank? || right.blank?

    left.to_i == right.to_i
  end

  def record_release_date_audit!(semester:, release_date:, previous_release_date:, new_release_date:, source:)
    return if release_dates_equal?(previous_release_date, new_release_date)

    AdminActivityLog.record!(
      admin: current_user,
      action: "course_release_date_update",
      subject: release_date || semester,
      description: "Updated course result release date for #{semester.name}: #{release_date_label(previous_release_date)} to #{release_date_label(new_release_date)}.",
      metadata: {
        semester_id: semester.id,
        semester_name: semester.name,
        previous_release_date: previous_release_date&.iso8601,
        new_release_date: new_release_date&.iso8601,
        source: source
      }
    )
  end

  def enqueue_course_release_notifications_if_released!(semester:, previous_release_date:, new_release_date:)
    return unless transitioned_to_released?(previous_release_date, new_release_date)

    CourseCompetencyReleaseNotificationJob.perform_later(program_semester_id: semester.id, triggered_by_id: current_user.id)
  end

  def transitioned_to_released?(previous_release_date, new_release_date)
    previously_embargoed = previous_release_date.present? && previous_release_date > Time.current
    now_released = new_release_date.blank? || new_release_date <= Time.current

    previously_embargoed && now_released
  end

  def release_date_label(value)
    value.present? ? I18n.l(value, format: :long) : "visible immediately"
  end
end
