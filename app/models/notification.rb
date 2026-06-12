# Polymorphic notifications delivered to end users.
class Notification < ApplicationRecord
  include Rails.application.routes.url_helpers

  belongs_to :user
  belongs_to :notifiable, polymorphic: true, optional: true

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(updated_at: :desc, created_at: :desc) }

  validates :title, presence: true
  validates :message, presence: true
  validates :dedupe_key, uniqueness: { scope: :user_id }, allow_blank: true
  validates :user_id, uniqueness: { scope: %i[title notifiable_type notifiable_id] }, unless: -> { dedupe_key.present? }

  # Creates or reuses an existing notification matching the stable dedupe key
  # when provided. Older/simple callers fall back to title + notifiable dedupe.
  #
  # @param user [User]
  # @param title [String]
  # @param message [String]
  # @param notifiable [ApplicationRecord, nil]
  # @param event_key [String, Symbol, nil]
  # @param dedupe_key [String, nil]
  # @param metadata [Hash]
  # @return [Notification, nil]
  def self.deliver!(user:, title:, message:, notifiable: nil, event_key: nil, dedupe_key: nil, metadata: {})
    return unless user

    normalized_dedupe_key = dedupe_key.presence
    relation = if normalized_dedupe_key
      where(user: user, dedupe_key: normalized_dedupe_key)
    else
      fallback_dedupe_relation(user:, title:, notifiable:)
    end

    record = relation.first_or_initialize
    record.title = title
    record.message = message
    record.notifiable = notifiable
    record.event_key = event_key.to_s if record.respond_to?(:event_key=) && event_key.present?
    record.dedupe_key = normalized_dedupe_key if record.respond_to?(:dedupe_key=)
    record.metadata = normalized_metadata(metadata) if record.respond_to?(:metadata=)
    record.read_at = user_in_app_notifications_enabled?(user) ? nil : Time.current
    record.created_at = Time.current if record.persisted?
    record.save!
    record
  end

  def self.fallback_dedupe_relation(user:, title:, notifiable:)
    relation = where(user: user, title: title)
    if notifiable
      relation.where(notifiable: notifiable)
    else
      relation.where(notifiable_type: nil, notifiable_id: nil)
    end
  end
  private_class_method :fallback_dedupe_relation

  def self.normalized_metadata(metadata)
    return {} if metadata.blank?

    metadata.respond_to?(:to_h) ? metadata.to_h : {}
  end
  private_class_method :normalized_metadata

  # Marks the notification as read by setting the timestamp.
  #
  # @return [Boolean]
  def mark_read!
    update!(read_at: Time.current)
  end

  # @return [Boolean] true when read_at contains a timestamp
  def read?
    read_at.present?
  end

  def self.user_in_app_notifications_enabled?(user)
    return true unless user.respond_to?(:in_app_notifications_enabled?)

    user.in_app_notifications_enabled?
  end

  # Returns clear, recipient-facing copy for display surfaces.
  #
  # Older notifications may include staff names or raw change-log text. Keep the
  # stored message intact, but normalize the wording wherever users read it.
  #
  # @return [String]
  def display_message
    case title
    when "New Competency Survey Assigned"
      assigned_display_message
    when "Survey Unassigned"
      unassigned_display_message
    when "Competency Survey Updated"
      survey_updated_display_message
    else
      message
    end
  end

  # Computes a reasonable path for the notification recipient to visit.
  #
  # @param viewer [User, nil]
  # @return [String, nil]
  def target_path_for(viewer = nil)
    return unless notifiable

    case notifiable
    when Survey
      resolve_survey_path(notifiable, viewer)
    when SurveyAssignment
      resolve_assignment_path(notifiable, viewer)
    when Question
      question_path(notifiable)
    when Feedback
      feedback_path(notifiable)
    when ProgramSemester
      resolve_program_semester_path(viewer)
    when GradeImportBatch
      resolve_grade_import_batch_path(notifiable, viewer)
    else
      nil
    end
  end

  private

  def assigned_display_message
    survey_title = display_survey_title
    return "You were assigned a competency survey." if survey_title.blank?

    "You were assigned the competency survey '#{survey_title}'."
  end

  def unassigned_display_message
    survey_title = display_survey_title
    return "A survey was removed from your assignments." if survey_title.blank?

    "The survey '#{survey_title}' was removed from your assignments."
  end

  def survey_updated_display_message
    survey_title = display_survey_title
    prefix = if survey_title.present?
      "The competency survey '#{survey_title}' was updated."
    else
      "A competency survey was updated."
    end

    summary = normalized_survey_update_summary
    [ prefix, summary ].compact_blank.join(" ")
  end

  def display_survey_title
    case notifiable
    when Survey
      notifiable.title
    when SurveyAssignment
      notifiable.survey&.title
    else
      quoted_survey_title_from_message
    end
  end

  def quoted_survey_title_from_message
    message.to_s[/competency survey '([^']+)'/i, 1] ||
      message.to_s[/survey '([^']+)'/i, 1] ||
      message.to_s[/removed '([^']+)' from your assignments/i, 1]
  end

  def normalized_survey_update_summary
    raw_summary = message.to_s
      .sub(/\AThe competency survey '[^']+' (?:has been|was) updated\.\s*/i, "")
      .strip

    return nil if raw_summary.blank?

    normalized = raw_summary.split(";").filter_map do |segment|
      normalize_update_segment(segment.strip)
    end

    normalized.join(" ").presence
  end

  def normalize_update_segment(segment)
    return if segment.blank?

    return "No question or structure changes were detected." if segment.match?(/\ANo structural changes detected\z/i)

    if (match = segment.match(/\A(.+?) changed from '([^']*)' to '([^']*)'\z/i))
      attribute = match[1].to_s.strip.downcase
      before_value = display_change_value(attribute, match[2])
      after_value = display_change_value(attribute, match[3])
      return "#{friendly_change_label(attribute)} changed from #{before_value} to #{after_value}."
    end

    segment.end_with?(".") ? segment : "#{segment}."
  end

  def friendly_change_label(attribute)
    {
      "available from" => "Open date",
      "available until" => "Due date",
      "is active" => "Status"
    }.fetch(attribute, attribute.humanize)
  end

  def display_change_value(attribute, value)
    return "not set" if value.nil? || (value.respond_to?(:empty?) && value.empty?)

    case attribute
    when "available from", "available until"
      parsed_time = Time.zone.parse(value.to_s)
      parsed_time ? parsed_time.to_fs(:long) : value
    when "is active"
      ActiveModel::Type::Boolean.new.cast(value) ? "active" : "archived"
    else
      value
    end
  rescue ArgumentError
    value
  end

  def default_url_options
    Rails.application.config.action_controller.default_url_options || {}
  end

  def resolve_assignment_path(assignment, viewer)
    return student_assignment_target_path(assignment) unless viewer

    case viewer.role
    when "advisor"
      assignments_survey_path(assignment.survey_id)
    when "admin"
      assignments_survey_path(assignment.survey_id)
    else
      student_assignment_target_path(assignment)
    end
  end

  def resolve_survey_path(survey, viewer)
    return unless viewer

    case viewer.role
    when "advisor"
      assignments_survey_path(survey)
    when "admin"
      assignments_survey_path(survey)
    else
      student = viewer.student_profile
      assignment = student && SurveyAssignment.find_by(student_id: student.student_id, survey_id: survey.id)
      return unless assignment

      student_assignment_target_path(assignment)
    end
  end

  def student_assignment_target_path(assignment)
    return survey_response_path_for_assignment(assignment) if assignment.completed_at?
    return unless assignment.survey&.is_active?
    return unless assignment.available_now?

    survey_path(assignment.survey_id)
  end

  def resolve_program_semester_path(viewer)
    return reports_path unless viewer

    case viewer.role
    when "student"
      student_competencies_path
    else
      reports_path
    end
  end

  def resolve_grade_import_batch_path(batch, viewer)
    return unless viewer

    case viewer.role
    when "advisor"
      reports_path(report_tab: "course_target", course_program_semester_id: batch.program_semester_id)
    when "admin"
      admin_grade_import_batch_path(batch)
    else
      nil
    end
  end

  def survey_response_path_for_assignment(assignment)
    return unless assignment.completed_at?

    student = assignment.student
    survey = assignment.survey
    return unless student && survey

    survey_response = SurveyResponse.build(student: student, survey: survey)
    survey_response_path(survey_response)
  end
end
