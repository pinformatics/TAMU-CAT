# frozen_string_literal: true

class StudentPortfolioExportsController < ApplicationController
  before_action :require_export_access!

  def index
    @exporter = StudentPortfolioExporter.new(actor_user: current_user, params: filter_params)
    @rows = @exporter.rows
  end

  def show
    exporter = StudentPortfolioExporter.new(actor_user: current_user, params: filter_params)
    package = exporter.workbook
    record_export_audit!(
      export_type: "student_portfolio_excel",
      description: "Exported student portfolio workbook.",
      metadata: { filters: filter_params.to_h }
    )

    send_data package.to_stream.read,
              filename: "student-portfolio-urls-#{Time.current.strftime('%Y%m%d-%H%M')}.xlsx",
              disposition: "attachment",
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  private

  def require_export_access!
    return if current_user&.role_admin? || current_user&.role_advisor?

    redirect_to dashboard_path, alert: "Portfolio exports are only available to administrators and advisors."
  end

  def filter_params
    params.permit(:q, :track, :program_year)
  end
end
