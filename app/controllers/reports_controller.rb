# frozen_string_literal: true

require "csv"

class ReportsController < ApplicationController
  before_action :ensure_reports_access!
  before_action :ensure_admin_access!, only: %i[ overview_and_user_guide example_reports ]

  def show
    @report_tab = normalize_report_tab(params[:report_tab])
    @report_insights = Reports::CompetencyInsights.new(user: current_user, params: reports_filter_params).call
    @course_competency_report = Reports::CourseCompetencyReport.new(user: current_user, params: reports_filter_params).call
    @portfolio_exporter = StudentPortfolioExporter.new(actor_user: current_user, params: portfolio_filter_params)
    @portfolio_rows = @report_tab == "portfolio_export" ? @portfolio_exporter.rows : []
  end

  def export_pdf
    payload = aggregator.export_payload
    course_report = Reports::CourseCompetencyReport.new(user: current_user, params: reports_filter_params).call
    section = normalize_export_section(reports_params[:section])
    y_axis_mode = normalize_y_axis_mode(reports_params[:y_axis])

    unless defined?(WickedPdf)
      render plain: "PDF export unavailable. WickedPdf is not configured.", status: :service_unavailable
      return
    end

    record_export_audit!(
      export_type: "reports_pdf",
      description: "Exported program reports PDF.",
      metadata: reports_filter_params.to_h.merge(section: section.presence || "dashboard", y_axis: y_axis_mode)
    )

    html = render_to_string(
      template: "reports/export",
      layout: "report_pdf",
      locals: { payload: payload, course_report: course_report, export_section: section, y_axis_mode: y_axis_mode }
    )

    pdf = WickedPdf.new.pdf_from_string(html, page_size: "Letter", orientation: "Landscape")

    send_data pdf,
              filename: "health-reports-#{Time.current.strftime('%Y%m%d-%H%M')}.pdf",
              disposition: "attachment",
              type: "application/pdf"
  end

  def overview_and_user_guide
    return pdf_unavailable unless defined?(WickedPdf)

    html = render_to_string(template: "reports/overview_and_user_guide", layout: "report_pdf", formats: [ :html ])
    send_document_pdf(html, "TAMU-CAT-Overview-and-User-Guide.pdf", "reports_user_guide_pdf")
  end

  def example_reports
    return pdf_unavailable unless defined?(WickedPdf)

    html = render_to_string(template: "reports/example_reports", layout: "report_pdf", formats: [ :html ])
    send_document_pdf(html, "TAMU-CAT-Example-Reports.pdf", "reports_example_reports_pdf")
  end

  # Generates one PDF per (track, program year) cohort combination the
  # current user can see, and bundles them into a single zip download.
  # Each track's students have their own program target levels, so cohorts
  # are never combined into one report -- see CAHME feedback that drove this.
  def export_by_cohort
    unless defined?(WickedPdf)
      render plain: "PDF export unavailable. WickedPdf is not configured.", status: :service_unavailable
      return
    end

    base_params = reports_filter_params.to_h.except("track", "program_year")
    combinations = Reports::DataAggregator.new(user: current_user, params: base_params).available_track_year_combinations

    if combinations.empty?
      redirect_to reports_path, alert: "No cohort data is available to export."
      return
    end

    record_export_audit!(
      export_type: "reports_pdf_by_cohort",
      description: "Exported program reports PDF bundle by track/cohort.",
      metadata: { cohorts: combinations }
    )

    zip_buffer = Zip::OutputStream.write_buffer do |zip|
      combinations.each do |combo|
        cohort_params = base_params.merge("track" => combo[:track_key], "program_year" => combo[:program_year].to_s)
        cohort_payload = Reports::DataAggregator.new(user: current_user, params: cohort_params).export_payload
        cohort_course_report = Reports::CourseCompetencyReport.new(user: current_user, params: cohort_params).call

        html = render_to_string(
          template: "reports/export",
          layout: "report_pdf",
          locals: { payload: cohort_payload, course_report: cohort_course_report, export_section: nil, y_axis_mode: nil }
        )
        pdf = WickedPdf.new.pdf_from_string(html, page_size: "Letter", orientation: "Landscape")

        zip.put_next_entry("mha-program-analytics-#{combo[:track_key]}-#{combo[:program_year]}.pdf")
        zip.write(pdf)
      end
    end

    send_data zip_buffer.string,
              filename: "mha-program-analytics-by-cohort-#{Time.current.strftime('%Y%m%d-%H%M')}.zip",
              disposition: "attachment",
              type: "application/zip"
  end

  def export_excel
    payload = aggregator.export_payload
    package = Reports::ExcelExporter.new(payload).generate

    record_export_audit!(
      export_type: "reports_excel",
      description: "Exported program reports Excel workbook.",
      metadata: reports_filter_params.to_h
    )

    send_data package.to_stream.read,
              filename: "health-reports-#{Time.current.strftime('%Y%m%d-%H%M')}.xlsx",
              disposition: "attachment",
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def export_tab_csv
    tab = normalize_report_tab(params[:report_tab])
    csv_payload = report_tab_csv_payload(tab)

    record_export_audit!(
      export_type: csv_payload.fetch(:export_type),
      description: csv_payload.fetch(:description),
      metadata: reports_filter_params.to_h.merge(report_tab: tab)
    )

    send_data csv_payload.fetch(:csv),
              filename: "#{csv_payload.fetch(:filename_prefix)}-#{Time.current.strftime('%Y%m%d-%H%M')}.csv",
              disposition: "attachment",
              type: "text/csv"
  end

  def export_portfolio
    exporter = StudentPortfolioExporter.new(actor_user: current_user, params: portfolio_filter_params)
    package = exporter.workbook

    record_export_audit!(
      export_type: "student_profile_portfolio_excel",
      description: "Exported student profile portfolio workbook.",
      metadata: { filters: portfolio_filter_params.to_h }
    )

    send_data package.to_stream.read,
              filename: "student-profile-portfolio-export-#{Time.current.strftime('%Y%m%d-%H%M')}.xlsx",
              disposition: "attachment",
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def export_course_competencies
    report = Reports::CourseCompetencyReport.new(user: current_user, params: reports_filter_params)

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

    redirect_to dashboard_path, alert: STAFF_ONLY_MESSAGE
  end

  def ensure_admin_access!
    return if current_user&.role_admin?

    redirect_to reports_path, alert: "Administrator access is required for these documents."
  end

  def pdf_unavailable
    render plain: "PDF export unavailable. WickedPdf is not configured.", status: :service_unavailable
  end

  def send_document_pdf(html, filename, export_type)
    pdf = WickedPdf.new.pdf_from_string(html, page_size: "Letter", orientation: "Portrait")
    record_export_audit!(
      export_type: export_type,
      description: "Exported TAMU-CAT documentation PDF.",
      metadata: { filters: reports_filter_params.to_h }
    )

    send_data pdf, filename: filename, disposition: "attachment", type: "application/pdf"
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
      :domain,
      :section,
      :y_axis,
      :report_tab,
      :q,
      :program_year,
      :student_status,
      :program_semester_id,
      :course_program_semester_id,
      :course_code,
      :course_track,
      :course_class_of,
      :class_of,
      :release_status,
      competencies: []
    )
  end

  def reports_filter_params
    reports_params.except(:section, :y_axis, :report_tab)
  end

  def portfolio_filter_params
    reports_params.slice(:q, :track, :program_year)
  end

  def normalize_report_tab(value)
    normalized = value.to_s.strip
    allowed = %w[dashboard course_target cohort_comparison domain_heatmap portfolio_export]
    allowed.include?(normalized) ? normalized : "dashboard"
  end

  def report_tab_csv_payload(tab)
    case tab
    when "course_target"
      {
        csv: Reports::CourseCompetencyReport.new(user: current_user, params: reports_filter_params).csv,
        filename_prefix: "course-competency-report",
        export_type: "course_competency_report_csv",
        description: "Exported course competency report CSV."
      }
    when "cohort_comparison"
      {
        csv: cohort_comparison_csv,
        filename_prefix: "cohort-comparison-report",
        export_type: "cohort_comparison_report_csv",
        description: "Exported cohort comparison report CSV."
      }
    when "domain_heatmap"
      {
        csv: heatmaps_csv,
        filename_prefix: "heatmaps-report",
        export_type: "heatmaps_report_csv",
        description: "Exported heatmaps report CSV."
      }
    else
      {
        csv: dashboard_summary_csv,
        filename_prefix: "dashboard-summary-report",
        export_type: "dashboard_summary_report_csv",
        description: "Exported dashboard summary report CSV."
      }
    end
  end

  def cohort_comparison_csv
    insights = Reports::CompetencyInsights.new(user: current_user, params: reports_filter_params).call

    CSV.generate(headers: true) do |csv|
      csv << [ "Semester", "Cohort", "Students", "Self Avg", "Advisor Avg", "Course Avg", "Below Program Target" ]
      Array(insights[:cohort_comparison]).each do |row|
        csv << [
          row[:semester],
          row[:program_year],
          row[:student_count],
          row[:self_average],
          row[:advisor_average],
          row[:course_average],
          row[:below_target_count]
        ]
      end
    end
  end

  def heatmaps_csv
    insights = Reports::CompetencyInsights.new(user: current_user, params: reports_filter_params).call
    course_report = Reports::CourseCompetencyReport.new(user: current_user, params: reports_filter_params).call

    CSV.generate do |csv|
      csv << [ "Course Heatmap" ]
      csv << [
        "Course", "Student", "Competencies", "Semester", "Track",
        "Class", "Course Achievement Level", "Rows", "Below Course Target", "No Course Target"
      ]
      course_heatmap_rows = Array(course_report[:student_course_heatmap]).sort_by do |row|
        [ row[:course_code].to_s, row[:student_name].to_s.downcase, row[:semester_names].to_s ]
      end
      course_heatmap_rows.each do |row|
        csv << [
          row[:course_code],
          row[:student_name],
          Array(row[:competency_titles]).join("; "),
          row[:semester_names],
          row[:track],
          row[:class_of],
          row[:average],
          row[:evidence_count],
          row[:below_count],
          row[:no_target_count]
        ]
      end

      csv << []
      csv << [ "Student by Domain Heatmap" ]
      domain_names = Array(insights[:heatmap]).first&.dig(:domains).to_a.map { |domain| domain[:name] }
      csv << [ "Student", "Track", "Class", *domain_names ]
      Array(insights[:heatmap]).each do |row|
        csv << [
          row[:student_name],
          row[:track],
          row[:program_year],
          *Array(row[:domains]).map { |domain| domain[:average] }
        ]
      end
    end
  end

  def dashboard_summary_csv
    payload = aggregator.export_payload
    cards = Array(payload.dig(:benchmark, :cards))

    CSV.generate(headers: true) do |csv|
      csv << [ "Metric", "Value", "Change", "Description", "Sample Size" ]
      cards.each do |card|
        csv << [ card[:title], card[:value], card[:change], card[:description], card[:sample_size] ]
      end
    end
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
