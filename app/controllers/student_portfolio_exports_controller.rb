# frozen_string_literal: true

class StudentPortfolioExportsController < ApplicationController
  before_action :require_export_access!

  def index
    redirect_to reports_path(filter_params.to_h.merge(report_tab: "portfolio_export"))
  end

  def show
    redirect_to export_reports_portfolio_path(filter_params.to_h)
  end

  private

  def require_export_access!
    return if current_user&.role_admin? || current_user&.role_advisor?

    redirect_to dashboard_path, alert: STAFF_ONLY_MESSAGE
  end

  def filter_params
    params.permit(:q, :track, :program_year)
  end
end
