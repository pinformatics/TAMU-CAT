# Allows an assigned advisor to create/update their confidential note for a
# specific student+survey pair.
#
# Notes are never exposed to students or admins (unless the admin is actively
# impersonating an advisor, in which case the session is enforced read-only).
class ConfidentialAdvisorNotesController < ApplicationController
  before_action :set_survey_response
  before_action :authorize!

  def update
    advisor_id = note_owner_advisor_id
    unless advisor_id
      redirect_back fallback_location: survey_response_path(@survey_response), alert: "We could not save the confidential note."
      return
    end

    note = ConfidentialAdvisorNote.find_or_initialize_by(
      student_id: @survey_response.student_id,
      survey_id: @survey_response.survey_id,
      advisor_id: advisor_id
    )

    body = confidential_advisor_note_params[:body].to_s

    if body.strip.blank?
      note.destroy if note.persisted?
      redirect_to return_path, notice: "Confidential note cleared."
      return
    end

    note.body = body
    note.save!

    redirect_to return_path, notice: "Confidential note saved."
  rescue ActiveRecord::RecordInvalid
    redirect_to return_path, alert: "We could not save the confidential note."
  end

  private

  def confidential_advisor_note_params
    params.require(:confidential_advisor_note).permit(:body)
  end

  def set_survey_response
    @survey_response = SurveyResponse.find_from_param(params[:id])
  end

  def authorize!
    current = current_user
    unless current&.role_advisor? || current&.role_admin?
      head :unauthorized and return
    end

    if current&.role_advisor?
      advisor_profile = current_advisor_profile
      assigned_advisor_id = @survey_response&.advisor_id

      unless advisor_profile && assigned_advisor_id.present? && advisor_profile.advisor_id == assigned_advisor_id
        head :unauthorized
      end
    end
  end

  def note_owner_advisor_id
    current = current_user

    if current&.role_advisor?
      return current_advisor_profile&.advisor_id
    end

    if current&.role_admin?
      return @survey_response&.advisor_id
    end

    nil
  end

  def return_path
    return_to = params[:return_to].to_s
    return return_to if return_to.start_with?("/") && !return_to.start_with?("//")

    survey_id = params[:survey_id].presence
    student_id = params[:student_id].presence

    if survey_id && student_id
      return new_feedback_path(survey_id: survey_id, student_id: student_id)
    end

    survey_response_path(@survey_response)
  end
end
