# frozen_string_literal: true

module Api
  class ReportsController < ApplicationController
    before_action :ensure_reports_access!

    def filters
      render json: aggregator.filter_options
    end

    def benchmark
      render json: aggregator.benchmark
    end

    def competency_summary
      render json: aggregator.competency_summary
    end

    def competency_detail
      render json: aggregator.competency_detail
    end

    def track_summary
      render json: aggregator.track_summary
    end

    def employment_summary
      render json: aggregator.employment_summary
    end

    private

    def ensure_reports_access!
      return if current_user.role_admin? || current_user.role_advisor?

      render json: { error: "Access denied" }, status: :forbidden
    end

    def aggregator
      @aggregator ||= Reports::DataAggregator.new(user: current_user, params: reports_params)
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
        :q,
        :program_year,
        :student_status,
        competencies: []
      )
    end
  end
end
