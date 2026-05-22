# frozen_string_literal: true

class ReportsController < ApplicationController
  before_action :ensure_reports_access!

  def show
    @report_insights = Reports::CompetencyInsights.new(user: current_user, params: reports_filter_params).call
    @course_competency_report = Reports::CourseCompetencyReport.new(params: reports_filter_params).call
  end

  def export_pdf
    payload = aggregator.export_payload
    section = normalize_export_section(reports_params[:section])
    y_axis_mode = normalize_y_axis_mode(reports_params[:y_axis])

    unless defined?(WickedPdf)
      render plain: "PDF export unavailable. WickedPdf is not configured.", status: :service_unavailable
      return
    end

    record_export_audit!(
      export_type: "reports_pdf",
      description: "Exported program reports PDF.",
      metadata: { section: section.presence || "dashboard", y_axis: y_axis_mode }
    )

    html = render_to_string(
      template: "reports/export",
      layout: "report_pdf",
      locals: { payload: payload, export_section: section, y_axis_mode: y_axis_mode }
    )

    pdf = WickedPdf.new.pdf_from_string(html, page_size: "Letter", orientation: "Landscape")

    send_data pdf,
              filename: "health-reports-#{Time.current.strftime('%Y%m%d-%H%M')}.pdf",
              disposition: "attachment",
              type: "application/pdf"
  end

  def export_excel
    payload = aggregator.export_payload
    package = Reports::ExcelExporter.new(payload).generate

    record_export_audit!(
      export_type: "reports_excel",
      description: "Exported program reports Excel workbook."
    )

    send_data package.to_stream.read,
              filename: "health-reports-#{Time.current.strftime('%Y%m%d-%H%M')}.xlsx",
              disposition: "attachment",
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def export_course_competencies
    report = Reports::CourseCompetencyReport.new(params: reports_filter_params)

    record_export_audit!(
      export_type: "course_competency_report_csv",
      description: "Exported course competency report CSV.",
      metadata: reports_filter_params.to_h
    )

    send_data report.csv,
              filename: "course-competency-report-#{Time.current.strftime('%Y%m%d-%H%M')}.csv",
              disposition: "attachment",
              type: "text/csv"
  end

  private

  def ensure_reports_access!
    return if current_user.role_admin? || current_user.role_advisor?

    redirect_to dashboard_path, alert: "Reports are only available to administrators and advisors."
  end

  def aggregator
    @aggregator ||= Reports::DataAggregator.new(user: current_user, params: reports_filter_params)
  end

  def reports_params
    params.permit(
      :track,
      :semester,
      :survey_id,
      :category_id,
      :student_id,
      :advisor_id,
      :competency,
      :section,
      :y_axis,
      :program_semester_id,
      :course_program_semester_id,
      :course_code,
      :course_track,
      :course_class_of,
      :class_of,
      :release_status
    )
  end

  def reports_filter_params
    reports_params.except(:section, :y_axis)
  end

  def normalize_export_section(value)
    normalized = value.to_s.strip
    return nil if normalized.blank?
    return nil if %w[dashboard all full default].include?(normalized)

    normalized
  end

  def normalize_y_axis_mode(value)
    normalized = value.to_s.strip.downcase
    return "percent" if normalized == "percent"

    "score"
  end
end
