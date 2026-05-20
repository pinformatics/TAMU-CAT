# Displays a consolidated stream of admin-relevant activity, including
# survey change logs and student submission events.
class Admin::ActivitiesController < Admin::BaseController
  # Lists recent activity entries from multiple sources.
  #
  # @return [void]
  def index
    @search_query = params[:q].to_s.strip

    @survey_logs = SurveyChangeLog
      .includes(:survey, :admin)
      .order(created_at: :desc)
      .limit(150)

    @submission_logs = SurveyResponseVersion
      .includes(:survey, student: :user)
      .where(event: %w[submitted revised edited])
      .order(created_at: :desc)
      .limit(150)

    @feedback_submission_logs = AdvisorFeedbackSubmission
      .includes(:survey, :student, advisor: :user)
      .order(Arel.sql("COALESCE(last_saved_at, submitted_at, updated_at) DESC"))
      .limit(150)

    @admin_activity_logs = AdminActivityLog
      .includes(:admin)
      .recent
      .limit(150)

    @entries = filtered_entries(build_entries)
      .sort_by { |entry| entry[:timestamp] || Time.zone.at(0) }
      .reverse
      .first(200)
  end

  private

  def build_entries
    survey_entries = @survey_logs.map do |log|
      survey_title = log.survey_title_snapshot.presence || log.survey&.title.presence || "Survey ##{log.survey_id}"
      admin_name = log.admin&.display_name.presence || log.admin&.email || "Admin"

      {
        type: "Survey Change",
        icon: "SUR",
        timestamp: log.created_at,
        title: "#{log.action.to_s.titleize}: #{survey_title}",
        subtitle: log.description.presence || "Updated by #{admin_name}",
        actor: admin_name,
        link: log.survey.present? ? edit_admin_survey_path(log.survey) : nil
      }
    end

    submission_entries = @submission_logs.map do |version|
      survey_title = version.survey&.title.presence || "Survey ##{version.survey_id}"
      student_name = version.student&.user&.name.presence || "Student ##{version.student_id}"
      event_label = case version.event.to_s
      when "revised"
        "Revised"
      when "edited"
        "Edited"
      else
        "Submitted"
      end

      {
        type: "Student Submission",
        icon: "SUB",
        timestamp: version.created_at,
        title: "#{event_label}: #{student_name}",
        subtitle: survey_title,
        actor: student_name,
        link: student_records_path
      }
    end

    survey_entries + submission_entries + feedback_entries + admin_activity_entries
  end

  def admin_activity_entries
    @admin_activity_logs.map do |log|
      admin_name = log.admin&.display_name.presence || log.admin&.email || "Admin"

      {
        type: "Admin Action",
        icon: "ADM",
        timestamp: log.created_at,
        title: log.action.to_s.titleize,
        subtitle: log.description,
        actor: admin_name,
        link: admin_activity_link_for(log)
      }
    end
  end

  def admin_activity_link_for(log)
    return people_management_path(tab: "students") if log.action == "student_lifecycle_update"
    return people_management_path if log.action.in?(%w[role_update member_removal])
    return people_management_path(tab: "students") if log.action.in?(%w[advisor_assignment bulk_advisor_assignment track_update])

    nil
  end

  def feedback_entries
    @feedback_submission_logs.flat_map do |submission|
      survey_title = submission.survey&.title.presence || "Survey ##{submission.survey_id}"
      student_name = submission.student&.user&.name.presence || "Student ##{submission.student_id}"
      advisor_name = submission.advisor&.display_name.presence || submission.advisor&.email || "Advisor ##{submission.advisor_id}"

      entries = []

      if submission.submitted_at.present?
        entries << {
          type: "Advisor Feedback",
          icon: "FBK",
          timestamp: submission.submitted_at,
          title: "Feedback submitted: #{student_name}",
          subtitle: "#{advisor_name} on #{survey_title}",
          actor: advisor_name,
          link: student_records_path
        }
      end

      changed_after_submit = submission.submitted_at.present? && submission.last_saved_at.present? && submission.last_saved_at > submission.submitted_at
      draft_changed = submission.submitted_at.blank? && submission.last_saved_at.present?

      if changed_after_submit || draft_changed
        entries << {
          type: "Advisor Feedback",
          icon: "FBK",
          timestamp: submission.last_saved_at,
          title: "Feedback changed: #{student_name}",
          subtitle: "#{advisor_name} on #{survey_title}",
          actor: advisor_name,
          link: student_records_path
        }
      end

      entries
    end
  end

  def filtered_entries(entries)
    return entries if @search_query.blank?

    term = @search_query.downcase
    entries.select do |entry|
      [
        entry[:type],
        entry[:title],
        entry[:subtitle],
        entry[:actor]
      ].compact.any? { |value| value.to_s.downcase.include?(term) }
    end
  end
end
