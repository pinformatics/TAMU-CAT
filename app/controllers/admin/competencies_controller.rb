# frozen_string_literal: true

require "csv"

class Admin::CompetenciesController < ApplicationController
  FILTER_SESSION_KEY = :admin_competency_matrix_filters
  FILTER_PARAM_KEYS = %w[q track program_year advisor_id semester domain student_status competencies].freeze

  helper_method :staff_competencies_path_for,
                :staff_competency_path_for,
                :staff_competencies_export_path_for,
                :staff_competencies_back_path

  before_action :require_competency_access!
  before_action :redirect_advisor_admin_competency_path!, only: %i[index show export]
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
    @competency_filter_query = competency_filter_query(@filters)
  end

  def show
    @student = accessible_student_scope.includes(:user, advisor: :user).find_by(student_id: params[:id])
    unless @student
      redirect_to staff_competencies_path_for, alert: "That student competency record is not available from your account."
      return
    end

    @payload = StudentCompetencyDashboard.new(student: @student, params: student_competency_params).call
    @competency_page_title = "#{@student.user&.display_name || @student.full_name} Competencies"
    @competency_page_subtitle = "Student-facing competency modules for advising review: source guide, changes, summary, graphs, and target comparison."
    @competency_back_path = staff_competencies_path_for
    @competency_form_path = staff_competency_path_for(@student)
    @competency_export_path = staff_competency_path_for(@student, format: :csv, semester: export_semester_param, sources: @payload.dig(:filters, :sources))
    @competency_pdf_path = staff_competency_path_for(@student, format: :pdf, semester: export_semester_param, sources: @payload.dig(:filters, :sources))

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
    redirect_to staff_competencies_path_for,
                notice: "Course competency rule updated to #{CourseCompetencyRule.label_for(rule)}."
  end

  private

  def redirect_advisor_admin_competency_path!
    return unless current_user&.role_advisor?
    return unless request.get? || request.head?
    return unless request.path.start_with?("/admin/competencies")

    redirect_to advisor_competency_redirect_target, status: :see_other
  end

  def advisor_competency_redirect_target
    query = request.query_parameters.symbolize_keys

    case action_name
    when "show"
      competency_path(params[:id], query.merge(format: params[:format].presence).compact)
    when "export"
      export_competencies_path(query.merge(format: params[:format].presence).compact)
    else
      competencies_path(query)
    end
  end

  def staff_competencies_path_for(options = {})
    current_user&.role_advisor? ? competencies_path(options) : admin_competencies_path(options)
  end

  def staff_competency_path_for(student, options = {})
    current_user&.role_advisor? ? competency_path(student, options) : admin_competency_path(student, options)
  end

  def staff_competencies_export_path_for(options = {})
    current_user&.role_advisor? ? export_competencies_path(options) : export_admin_competencies_path(options)
  end

  def staff_competencies_back_path
    current_user&.role_advisor? ? advisor_dashboard_path : admin_dashboard_path
  end

  def competency_payload
    Admin::CompetencyMatrix.new(params: remembered_competency_filter_params, actor_user: current_user).call
  end

  def remembered_competency_filter_params
    @remembered_competency_filter_params ||= begin
      if params[:clear_filters].present?
        session.delete(FILTER_SESSION_KEY)
        {}
      elsif competency_filter_request?
        filters = normalized_filter_storage(competency_filter_params)
        session[FILTER_SESSION_KEY] = filters
        filters
      else
        session[FILTER_SESSION_KEY].presence || {}
      end
    end
  end

  def competency_filter_request?
    FILTER_PARAM_KEYS.any? { |key| params.key?(key) }
  end

  def normalized_filter_storage(permitted_params)
    filters = permitted_params.to_h
    filters["competencies"] = Array(filters["competencies"]).map { |value| value.to_s.strip }.reject(&:blank?)
    filters.slice(*FILTER_PARAM_KEYS)
  end

  def competency_filter_query(filters)
    {
      "q" => filters[:q].presence,
      "track" => filters[:track].presence,
      "program_year" => filters[:program_year].presence,
      "advisor_id" => filters[:advisor_id].presence,
      "semester" => filters[:semester].presence,
      "domain" => filters[:domain].presence,
      "student_status" => filters[:student_status].presence,
      "competencies" => Array(filters[:competencies]).presence
    }.compact
  end

  def accessible_student_scope
    scope = Student.includes(:user)
    return scope if current_user&.role_admin?

    return Student.where(advisor_id: current_advisor_profile.advisor_id) if current_user&.role_advisor? && current_advisor_profile.present?

    Student.none
  end

  def require_competency_access!
    return if current_user&.role_admin? || current_user&.role_advisor?

    redirect_to dashboard_path, alert: STAFF_ONLY_MESSAGE
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

    redirect_to dashboard_path, alert: ADMIN_ONLY_MESSAGE
  end
end
