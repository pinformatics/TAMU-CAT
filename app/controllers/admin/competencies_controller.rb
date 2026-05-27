# frozen_string_literal: true

require "csv"

class Admin::CompetenciesController < ApplicationController
  before_action :require_competency_access!
  before_action :require_admin_for_course_rule!, only: :course_rule

  def index
    payload = competency_payload
    @filters = payload[:filters]
    @filter_options = payload[:filter_options]
    @domains = payload[:domains]
    @students = payload[:students]
    @visible_competency_count = payload[:visible_competency_count]
    @active_course_competency_rule = payload[:course_competency_rule]
    @active_course_competency_rule_label = payload[:course_competency_rule_label]
    @course_competency_rule_options = payload[:course_competency_rule_options]
  end

  def show
    @student = accessible_student_scope.includes(:user, advisor: :user).find(params[:id])
    @payload = StudentCompetencyDashboard.new(student: @student, params: student_competency_params).call
    @competency_page_title = "#{@student.user&.display_name || @student.full_name} Competencies"
    @competency_page_subtitle = "Student-facing competency modules for advising review: source guide, changes, summary, graphs, and target comparison."
    @competency_back_path = admin_competencies_path
    @competency_form_path = admin_competency_path(@student)
    @competency_export_path = admin_competency_path(@student, format: :csv, semester: export_semester_param, sources: @payload.dig(:filters, :sources))
    @competency_pdf_path = admin_competency_path(@student, format: :pdf, semester: export_semester_param, sources: @payload.dig(:filters, :sources))

    respond_to do |format|
      format.html { render "student_competencies/show" }
      format.csv do
        record_export_audit!(
          export_type: "student_competencies_csv",
          description: "Exported detailed competency CSV for #{@student.user&.email || @student.student_id}.",
          subject: @student,
          metadata: { student_id: @student.student_id }
        )
        send_data @payload[:csv],
                  filename: "student-competencies-#{@student.student_id}-#{Time.current.strftime('%Y%m%d-%H%M')}.csv",
                  type: "text/csv"
      end
      format.pdf do
        record_export_audit!(
          export_type: "student_competencies_pdf",
          description: "Exported detailed competency PDF for #{@student.user&.email || @student.student_id}.",
          subject: @student,
          metadata: { student_id: @student.student_id }
        )
        send_competency_pdf(
          template: "student_competencies/pdf",
          filename: "student-competencies-#{@student.student_id}-#{Time.current.strftime('%Y%m%d-%H%M')}.pdf"
        )
      end
    end
  end

  def export
    payload = competency_payload
    record_export_audit!(
      export_type: "competency_matrix_csv",
      description: "Exported competency matrix CSV.",
      metadata: { filters: payload[:filters] }
    )

    send_data competencies_csv(payload),
              filename: "competencies-matrix-#{Time.current.strftime('%Y%m%d-%H%M')}.csv",
              type: "text/csv"
  end

  def course_rule
    rule = SiteSetting.set_course_competency_rule!(params[:course_competency_rule])
    redirect_to admin_competencies_path,
                notice: "Course competency rule updated to #{CourseCompetencyRule.label_for(rule)}."
  end

  private

  def competency_payload
    Admin::CompetencyMatrix.new(params: competency_filter_params, actor_user: current_user).call
  end

  def accessible_student_scope
    scope = Student.includes(:user)
    return scope if current_user&.role_admin?

    return Student.where(advisor_id: current_advisor_profile.advisor_id) if current_user&.role_advisor? && current_advisor_profile.present?

    Student.none
  end

  def require_competency_access!
    return if current_user&.role_admin? || current_user&.role_advisor?

    if current_user&.role_student?
      redirect_to dashboard_path
    else
      redirect_to dashboard_path, alert: "Access denied. Admin or advisor privileges required."
    end
  end

  def competency_filter_params
    params.permit(:q, :track, :program_year, :advisor_id, :semester, :domain, :student_status, competencies: [])
  end

  def student_competency_params
    params.permit(:semester, sources: [])
  end

  def export_semester_param
    @payload.dig(:filters, :semester).presence || StudentCompetencyDashboard::ALL_SEMESTERS_VALUE
  end

  def send_competency_pdf(template:, filename:)
    unless defined?(WickedPdf)
      render plain: "PDF export unavailable. WickedPdf is not configured.", status: :service_unavailable
      return
    end

    html = render_to_string(template: template, layout: "pdf", formats: [ :html ])
    pdf = WickedPdf.new.pdf_from_string(html, page_size: "Letter", orientation: "Portrait")

    send_data pdf,
              filename: filename,
              disposition: "attachment",
              type: "application/pdf"
  end

  def competencies_csv(payload)
    competency_columns = payload[:domains].flat_map do |domain|
      domain[:competencies].map do |competency|
        {
          domain: domain[:name],
          title: competency[:title]
        }
      end
    end

    base_headers = [
      "Student ID",
      "Student Name",
      "Student Email",
      "UIN",
      "Track",
      "Program Year",
      "Advisor",
      "Course Competency Rule",
      "Semester Filter"
    ]

    competency_headers = competency_columns.flat_map do |competency|
      title = competency[:title]

      [
        "#{title} Domain",
        "#{title} Self Rating",
        "#{title} Advisor Rating",
        "#{title} Course Rating",
        "#{title} Program Target"
      ]
    end

    CSV.generate(headers: true) do |csv|
      csv << base_headers + competency_headers

      payload[:students].sort_by { |student| [ student[:name].to_s.downcase, student[:id].to_s ] }.each do |student|
        row = [
          student[:id],
          student[:name],
          student[:email],
          student[:uin],
          student[:track],
          student[:program_year],
          student[:advisor_name],
          payload[:course_competency_rule_label],
          payload.dig(:filters, :semester).presence || "All semesters"
        ]

        competency_columns.each do |competency|
          ratings = student.dig(:ratings, competency[:title]) || {}
          row += [
            competency[:domain],
            ratings[:self_rating],
            ratings[:advisor_rating],
            ratings[:course_rating],
            ratings[:program_target]
          ]
        end

        csv << row
      end
    end
  end

  def require_admin_for_course_rule!
    return if current_user&.role_admin?

    redirect_to dashboard_path, alert: "Access denied. Admin privileges required."
  end
end
