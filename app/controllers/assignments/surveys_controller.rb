module Assignments
  # Provides admins and advisors with read access to survey definitions and lets
  # them assign/unassign surveys to students.
  class SurveysController < BaseController
    REMINDER_NOTIFICATION_TITLES = [
      "New Competency Survey Assigned",
      "Competency Survey Closing Soon",
      "Competency Survey Closed"
    ].freeze

    helper_method :datetime_local_value

    before_action :set_survey, only: %i[show assign assign_all unassign unassign_selected availability extend_deadline extend_group_deadline reopen]
    before_action :require_admin_for_survey_availability!, only: %i[availability]
    before_action :ensure_survey_active_for_mutation!, only: %i[assign assign_all unassign unassign_selected extend_deadline extend_group_deadline reopen]

    # Lists surveys with their categories and questions.
    def index
      if current_user&.role_admin?
        redirect_to admin_surveys_path(anchor: "active-surveys"),
                    notice: "Survey assignments are now managed from Survey Builder."
        return
      end

      @surveys = Survey.includes(:categories, :questions).order(created_at: :desc)
    end

    # Shows survey metadata and the list of students eligible for assignment.
    def show
      @students = assignable_students

      track_key =
        if @survey.respond_to?(:track) && @survey.track.present?
          ProgramTrack.canonical_key(@survey.track)
        else
          t = @survey.title.to_s.downcase
          t.include?("executive") ? "executive" : (t.include?("residential") ? "residential" : nil)
        end

      if track_key.present? && Student.tracks.key?(track_key)
        @students = @students.where("LOWER(track) = ?", track_key)
      end

      @track_options = ProgramTrack.names
      @year_options = assignable_students.where.not(program_year: nil).distinct.order(:program_year).pluck(:program_year)
      @default_track_label = track_key.present? ? Student.tracks[track_key] : nil

      student_ids = @students.pluck(:student_id)
      @assignments_by_student_id =
        SurveyAssignment
          .where(survey_id: @survey.id, student_id: student_ids)
          .select(:id, :survey_id, :student_id, :assigned_at, :available_from, :available_until, :completed_at)
          .index_by(&:student_id)

      @assigned_student_ids = @assignments_by_student_id.keys.to_set

      answer_counts =
        StudentQuestion
          .joins(question: :category)
          .where(student_id: student_ids, categories: { survey_id: @survey.id })
          .group(:student_id)
          .count
      @answer_counts_by_student_id = answer_counts

      assignment_ids = @assignments_by_student_id.values.map(&:id)
      @last_notified_at_by_assignment_id = if assignment_ids.any?
        Notification
          .where(notifiable_type: "SurveyAssignment", notifiable_id: assignment_ids, title: REMINDER_NOTIFICATION_TITLES)
          .group(:notifiable_id)
          .maximum(:updated_at)
      else
        {}
      end
    end

    def availability
      previous_available_from = @survey.available_from
      previous_available_until = @survey.available_until

      available_from = parsed_survey_datetime(:available_from)
      available_until = parsed_survey_datetime(:available_until)
      return if performed?

      @survey.update!(
        available_from: available_from,
        available_until: available_until
      )
      sync_inherited_availability!(
        previous_available_from: previous_available_from,
        previous_available_until: previous_available_until
      )

      redirect_to assignments_survey_path(@survey), notice: "Survey availability updated. Survey Builder settings now show the same dates."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to assignments_survey_path(@survey), alert: e.record.errors.full_messages.to_sentence
    end

    # Assigns the selected survey to a single student.
    def assign
      student = assignable_students.find_by!(student_id: params[:student_id])

      if params[:available_until].present? && parsed_available_until.present? && !ensure_deadline_not_before_survey!(parsed_available_until)
        return
      end

      changed_assignment = nil
      previous_deadline = nil

      ActiveRecord::Base.transaction do
        @survey.questions.find_each do |question|
          StudentQuestion.find_or_create_by!(student_id: student.student_id, question_id: question.id) do |record|
            record.advisor_id = current_advisor_profile&.advisor_id
          end
        end

        assignment, created, prior_deadline, deadline_changed = upsert_assignment_for(student)
        unless created
          changed_assignment = assignment if deadline_changed
          previous_deadline = prior_deadline
        end
      end

      deliver_assignment_deadline_changed_notification!(changed_assignment, previous_deadline: previous_deadline) if changed_assignment

      redirect_to assignments_surveys_path,
                  notice: "Assigned '#{@survey.title}' to #{student.full_name || student.user.email} at #{timestamp_str}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to assignments_survey_path(@survey), alert: e.record.errors.full_messages.to_sentence
    end

    # Assigns the survey to all eligible students in the survey's track.
    def assign_all
      track_filter = params[:track].presence
      year_filter = params[:program_year].presence
      students = students_for_bulk_action(track_filter:, year_filter:)
      selected_ids = selected_student_ids
      students = students.where(student_id: selected_ids) if selected_ids.present?

      if students.blank?
        redirect_to assignments_survey_path(@survey),
                    alert: "No students available for the selected assignment group."
        return
      end

      if params[:available_until].present? && parsed_available_until.present? && !ensure_deadline_not_before_survey!(parsed_available_until)
        return
      end

      processed_count = 0
      changed_existing_assignments = []

      ActiveRecord::Base.transaction do
        students.find_each do |student|
          @survey.questions.find_each do |question|
            StudentQuestion.find_or_create_by!(student_id: student.student_id, question_id: question.id) do |record|
              record.advisor_id = current_advisor_profile&.advisor_id
            end
          end

          assignment, created, previous_deadline, deadline_changed = upsert_assignment_for(student)
          changed_existing_assignments << [ assignment, previous_deadline ] if !created && deadline_changed
          processed_count += 1
        end
      end

      changed_existing_assignments.each do |assignment, previous_deadline|
        deliver_assignment_deadline_changed_notification!(assignment, previous_deadline: previous_deadline)
      end

      group_label = []
      group_label << (track_filter.present? ? track_filter.to_s.strip : (survey_track_key&.titleize || "selected track"))
      group_label << "Class of #{year_filter}" if year_filter.present?
        redirect_to assignments_survey_path(@survey),
          notice: "Assigned '#{@survey.title}' to #{processed_count} student#{'s' unless processed_count == 1} in #{group_label.compact.join(' • ')} at #{timestamp_str}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to assignments_survey_path(@survey), alert: e.record.errors.full_messages.to_sentence
    end

    # Reopens (unlocks) assignments for selected students by clearing completion.
    def reopen
      track_filter = params[:track].presence
      year_filter = params[:program_year].presence

      students = students_for_bulk_action(track_filter:, year_filter:)
      selected_ids = selected_student_ids
      students = students.where(student_id: selected_ids) if selected_ids.present?

      student_ids = students.pluck(:student_id)
      assignments = SurveyAssignment.where(survey_id: @survey.id, student_id: student_ids)

      if assignments.blank?
        redirect_to assignments_survey_path(@survey),
                    alert: "No assignments matched the selected students for re-opening."
        return
      end

      update_attributes = { completed_at: nil, updated_at: Time.current }
      extension_deadline = parsed_extension_available_until

      if params[:new_available_until].present? && extension_deadline.blank?
        redirect_to assignments_survey_path(@survey),
                    alert: "Please provide a valid extension deadline."
        return
      end

      if extension_deadline.present?
        return unless ensure_deadline_not_before_survey!(extension_deadline)

        update_attributes[:available_until] = extension_deadline
      end

      assignments_to_reopen = assignments.includes(student: :user).to_a
      reopened_count = assignments.update_all(update_attributes)

      if reopened_count.zero?
        redirect_to assignments_survey_path(@survey),
                    alert: "No assignments were re-opened for the selected students."
        return
      end

      group_label = []
      group_label << (track_filter.present? ? track_filter.to_s.strip : (survey_track_key&.titleize || "selected track"))
      group_label << "Class of #{year_filter}" if year_filter.present?

      assignments_to_reopen.each do |assignment|
        assignment.completed_at = nil
        assignment.available_until = extension_deadline if extension_deadline.present?
        deliver_assignment_reopened_notification!(assignment)
      end

      redirect_to assignments_survey_path(@survey),
                  notice: "Re-opened '#{@survey.title}' for #{reopened_count} student#{'s' unless reopened_count == 1} in #{group_label.compact.join(' • ')}."
    end

    # Unassigns the survey from a single student.
    def unassign
      student = assignable_students.find_by!(student_id: params[:student_id])

      assignment = SurveyAssignment.find_by(survey_id: @survey.id, student_id: student.student_id)
      if assignment&.completed_at?
        redirect_to assignments_survey_path(@survey),
                    alert: "Cannot unassign a completed survey for #{student.full_name || student.user.email}."
        return
      end

      scope = StudentQuestion.where(
        student_id: student.student_id,
        question_id: @survey.questions.select(:id)
      )
      has_responses = scope.exists?

      if assignment.present? || has_responses
        ActiveRecord::Base.transaction do
          scope.delete_all if has_responses
          assignment&.destroy!
          deliver_assignment_unassigned_notification!(student)
        end
        redirect_to assignments_survey_path(@survey),
                    notice: "Unassigned '#{@survey.title}' from #{student.full_name || student.user.email} at #{timestamp_str}."
      else
        redirect_to assignments_survey_path(@survey), alert: "No assignment found for that student."
      end
    end

    # Unassigns the survey for selected students in bulk.
    def unassign_selected
      track_filter = params[:track].presence
      year_filter = params[:program_year].presence
      students = students_for_bulk_action(track_filter:, year_filter:)
      selected_ids = selected_student_ids
      students = students.where(student_id: selected_ids) if selected_ids.present?

      student_ids = students.pluck(:student_id)
      assignments = SurveyAssignment.where(survey_id: @survey.id, student_id: student_ids)
      completed_student_ids = assignments.where.not(completed_at: nil).pluck(:student_id)
      removable_assignments = assignments.where(completed_at: nil)

      if removable_assignments.blank?
        redirect_to assignments_survey_path(@survey),
                    alert: "No incomplete assignments matched the selected students for unassignment."
        return
      end

      removable_student_ids = removable_assignments.pluck(:student_id)
      student_records_by_id = students.where(student_id: removable_student_ids).includes(:user).index_by(&:student_id)

      removed_count = 0

      ActiveRecord::Base.transaction do
        StudentQuestion.where(student_id: removable_student_ids, question_id: @survey.questions.select(:id)).delete_all

        removable_assignments.find_each do |assignment|
          assignment.destroy!
          student = student_records_by_id[assignment.student_id]
          deliver_assignment_unassigned_notification!(student) if student&.user.present?
          removed_count += 1
        end
      end

      if removed_count.zero?
        redirect_to assignments_survey_path(@survey),
                    alert: "No assignments were unassigned for the selected students."
        return
      end

      skipped_count = completed_student_ids.uniq.count
      notice = "Unassigned '#{@survey.title}' from #{removed_count} student#{'s' unless removed_count == 1} at #{timestamp_str}."
      notice += " Skipped #{skipped_count} completed assignment#{'s' unless skipped_count == 1}." if skipped_count.positive?

      redirect_to assignments_survey_path(@survey), notice: notice
    end

    # Extends the deadline for one assigned student.
    def extend_deadline
      student = assignable_students.find_by!(student_id: params[:student_id])
      assignment = SurveyAssignment.find_by(survey_id: @survey.id, student_id: student.student_id)

      if assignment.nil?
        redirect_to assignments_survey_path(@survey), alert: "No assignment found for that student."
        return
      end

      if assignment.completed_at?
        redirect_to assignments_survey_path(@survey),
                    alert: "Cannot change deadline for a completed survey for #{student.full_name || student.user.email}."
        return
      end

      extension_deadline = parsed_extension_available_until
      if extension_deadline.nil?
        redirect_to assignments_survey_path(@survey),
                    alert: "Please provide a valid deadline to change this assignment."
        return
      end

      return unless ensure_deadline_not_before_survey!(extension_deadline)

      previous_deadline = assignment.available_until
      assignment.update!(available_until: extension_deadline)
      deliver_assignment_deadline_changed_notification!(assignment, previous_deadline: previous_deadline)
      redirect_to assignments_survey_path(@survey),
                  notice: "Changed '#{@survey.title}' deadline for #{student.full_name || student.user.email} to #{format_timestamp(extension_deadline)}."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to assignments_survey_path(@survey), alert: e.record.errors.full_messages.to_sentence
    end

    # Extends deadlines for a selected student group.
    def extend_group_deadline
      raw_deadline = params[:new_available_until].to_s.strip
      extension_deadline = raw_deadline.present? ? parsed_extension_available_until : @survey.available_until

      if raw_deadline.present? && extension_deadline.nil?
        redirect_to assignments_survey_path(@survey),
                    alert: "Please provide a valid group deadline to apply the change."
        return
      end

      if raw_deadline.present? && extension_deadline.present? && !ensure_deadline_not_before_survey!(extension_deadline)
        return
      end

      track_filter = params[:track].presence
      year_filter = params[:program_year].presence
      students = students_for_bulk_action(track_filter:, year_filter:)
      selected_ids = selected_student_ids
      students = students.where(student_id: selected_ids) if selected_ids.present?
      if students.blank?
        redirect_to assignments_survey_path(@survey),
                    alert: "No assignments matched the selected group for deadline change."
        return
      end

      processed_count = 0
      changed_existing_assignments = []

      ActiveRecord::Base.transaction do
        students.find_each do |student|
          @survey.questions.find_each do |question|
            StudentQuestion.find_or_create_by!(student_id: student.student_id, question_id: question.id) do |record|
              record.advisor_id = current_advisor_profile&.advisor_id
            end
          end

          assignment = SurveyAssignment.find_or_initialize_by(survey_id: @survey.id, student_id: student.student_id)
          created = assignment.new_record?
          previous_deadline = assignment.available_until
          assignment.manual = true if assignment.respond_to?(:manual=)
          assignment.advisor_id ||= current_advisor_profile&.advisor_id
          assignment.assigned_at ||= Time.current
          assignment.available_from ||= @survey.available_from
          assignment.available_until = extension_deadline
          assignment.save! if assignment.new_record? || assignment.changed?
          changed_existing_assignments << [ assignment, previous_deadline ] if !created && previous_deadline != extension_deadline

          processed_count += 1
        end
      end

      changed_existing_assignments.each do |assignment, previous_deadline|
        deliver_assignment_deadline_changed_notification!(assignment, previous_deadline: previous_deadline)
      end

      group_label = []
      group_label << (track_filter.present? ? track_filter.to_s.strip : (survey_track_key&.titleize || "selected track"))
      group_label << "Class of #{year_filter}" if year_filter.present?
      deadline_label = extension_deadline.present? ? format_timestamp(extension_deadline) : "No deadline"
      redirect_to assignments_survey_path(@survey),
          notice: "Changed '#{@survey.title}' deadline for #{processed_count} student#{'s' unless processed_count == 1} in #{group_label.compact.join(' • ')} to #{deadline_label}."
    end

    private

    def set_survey
      @survey = Survey.find(params[:id])
      @survey_number = @survey.id
    end

    def assignable_students
      if current_user.role_admin?
        Student.includes(:user)
      else
        (current_advisor_profile&.advisees || Student.none).includes(:user)
      end
    end

    def eligible_students_for_track
      scope = assignable_students
      key = survey_track_key
      return scope.none unless key.present? && Student.tracks.key?(key)

      scope.where("LOWER(track) = ?", key)
    end

    def students_for_bulk_action(track_filter:, year_filter:)
      students = assignable_students

      if track_filter.present?
        canonical = ProgramTrack.canonical_key(track_filter)
        students = students.where("LOWER(track) = ?", canonical) if canonical.present?
      end

      if year_filter.present?
        students = students.where(program_year: year_filter.to_i)
      end

      if track_filter.blank? && year_filter.blank?
        key = survey_track_key
        return students.where("LOWER(track) = ?", key) if key.present? && Student.tracks.key?(key)

        return students
      end

      students
    end

    def survey_track_key
      @survey_track_key ||= begin
        if @survey.respond_to?(:track) && @survey.track.present?
          ProgramTrack.canonical_key(@survey.track)
        else
          t = @survey.title.to_s.downcase
          t.include?("executive") ? "executive" : (t.include?("residential") ? "residential" : nil)
        end
      end
    end

    # Ensures a SurveyAssignment exists for the student/survey pair.
    #
    # @param student [Student]
    # @return [Array<(SurveyAssignment, Boolean, Time, Boolean)>] record, creation flag, previous deadline, and deadline-change flag
    def upsert_assignment_for(student)
      assignment = SurveyAssignment.find_or_initialize_by(
        survey_id: @survey.id,
        student_id: student.student_id
      )

      created = assignment.new_record?
      previous_deadline = assignment.available_until
      assignment.manual = true if assignment.respond_to?(:manual=)
      assignment.advisor_id ||= current_advisor_profile&.advisor_id
      assignment.assigned_at ||= Time.current

      default_available_from = @survey.available_from
      default_available_until = @survey.available_until

      if SurveyOffering.data_source_ready? && student.track.present? && student.program_year.present?
        offerings = SurveyOffering.for_student(track_key: student.track_key, class_of: student.program_year)
                                 .where(survey_id: @survey.id)
        if offerings.exists?
          exact = offerings.find { |row| row.class_of.present? && row.class_of.to_i == student.program_year.to_i }
          offering = exact || offerings.first
          default_available_from = offering.available_from if offering.available_from.present?
          default_available_until = offering.available_until if offering.available_until.present?
        end
      end

      assignment.available_from ||= default_available_from
      assignment.available_until ||= default_available_until

      if (available_from = parsed_available_from)
        assignment.available_from = available_from
      end

      if (available_until = parsed_available_until)
        assignment.available_until = available_until
      end

      assignment.completed_at = nil if created
      assignment.save! if assignment.new_record? || assignment.changed?

      [ assignment, created, previous_deadline, !created && previous_deadline != assignment.available_until ]
    end

    def deliver_assignment_unassigned_notification!(student)
      return unless student&.user

      Notification.deliver!(
        user: student.user,
        title: "Survey Unassigned",
        message: "The survey '#{@survey.title}' was removed from your assignments.",
        notifiable: @survey,
        event_key: "survey.unassigned",
        dedupe_key: "survey.unassigned:survey:#{@survey.id}:student:#{student.student_id}",
        metadata: {
          survey_id: @survey.id,
          student_id: student.student_id
        }
      )
    end

    def deliver_assignment_deadline_changed_notification!(assignment, previous_deadline:)
      user = assignment.recipient_user
      return unless user

      Notification.deliver!(
        user: user,
        title: "Survey Deadline Changed",
        message: deadline_changed_message(assignment),
        notifiable: assignment,
        event_key: "survey.deadline_changed",
        dedupe_key: "survey.deadline_changed:survey_assignment:#{assignment.id}",
        metadata: {
          survey_assignment_id: assignment.id,
          survey_id: assignment.survey_id,
          student_id: assignment.student_id,
          previous_available_until: previous_deadline&.iso8601,
          available_until: assignment.available_until&.iso8601
        }
      )
    end

    def deliver_assignment_reopened_notification!(assignment)
      user = assignment.recipient_user
      return unless user

      Notification.deliver!(
        user: user,
        title: "Competency Survey Reopened",
        message: reopened_assignment_message(assignment),
        notifiable: assignment,
        event_key: "survey.reopened",
        dedupe_key: "survey.reopened:survey_assignment:#{assignment.id}",
        metadata: {
          survey_assignment_id: assignment.id,
          survey_id: assignment.survey_id,
          student_id: assignment.student_id,
          available_until: assignment.available_until&.iso8601
        }
      )
    end

    def deadline_changed_message(assignment)
      deadline = assignment.available_until
      if deadline.present?
        "The deadline for '#{assignment.survey.title}' changed to #{format_timestamp(deadline)}."
      else
        "The deadline for '#{assignment.survey.title}' was removed."
      end
    end

    def reopened_assignment_message(assignment)
      deadline = assignment.available_until
      if deadline.present?
        "The competency survey '#{assignment.survey.title}' was reopened. You can edit and resubmit until #{format_timestamp(deadline)}."
      else
        "The competency survey '#{assignment.survey.title}' was reopened. You can edit and resubmit while it is available."
      end
    end

    def parsed_available_from
      return @parsed_available_from if instance_variable_defined?(:@parsed_available_from)

      raw_value = params[:available_from].presence
      @parsed_available_from = begin
        raw_value ? Time.zone.parse(raw_value) : nil
      rescue ArgumentError
        nil
      end
    end

    def parsed_available_until
      return @parsed_available_until if instance_variable_defined?(:@parsed_available_until)

      raw_value = params[:available_until].presence
      @parsed_available_until = begin
        raw_value ? Time.zone.parse(raw_value) : nil
      rescue ArgumentError
        nil
      end
    end

    def parsed_extension_available_until
      return @parsed_extension_available_until if instance_variable_defined?(:@parsed_extension_available_until)

      raw_value = params[:new_available_until].presence
      @parsed_extension_available_until = begin
        raw_value ? Time.zone.parse(raw_value) : nil
      rescue ArgumentError
        nil
      end
    end

    def selected_student_ids
      raw_values = Array(params[:student_ids]).flatten
      values = raw_values.flat_map { |item| item.to_s.split(",") }
      values.map { |value| value.to_s.strip }.reject(&:blank?).uniq
    end

    def datetime_local_value(value)
      return if value.blank?

      value.in_time_zone.strftime("%Y-%m-%dT%H:%M")
    end

    def format_timestamp(value)
      I18n.l(value, format: :long)
    rescue I18n::MissingTranslationData, I18n::InvalidLocale
      value.to_fs(:long)
    end

    def timestamp_str
      I18n.l(Time.current, format: :long)
    rescue I18n::MissingTranslationData, I18n::InvalidLocale
      Time.current.to_fs(:long)
    end

    def parsed_survey_datetime(attribute)
      raw_value = params.dig(:survey, attribute).to_s.strip
      return nil if raw_value.blank?

      Time.zone.parse(raw_value)
    rescue ArgumentError
      redirect_to assignments_survey_path(@survey), alert: "Please provide a valid #{attribute.to_s.humanize.downcase}."
      nil
    end

    def sync_inherited_availability!(previous_available_from:, previous_available_until:)
      all_assignments_scope = SurveyAssignment.where(survey_id: @survey.id)

      sync_inherited_assignment_column!(
        scope: all_assignments_scope,
        column: :available_from,
        previous_value: previous_available_from,
        new_value: @survey.available_from
      ) if previous_available_from != @survey.available_from

      sync_inherited_assignment_column!(
        scope: all_assignments_scope,
        column: :available_until,
        previous_value: previous_available_until,
        new_value: @survey.available_until
      ) if previous_available_until != @survey.available_until

      return unless SurveyOffering.data_source_ready? && SurveyOffering.where(survey_id: @survey.id).exists?

      updates = {
        available_from: @survey.available_from,
        available_until: @survey.available_until,
        updated_at: Time.current
      }
      updates[:portfolio_due_date] = @survey.available_until if SurveyOffering.column_names.include?("portfolio_due_date")

      SurveyOffering.where(survey_id: @survey.id).update_all(updates)
    end

    def sync_inherited_assignment_column!(scope:, column:, previous_value:, new_value:)
      assignments = SurveyAssignment.arel_table
      assignment_column = assignments[column]

      inherited_scope = if previous_value.nil?
        scope.where(column => nil)
      else
        scope.where(
          assignment_column.eq(previous_value).or(
            Arel::Nodes::NamedFunction.new("DATE", [ assignment_column ]).eq(previous_value.to_date)
          )
        )
      end

      inherited_scope.update_all(column => new_value, updated_at: Time.current)
    end

    def require_admin_for_survey_availability!
      return if current_user&.role_admin?

      redirect_to assignments_survey_path(@survey), alert: "Only admins can change survey availability settings."
    end

    def ensure_survey_active_for_mutation!
      return if @survey.is_active?

      redirect_to assignments_survey_path(@survey),
                  alert: "This survey is archived and cannot be modified."
    end

    def ensure_deadline_not_before_survey!(deadline)
      return true if deadline.blank? || @survey.available_until.blank?
      return true if deadline >= @survey.available_until

      redirect_to assignments_survey_path(@survey),
                  alert: "Student due date cannot be earlier than the survey due date."
      false
    end
  end
end
