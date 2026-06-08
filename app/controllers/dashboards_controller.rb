require "set"

# Presents role-aware dashboards and administrative utilities for students,
# advisors, and administrators within the main application.
class DashboardsController < ApplicationController
  skip_before_action :check_student_profile_complete, only: :switch_role
  before_action :ensure_profile_present, only: %i[student advisor]
  before_action :ensure_role_switch_allowed, only: :switch_role

  # Redirects the signed-in user to their primary role dashboard.
  #
  # @return [void]
  def show
    case current_user.role
    when "student"
      redirect_to student_dashboard_path
    when "advisor"
      redirect_to advisor_dashboard_path
    when "admin"
      redirect_to admin_dashboard_path
    else
      redirect_to student_dashboard_path
    end
  end

  # Renders the student dashboard with survey completion summaries and
  # download links.
  #
  # @return [void]
  def student
    @student = current_student

    unless @student
      redirect_to dashboard_path, alert: "We could not find that student profile." and return
    end

    surveys = surveys_for_student(@student)

    @offerings_by_survey_id = {}
    if SurveyOffering.data_source_ready? && @student.program_year.present? && @student.track_key.present? && surveys.any?
      offerings = SurveyOffering
                    .for_student(track_key: @student.track_key, class_of: @student.program_year)
                    .where(survey_id: surveys.map(&:id))

      grouped = offerings.group_by(&:survey_id)
      grouped.each do |survey_id, rows|
        exact = rows.find { |row| row.class_of.present? && row.class_of.to_i == @student.program_year.to_i }
        @offerings_by_survey_id[survey_id] = exact || rows.first
      end
    end

    student_responses = StudentQuestion
                          .joins(question: :category)
                          .where(student_id: @student.student_id)
                          .where.not(response_value: [ nil, "" ])
                          .select(
                            "categories.survey_id AS survey_id",
                            "student_questions.question_id",
                            "student_questions.updated_at"
                          )

    responses_matrix = Hash.new { |hash, key| hash[key] = [] }
    student_responses.each do |entry|
      responses_matrix[entry.survey_id] << { question_id: entry.question_id, updated_at: entry.updated_at }
    end

    # Load assignment records to determine true completion (submit) status
    assignments = SurveyAssignment
                    .where(student_id: @student.student_id, survey_id: surveys.map(&:id))
                    .index_by(&:survey_id)

    admin_update_by_survey = SurveyResponseVersion
                  .where(student_id: @student.student_id, survey_id: surveys.map(&:id), event: %w[admin_edited admin_deleted])
                  .group(:survey_id)
                  .maximum(:created_at)

    @completed_surveys = []
    @pending_surveys = []
    now = Time.current

    surveys.each do |survey|
      parent_questions = survey.questions
      parent_questions = parent_questions.parent_questions if parent_questions.respond_to?(:parent_questions)
      branch_parent_ids = SurveyQuestionRules.branch_parent_ids(survey.questions.to_a)
      parent_question_ids = parent_questions.map(&:id)

      required_ids = parent_questions.select { |question| required_question?(question, branch_parent_ids:) }.map(&:id)
      responses = responses_matrix[survey.id]
      answered_ids = responses.map { |entry| entry[:question_id] }.uniq & parent_question_ids
      answered_required_count = (answered_ids & required_ids).size
      total_required_count = required_ids.size
      total_questions = parent_question_ids.size
      answered_total_count = answered_ids.size
      answered_optional_count = [ answered_total_count - answered_required_count, 0 ].max
      total_optional_count = [ total_questions - total_required_count, 0 ].max
      progress_summary = {
        answered_total: answered_total_count,
        total_questions: total_questions,
        answered_required: answered_required_count,
        total_required: total_required_count,
        answered_optional: answered_optional_count,
        total_optional: total_optional_count
      }
      # Only consider a survey "Completed" when it was submitted, not just answered
      assignment = assignments[survey.id]
      completed_at = assignment&.completed_at
      available_from = assignment&.available_from.presence || survey.available_from
      available_until = assignment&.available_until.presence || survey.available_until

      survey_response = SurveyResponse.build(student: @student, survey: survey)
      survey_summary = {
        survey: survey,
        answered_count: answered_total_count,
        total_count: total_questions,
        progress: progress_summary,
        required_answered_count: answered_required_count,
        required_total_count: total_required_count,
        completed_at: completed_at,
        available_from: available_from,
        available_until: available_until,
        admin_updated_at: admin_update_by_survey[survey.id],
        required: required_ids.present?,
        survey_response: survey_response,
        download_token: survey_response.signed_download_token
      }

      if completed_at.present?
        @completed_surveys << survey_summary.merge(status: "Completed")
      else
        next if available_from.present? && available_from > now
        next if available_until.present? && available_until < now

        @pending_surveys << survey_summary.merge(status: "Pending")
      end
    end

    @dashboard_notifications = dashboard_notifications_scope.unread.recent.limit(5)
  end

  # Displays advisor-specific information such as advisees and recent feedback.
  #
  # @return [void]
  def advisor
    @advisor = current_advisor_profile
    @advisees = (@advisor&.advisees || Student.none).current_records.includes(:user)
    advisee_ids = @advisees.map(&:student_id)
    @recent_feedback = Feedback.where(advisor_id: @advisor&.advisor_id, student_id: advisee_ids).includes(:category, :survey, :student).order(created_at: :desc).limit(5)
    @pending_notifications_count = dashboard_notifications_scope.unread.count

    @advisee_count = @advisees.size
    @active_survey_count = Survey.count
    advisee_ids = Array(@advisees).map(&:student_id).compact
    @total_reports = advisee_ids.empty? ? 0 : SurveyAssignment.where(student_id: advisee_ids).count
    @survey_record_counts = survey_record_counts(student_ids: advisee_ids)
    @dashboard_notifications = dashboard_notifications_scope.recent.limit(5)
  end

  # Shows high-level system metrics for administrators.
  #
  # @return [void]
  def admin
    return unless ensure_admin!

    @role_counts = {
      student: User.students.count,
      advisor: User.advisors.count,
      admin: User.admins.count
    }

    @total_surveys = Survey.count
    @total_responses = StudentQuestion.count
    @total_reports = SurveyAssignment.count
    @survey_record_counts = survey_record_counts
    @maintenance_enabled = SiteSetting.maintenance_enabled?
    @dashboard_notifications = dashboard_notifications_scope.recent.limit(5)
  end

  # Provides a single admin workspace for member and student management.
  #
  # @return [void]
  def people_management
    return unless ensure_admin!

    @people_tab = params[:tab].to_s.presence_in(%w[members students]) || "members"

    if @people_tab == "students"
      load_student_management_state
    else
      load_member_management_state
    end
  end

  # Lists all members and role counts for admin management.
  #
  # @return [void]
  def manage_members
    redirect_to people_management_path(tab: "members", q: params[:q].presence)
  end

  # Applies role updates submitted by admins, reporting successes and failures.
  #
  # @return [void]
  def update_roles
    ensure_admin!

    role_updates = params[:role_updates] || {}
    if role_updates.empty?
      redirect_to people_management_path(tab: "members"), alert: "No role changes were submitted."
      return
    end

    allowed_roles = User.roles.values
    successful_updates = []
    failed_updates = []

    ActiveRecord::Base.transaction do
      role_updates.each do |user_id, new_role|
        user = User.find_by(id: user_id)
        unless user
          failed_updates << "User ID #{user_id}: not found"
          next
        end

        if user == current_user
          failed_updates << "#{user.email}: cannot change your own role"
          next
        end

        unless allowed_roles.include?(new_role)
          failed_updates << "#{user.email}: invalid role '#{new_role}'"
          next
        end

        next if user.role == new_role

        previous_role = user.role
        user.update!(role: new_role)
        successful_updates << "#{user.email}: #{previous_role} → #{new_role}"
      rescue StandardError => e
        Rails.logger.error "Error updating user #{user_id}: #{e.message}"
        failed_updates << "User ID #{user_id}: #{e.message}"
      end
    end

    log_metadata = { successes: successful_updates, failures: failed_updates }.reject { |_k, v| v.blank? }

    if successful_updates.present?
      message = "Updated #{successful_updates.size} user role#{'s' if successful_updates.size > 1}."
      message += " Failures: #{failed_updates.join(', ')}" if failed_updates.present?
      AdminActivityLog.record!(
        admin: current_user,
        action: "role_update",
        description: message,
        metadata: log_metadata
      ) if log_metadata.present?
      redirect_to people_management_path(tab: "members"), notice: message
    elsif failed_updates.present?
      error_message = "Role update errors: #{failed_updates.join(', ')}"
      AdminActivityLog.record!(
        admin: current_user,
        action: "role_update",
        description: error_message,
        metadata: log_metadata
      ) if log_metadata.present?
      redirect_to people_management_path(tab: "members"), alert: error_message
    else
      redirect_to people_management_path(tab: "members"), notice: "No role changes were needed."
    end
  end

  # Removes a member account entirely from the system.
  #
  # @return [void]
  def destroy_member
    return unless ensure_admin!

    user = User.find_by(id: params[:id])
    unless user
      redirect_to people_management_path(tab: "members"), alert: "Member not found."
      return
    end

    if user == current_user
      redirect_to people_management_path(tab: "members"), alert: "You cannot remove your own account."
      return
    end

    removed_user_id = user.id
    removed_email = user.email
    removed_role = user.role

    safely_destroy_member!(user)

    AdminActivityLog.record!(
      admin: current_user,
      action: "member_removal",
      description: "Removed member #{removed_email}.",
      metadata: {
        removed_user_id: removed_user_id,
        removed_user_email: removed_email,
        removed_user_role: removed_role
      }
    )

    redirect_to people_management_path(tab: "members"), notice: "Removed member #{removed_email}."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey => e
    Rails.logger.error "Failed to remove user #{params[:id]}: #{e.class} #{e.message}"
    redirect_to people_management_path(tab: "members"), alert: "We could not remove that member: #{e.message}"
  end

  # Removes multiple member accounts from the system.
  #
  # @return [void]
  def destroy_members
    return unless ensure_admin!

    member_ids = normalize_member_ids(params[:user_ids])
    if member_ids.empty?
      redirect_to people_management_path(tab: "members"), alert: "No members were selected for removal."
      return
    end

    users_by_id = User.where(id: member_ids).index_by(&:id)
    removed = []
    failed = []

    member_ids.each do |member_id|
      user = users_by_id[member_id]
      unless user
        failed << "User ID #{member_id}: not found"
        next
      end

      if user == current_user
        failed << "#{user.email}: cannot remove your own account"
        next
      end

      begin
        removed_user_id = user.id
        removed_email = user.email
        removed_role = user.role

        safely_destroy_member!(user)

        removed << removed_email
        AdminActivityLog.record!(
          admin: current_user,
          action: "member_removal",
          description: "Removed member #{removed_email}.",
          metadata: {
            removed_user_id: removed_user_id,
            removed_user_email: removed_email,
            removed_user_role: removed_role,
            batch: true
          }
        )
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey => e
        Rails.logger.error "Failed to remove user #{member_id}: #{e.class} #{e.message}"
        failed << "#{user.email}: #{e.message}"
      end
    end

    if removed.present?
      message = "Removed #{removed.size} member#{'s' if removed.size != 1}."
      message += " Failures: #{failed.join(', ')}" if failed.present?
      redirect_to people_management_path(tab: "members"), notice: message
    else
      redirect_to people_management_path(tab: "members"), alert: "We could not remove these selected members: #{failed.join(', ')}"
    end
  end

  # Returns a JSON payload summarizing users and role counts for troubleshooting.
  #
  # @return [void]
  def debug_users
    ensure_admin!

    users = User.order(:name).map do |user|
      {
        id: user.id,
        email: user.email,
        name: user.name,
        role: user.role,
        updated_at: user.updated_at
      }
    end

    render json: {
      users: users,
      role_counts: {
        student: User.students.count,
        advisor: User.advisors.count,
        admin: User.admins.count
      },
      timestamp: Time.current
    }
  end

  # Allows role switching in non-production environments for testing nested
  # dashboards.
  #
  # @return [void]
  def switch_role
    new_role = params[:role].to_s.downcase

    unless User.roles.values.include?(new_role)
      redirect_back fallback_location: dashboard_path, alert: "Unrecognized role selection." and return
    end

    if current_user.role == new_role
      redirect_to dashboard_path_for_role(new_role), notice: "Already viewing the #{new_role.titleize} dashboard." and return
    end

    begin
      current_user.update!(role: new_role)
      flash[:notice] = "Role switched to #{new_role.titleize} for testing."

      if new_role == "student"
        student = current_user.student_profile
        SurveyAssignments::AutoAssigner.call(student: student) if student
      end
    rescue StandardError => e
      Rails.logger.error "Role switch failed for user #{current_user.id}: #{e.message}"
      redirect_back fallback_location: dashboard_path, alert: "We could not switch roles: #{e.message}" and return
    end

    redirect_to dashboard_path_for_role(new_role)
  end

  def normalize_member_ids(raw_ids)
    values = case raw_ids
    when String
      raw_ids.split(/[\s,]+/)
    when Array
      raw_ids
    else
      []
    end

    values.filter_map do |value|
      numeric = value.to_s.strip
      next if numeric.blank?

      id = numeric.to_i
      id.positive? ? id : nil
    end.uniq
  end

  def safely_destroy_member!(user)
    ActiveRecord::Base.transaction do
      purge_member_survey_response_versions!(user)
      user.destroy!
    end
  end

  def purge_member_survey_response_versions!(user)
    student_ids = []
    student_ids << user.student_profile.student_id if user.student_profile.present?

    if user.advisor_profile.present?
      student_ids.concat(user.advisor_profile.advisees.pluck(:student_id))
    end

    student_ids = student_ids.compact.uniq
    return if student_ids.empty?

    assignment_ids = SurveyAssignment.where(student_id: student_ids).pluck(:id)
    version_scope = SurveyResponseVersion.where(student_id: student_ids)
    version_scope = version_scope.or(SurveyResponseVersion.where(survey_assignment_id: assignment_ids)) if assignment_ids.any?
    version_scope.delete_all
  end

  # Lists students and advisors for assignment management.
  #
  # @return [void]
  def manage_students
    redirect_to people_management_path(tab: "students", q: params[:q].presence)
  end

  # Updates the advisor assigned to a student.
  #
  # @return [void]
  def update_student_advisor
    @student = Student.find(params[:id])
    previous_advisor = @student.advisor
    @student.advisor_assignment_actor = current_user
    if @student.update(student_params)
      AdminActivityLog.record!(
        admin: current_user,
        action: "advisor_assignment",
        description: "Updated advisor for #{@student.user&.email || @student.student_id} from #{previous_advisor&.display_name || 'Unassigned'} to #{@student.advisor&.display_name || 'Unassigned'}",
        subject: @student,
        metadata: {
          previous_advisor_id: previous_advisor&.advisor_id,
          new_advisor_id: @student.advisor_id
        }
      )
      redirect_to people_management_path(tab: "students"), notice: "Advisor updated successfully."
    else
      redirect_to people_management_path(tab: "students"), alert: "We could not update the advisor."
    end
  end

  # Applies bulk advisor assignments submitted from the management table.
  #
  # @return [void]
  def update_student_advisors
    return unless ensure_admin!

    advisor_updates = normalize_student_updates(params[:advisor_updates])
    track_updates = normalize_student_updates(params[:track_updates])
    program_year_updates = normalize_student_updates(params[:program_year_updates])
    assignment_group_updates = normalize_student_updates(params[:assignment_group_updates])
    status_updates = normalize_student_updates(params[:status_updates])
    selected_student_ids = normalize_student_ids(params[:selected_student_ids])
    bulk_status = params[:bulk_status].to_s.strip.downcase.presence
    lifecycle_reason = params[:lifecycle_reason].to_s.strip.presence

    if bulk_status.present?
      if selected_student_ids.blank?
        redirect_to people_management_path(tab: "students"), alert: "Select at least one student before applying a bulk lifecycle status."
        return
      end

      selected_student_ids.each do |student_id|
        status_updates[student_id.to_s] = bulk_status
      end
    end

    if advisor_updates.blank? && track_updates.blank? && program_year_updates.blank? && assignment_group_updates.blank? && status_updates.blank?
      redirect_to people_management_path(tab: "students"), alert: "No student changes were submitted."
      return
    end

    advisor_lookup = build_advisor_lookup(advisor_updates.values)
    student_ids = (advisor_updates.keys + track_updates.keys + program_year_updates.keys + assignment_group_updates.keys + status_updates.keys).uniq
    students = Student.includes(:user, advisor: :user)
                      .where(student_id: student_ids)
                      .index_by { |student| student.student_id.to_s }

    advisor_successes = []
    advisor_failures = []
    track_successes = []
    track_failures = []
    program_year_successes = []
    program_year_failures = []
    group_successes = []
    group_failures = []
    status_successes = []
    status_failures = []

    ActiveRecord::Base.transaction do
      student_ids.each do |student_id|
        student = students[student_id]

        if student.nil?
          advisor_failures << "Student ##{student_id} not found" if advisor_updates.key?(student_id)
          track_failures << "Student ##{student_id} not found" if track_updates.key?(student_id)
          program_year_failures << "Student ##{student_id} not found" if program_year_updates.key?(student_id)
          group_failures << "Student ##{student_id} not found" if assignment_group_updates.key?(student_id)
          status_failures << "Student ##{student_id} not found" if status_updates.key?(student_id)
          next
        end

        if status_updates.key?(student_id)
          apply_status_update(student, status_updates[student_id], lifecycle_reason, status_successes, status_failures)
        end

        if track_updates.key?(student_id)
          apply_track_update(student, track_updates[student_id], track_successes, track_failures)
        end

        if program_year_updates.key?(student_id)
          apply_program_year_update(student, program_year_updates[student_id], program_year_successes, program_year_failures)
        end

        if assignment_group_updates.key?(student_id)
          apply_assignment_group_update(student, assignment_group_updates[student_id], group_successes, group_failures)
        end

        if advisor_updates.key?(student_id)
          apply_advisor_update(student, advisor_updates[student_id], advisor_lookup, advisor_successes, advisor_failures)
        end
      end
    end

    notice_parts = []
    alert_parts = []

    if advisor_successes.present?
      message = "Updated #{advisor_successes.size} student advisor assignment#{'s' if advisor_successes.size != 1}."
      message += " Failures: #{advisor_failures.join(', ')}" if advisor_failures.present?
      log_metadata = { successes: advisor_successes, failures: advisor_failures }.reject { |_k, v| v.blank? }
      AdminActivityLog.record!(
        admin: current_user,
        action: "bulk_advisor_assignment",
        description: message,
        metadata: log_metadata
      ) if log_metadata.present?
      notice_parts << message
    elsif advisor_failures.present?
      error_message = "Advisor update errors: #{advisor_failures.join(', ')}"
      AdminActivityLog.record!(
        admin: current_user,
        action: "bulk_advisor_assignment",
        description: error_message,
        metadata: { successes: [], failures: advisor_failures }
      )
      alert_parts << error_message
    end

    if track_successes.present?
      summary = "Updated #{track_successes.size} track#{'s' if track_successes.size != 1}"
      summary += ". Changes: #{track_successes.join(', ')}" if track_successes.any?
      notice_parts << "#{summary}."
    end

    if track_failures.present?
      alert_parts << "Track update errors: #{track_failures.join(', ')}"
    end

    if program_year_successes.present?
      summary = "Updated #{program_year_successes.size} class year#{'s' if program_year_successes.size != 1}"
      summary += ". Changes: #{program_year_successes.join(', ')}" if program_year_successes.any?
      notice_parts << "#{summary}."
    end

    if program_year_failures.present?
      alert_parts << "Class year update errors: #{program_year_failures.join(', ')}"
    end

    if group_successes.present?
      summary = "Updated #{group_successes.size} assignment group#{'s' if group_successes.size != 1}"
      summary += ". Changes: #{group_successes.join(', ')}" if group_successes.any?
      notice_parts << "#{summary}."
    end

    if group_failures.present?
      alert_parts << "Assignment group update errors: #{group_failures.join(', ')}"
    end

    if status_successes.present?
      summary = "Updated #{status_successes.size} student lifecycle status#{'es' if status_successes.size != 1}"
      summary += ". Changes: #{status_successes.join(', ')}" if status_successes.any?
      notice_parts << "#{summary}."
    end

    if status_failures.present?
      alert_parts << "Lifecycle update errors: #{status_failures.join(', ')}"
    end

    if notice_parts.blank? && alert_parts.blank?
      notice_parts << "No student changes were needed."
    end

    flash[:notice] = notice_parts.join(" ") if notice_parts.any?
    flash[:alert] = alert_parts.join(" ") if alert_parts.any?

    redirect_to people_management_path(tab: "students")
  end

  private

  def load_member_management_state
    if params[:q].present?
      q = params[:q].strip
      @users = User.where("name ILIKE :q OR email ILIKE :q OR uid::text ILIKE :q", q: "%#{q}%").order(:name, :email)
    else
      @users = User.order(:name, :email)
    end

    @role_counts = {
      student: User.students.count,
      advisor: User.advisors.count,
      admin: User.admins.count
    }
  end

  def dashboard_notifications_scope
    return Notification.none unless in_app_notifications_enabled_for?(current_user)

    current_user.notifications
  end

  def load_student_management_state
    @student_status_filter = Student.normalize_lifecycle_filter(params[:student_status])
    @students = load_students
    if params[:q].present?
      q = params[:q].strip
      @students = @students.where(
        "users.name ILIKE :q OR users.email ILIKE :q OR users.uid::text ILIKE :q OR students.uin ILIKE :q OR students.student_id::text ILIKE :q OR students.program_year::text ILIKE :q",
        q: "%#{q}%"
      )
    end
    @advisors = Advisor.left_joins(:user).includes(:user).order(Arel.sql("LOWER(users.name) ASC"))
    @advisor_select_options = [ [ "Unassigned", "" ] ] + @advisors.map { |advisor| [ advisor.display_name, advisor.advisor_id.to_s ] }
    @track_select_options = Student.tracks.keys.map { |key| [ key.titleize, key ] }
    @program_year_select_options = ProgramYear.values.map { |year| [ year.to_s, year.to_s ] }
    @assignment_group_select_options = build_assignment_group_select_options
    @student_status_options = Student.lifecycle_filter_options
    @lifecycle_status_select_options = Student::STATUSES.map { |status| [ status.titleize, status ] }
    @student_status_counts = Student.group(:status).count
    @student_profile_warnings = build_student_profile_warnings(@students.select(&:current_record?))
    @assignment_stats = {
      total: @students.size,
      assigned: @students.count { |student| student.advisor_id.present? },
      unassigned: @students.count { |student| student.advisor_id.blank? },
      current: Student.current_records.count,
      graduated: Student.graduated.count,
      archived: Student.archived_records.count
    }
    @can_manage = current_user.role_admin?
  end

  def build_student_profile_warnings(students)
    warning_definitions = [
      [ :missing_track, "Missing track", ->(student) { student.track_key.blank? } ],
      [ :missing_class_year, "Missing class year", ->(student) { student.program_year.blank? } ],
      [ :missing_advisor, "Unassigned advisor", ->(student) { student.advisor_id.blank? } ],
      [ :missing_uin, "Missing UIN", ->(student) { student.uin.blank? } ]
    ]

    warning_definitions.filter_map do |key, label, predicate|
      affected_students = Array(students).select { |student| predicate.call(student) }
      next if affected_students.blank?

      {
        key: key,
        label: label,
        count: affected_students.size,
        students: affected_students.first(4).map { |student| student_display_label(student) }
      }
    end
  end

  # Ensures the current user has the necessary profile record for their role.
  #
  # @return [void]
  def ensure_profile_present
    return if current_user.role_admin?

    if current_user.role_student? && current_student.nil?
      current_user.create_student_profile unless current_user.student_profile
      @current_student = current_user.student_profile
    elsif current_user.role_advisor? && current_advisor_profile.nil?
      current_user.create_advisor_profile unless current_user.advisor_profile
      @current_advisor = current_user.advisor_profile
    end
  end

  # Raises an alert when a non-admin attempts to access admin-only actions.
  #
  # @return [Boolean] false when access is denied
  def ensure_admin!
    return true if current_user.role_admin?

    redirect_to dashboard_path, alert: ADMIN_ONLY_MESSAGE
    false
  end

  # Gatekeeps the role-switch feature to development and test environments.
  #
  # @return [void]
  def ensure_role_switch_allowed
    # Always allow in development and test
    return if Rails.env.development? || Rails.env.test?

    # When ENABLE_ROLE_SWITCH=="1" the feature is explicitly enabled for this deployment.
    # In that mode, allow any signed-in user to use the switcher (useful for testing impersonation
    # flows across roles). If the flag is not set, deny access in production.
    if ENV["ENABLE_ROLE_SWITCH"] == "1" && current_user.present?
      return
    end

    redirect_to dashboard_path, alert: "Role switching is only available in development/test or when ENABLE_ROLE_SWITCH is enabled."
  end

  # Resolves the dashboard path for a given role value.
  #
  # @param role [String]
  # @return [String]
  def dashboard_path_for_role(role)
    case role
    when User.roles[:student]
      student_dashboard_path
    when User.roles[:advisor]
      advisor_dashboard_path
    when User.roles[:admin]
      admin_dashboard_path
    else
      dashboard_path
    end
  end

  # Determines whether a question must be answered to count toward completion.
  #
  # @param question [Question, nil]
  # @return [Boolean]
  def required_question?(question, branch_parent_ids: [])
    return false unless question

    SurveyQuestionRules.required_indicator?(question, branch_parent_ids:)
  end

  def surveys_for_student(student)
    return Survey.none unless student&.student_id

    # Keep dashboard listings consistent even if the sign-in callback didn't run
    # (e.g., direct session restore). This will add missing assignments for the
    # student's track/current semester and remove outdated managed assignments.
    SurveyAssignments::AutoAssigner.call(student: student)

    Survey
      .includes(:questions)
      .joins(:survey_assignments)
      .where(survey_assignments: { student_id: student.student_id })
      .distinct
      .ordered
  rescue StandardError => e
    Rails.logger.error("Dashboard auto-assign failed for student #{student&.student_id}: #{e.class}: #{e.message}")
    Survey.none
  end

  def survey_record_counts(student_ids: nil)
    scope = SurveyAssignment.all

    if student_ids
      ids = Array(student_ids).compact
      return { assigned: 0, completed: 0 } if ids.empty?

      scope = scope.where(student_id: ids)
    end

    {
      assigned: scope.count,
      completed: scope.where.not(completed_at: nil).count
    }
  end


  # Loads students visible to the current user, respecting admin/advisor scope.
  #
  # @return [ActiveRecord::Relation<Student>]
  def load_students
    has_admin_privileges = current_user&.role_admin? || current_user&.admin_profile.present?
    lifecycle_filter = Student.normalize_lifecycle_filter(params[:student_status])

    scope = if has_admin_privileges
      Student.with_lifecycle_filter(lifecycle_filter)
    else
      (current_advisor_profile&.advisees || Student.none).with_lifecycle_filter(lifecycle_filter)
    end

    scope
      .left_joins(:user)
      .includes(:user, advisor: :user)
      .order(Arel.sql("LOWER(users.name) ASC"))
  end

  # Strong parameters for assigning an advisor to a student.
  #
  # @return [ActionController::Parameters]
  def student_params
    params.require(:student).permit(:advisor_id)
  end

  # Normalizes nested form parameters keyed by student_id into a string-keyed hash.
  #
  # @param raw_updates [Hash, ActionController::Parameters, nil]
  # @return [Hash{String=>String}] string-keyed hash of updates
  def normalize_student_updates(raw_updates)
    return {} if raw_updates.blank?

    updates_hash = if raw_updates.respond_to?(:to_unsafe_h)
      raw_updates.to_unsafe_h
    else
      raw_updates
    end

    updates_hash.each_with_object({}) do |(student_id, value), memo|
      memo[student_id.to_s] = value
    end
  end

  def normalize_student_ids(raw_ids)
    values = case raw_ids
    when String
      raw_ids.split(/[\s,]+/)
    when Array
      raw_ids
    else
      []
    end

    values.filter_map do |value|
      id = value.to_s.strip.to_i
      id.positive? ? id : nil
    end.uniq
  end

  # Builds a lookup of advisors referenced in the submitted payload to avoid
  # repeated queries when processing many students.
  #
  # @param advisor_values [Array<String>]
  # @return [Hash{Integer=>Advisor}]
  def build_advisor_lookup(advisor_values)
    ids = Array(advisor_values).map { |value| value.to_s.presence&.to_i }.compact
    return {} if ids.blank?

    Advisor.includes(:user).where(advisor_id: ids).index_by(&:advisor_id)
  end

  # Applies a single track update for the provided student, recording success
  # and failure messages and emitting an AdminActivityLog entry on success.
  #
  # @param student [Student]
  # @param new_track_value [String]
  # @param successes [Array<String>]
  # @param failures [Array<String>]
  # @return [void]
  def apply_track_update(student, new_track_value, successes, failures)
    new_track_key = new_track_value.to_s
    student_label = student_display_label(student)

    if new_track_key.blank?
      return if student.track.blank?

      failures << "#{student_label}: track selection is required"
      return
    end

    unless Student.tracks.key?(new_track_key)
      failures << "#{student_label}: invalid track selection"
      return
    end

    return if student.track_key == new_track_key

    previous_track = student.track_key
    previous_label = ProgramTrack.name_for_key(previous_track) || previous_track.to_s.titleize.presence || "Unassigned"
    new_label = new_track_key.titleize

    student.update!(track: new_track_key)
    successes << "#{student_label}: #{previous_label} → #{new_label}"

    AdminActivityLog.record!(
      admin: current_user,
      action: "track_update",
      description: "Track updated for #{student_label}: #{previous_label} → #{new_label}",
      subject: student,
      metadata: {
        previous_track: previous_track,
        new_track: new_track_key
      }
    )
  rescue StandardError => e
    failures << "#{student_label}: #{e.message}"
  end

  def apply_program_year_update(student, new_program_year_value, successes, failures)
    student_label = student_display_label(student)
    normalized_year = new_program_year_value.to_s.strip

    if normalized_year.blank?
      return if student.program_year.blank?

      failures << "#{student_label}: class year selection is required"
      return
    end

    unless ProgramYear.values.map(&:to_i).include?(normalized_year.to_i) && normalized_year.match?(/\A\d+\z/)
      failures << "#{student_label}: invalid class year selection"
      return
    end

    new_program_year = normalized_year.to_i
    current_program_year = student.program_year
    return if current_program_year.to_i == new_program_year

    previous_label = current_program_year.presence || "Unassigned"
    new_label = new_program_year.to_s

    student.update!(program_year: new_program_year)
    successes << "#{student_label}: #{previous_label} → #{new_label}"

    AdminActivityLog.record!(
      admin: current_user,
      action: "program_year_update",
      description: "Class year updated for #{student_label}: #{previous_label} → #{new_label}",
      subject: student,
      metadata: {
        previous_program_year: current_program_year,
        new_program_year: new_program_year
      }
    )
  rescue StandardError => e
    failures << "#{student_label}: #{e.message}"
  end

  # Applies a single advisor update for the provided student, appending
  # descriptive success/failure strings used in the flash message.
  #
  # @param student [Student]
  # @param advisor_value [String]
  # @param advisor_lookup [Hash]
  # @param successes [Array<String>]
  # @param failures [Array<String>]
  # @return [void]
  def apply_advisor_update(student, advisor_value, advisor_lookup, successes, failures)
    normalized_advisor_id = advisor_value.to_s.presence&.to_i
    student_label = student_display_label(student)

    if normalized_advisor_id.present? && advisor_lookup[normalized_advisor_id].nil?
      failures << "#{student_label}: advisor not found"
      return
    end

    current_advisor_id = student.advisor_id
    return if (current_advisor_id || nil) == normalized_advisor_id

    previous_label = student.advisor&.display_name || "Unassigned"
    new_advisor_record = normalized_advisor_id.present? ? advisor_lookup[normalized_advisor_id] : nil
    new_label = new_advisor_record&.display_name || "Unassigned"

    student.advisor_assignment_actor = current_user
    student.update!(advisor_id: normalized_advisor_id)
    successes << "#{student_label}: #{previous_label} → #{new_label}"
  rescue StandardError => e
    failures << "#{student_label}: #{e.message}"
  end

  # Applies a single assignment_group update for the provided student.
  #
  # @param student [Student]
  # @param new_group_value [String]
  # @param successes [Array<String>]
  # @param failures [Array<String>]
  # @return [void]
  def apply_assignment_group_update(student, new_group_value, successes, failures)
    student_label = student_display_label(student)

    new_group = new_group_value.to_s.strip.presence
    current_group = student.respond_to?(:assignment_group) ? student.assignment_group.to_s.strip.presence : nil

    return if current_group == new_group

    previous_label = current_group.presence || "Unassigned"
    new_label = new_group.presence || "Unassigned"

    student.update!(assignment_group: new_group)
    successes << "#{student_label}: #{previous_label} → #{new_label}"
  rescue StandardError => e
    failures << "#{student_label}: #{e.message}"
  end

  def apply_status_update(student, new_status_value, reason, successes, failures)
    student_label = student_display_label(student)
    new_status = new_status_value.to_s.strip.downcase
    return if new_status.blank?

    unless Student::STATUSES.include?(new_status)
      failures << "#{student_label}: invalid lifecycle status"
      return
    end

    current_status = student.status.to_s
    return if current_status == new_status

    previous_label = student.lifecycle_label
    attributes = lifecycle_status_attributes(new_status, reason)
    student.update!(attributes)
    new_label = student.reload.lifecycle_label
    successes << "#{student_label}: #{previous_label} → #{new_label}"

    AdminActivityLog.record!(
      admin: current_user,
      action: "student_lifecycle_update",
      description: "Lifecycle status updated for #{student_label}: #{previous_label} → #{new_label}",
      subject: student,
      metadata: {
        previous_status: current_status,
        new_status: new_status,
        reason: reason
      }.compact
    )
  rescue StandardError => e
    failures << "#{student_label}: #{e.message}"
  end

  def lifecycle_status_attributes(status, reason)
    case status
    when "active"
      {
        status: "active",
        graduated_at: nil,
        archived_at: nil,
        archived_by: nil,
        archive_reason: nil
      }
    when "graduated"
      {
        status: "graduated",
        graduated_at: Time.current,
        archived_at: nil,
        archived_by: nil,
        archive_reason: nil
      }
    when "archived"
      {
        status: "archived",
        graduated_at: nil,
        archived_at: Time.current,
        archived_by: current_user,
        archive_reason: reason
      }
    when "inactive", "withdrawn"
      {
        status: status,
        graduated_at: nil,
        archived_at: nil,
        archived_by: nil,
        archive_reason: nil
      }
    else
      { status: status }
    end
  end

  # Human-friendly identifier for logging/flash messages.
  #
  # @param student [Student]
  # @return [String]
  def student_display_label(student)
    student.user&.name.presence || student.user&.email.presence || "Student ##{student.student_id}"
  end

  def build_assignment_group_select_options
    groups = []

    if SurveyOffering.data_source_ready?
      groups.concat(SurveyOffering.distinct.pluck(:assignment_group))
    end

    if Student.column_names.include?("assignment_group")
      groups.concat(Student.distinct.pluck(:assignment_group))
    end

    groups = groups.compact.map { |value| value.to_s.strip }.reject(&:blank?).uniq.sort

    [ [ "Unassigned", "" ] ] + groups.map { |group| [ group, group ] }
  rescue StandardError
    [ [ "Unassigned", "" ] ]
  end
end
