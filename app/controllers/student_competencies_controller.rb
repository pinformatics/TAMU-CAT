# frozen_string_literal: true

class StudentCompetenciesController < ApplicationController
  before_action :require_student!

  def show
    @payload = dashboard_payload

    respond_to do |format|
      format.html
      format.csv do
        send_data @payload[:csv],
                  filename: "my-competencies-#{Time.current.strftime('%Y%m%d-%H%M')}.csv",
                  type: "text/csv"
      end
      format.pdf do
        send_competency_pdf(
          template: "student_competencies/pdf",
          filename: "my-competencies-#{Time.current.strftime('%Y%m%d-%H%M')}.pdf"
        )
      end
    end
  end

  private

  def dashboard_payload
    StudentCompetencyDashboard.new(student: current_user.student_profile, params: dashboard_params).call
  end

  def dashboard_params
    params.permit(:semester, sources: [])
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

  def require_student!
    return if current_user&.role_student? && current_user.student_profile.present?

    redirect_to dashboard_path, alert: "The student competency dashboard is available only to students."
  end
end
