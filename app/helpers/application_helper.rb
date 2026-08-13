# Helpers shared across views for formatting flash messages, buttons, and audit
# metadata.
module ApplicationHelper
  include MarkdownHelper
  include GuidanceTextHelper
  include CompetencyTargetLevelsHelper

  APP_SHORT_NAME = "TAMU CAT".freeze
  APP_FULL_NAME = "TAMU Competency Assessment Tracking".freeze
  APP_LEGACY_NAME = "TAMU Competency Assessment Tool".freeze
  APP_ICON_ASSET = "TAMU_CAT_icon.png".freeze
  TAMU_ICON_ASSET = "tamu-logo.png".freeze

  # Base CSS class applied to all flash notifications.
  FLASH_BASE_CLASSES = "flash".freeze
  # Query string keys that should be preserved when building sortable headers.
  SURVEY_SORTABLE_KEYS = %w[q track semester].freeze

  def app_short_name
    APP_SHORT_NAME
  end

  def app_full_name
    APP_FULL_NAME
  end

  def app_icon_asset
    APP_ICON_ASSET
  end

  def tamu_icon_asset
    TAMU_ICON_ASSET
  end

  def browser_title(page_title = nil)
    title = page_title.to_s.strip
    return app_short_name if title.blank?

    compact_title = title
      .gsub(APP_FULL_NAME, app_short_name)
      .gsub(APP_LEGACY_NAME, app_short_name)

    compact_title.include?(app_short_name) ? compact_title : "#{compact_title} | #{app_short_name}"
  end

  # Computes alert styling classes based on the flash key.
  #
  # @param key [Symbol, String]
  # @return [String]
  def flash_classes(key)
    tone = key.to_sym

    case tone
    when :notice, :info
      "#{FLASH_BASE_CLASSES} flash__notice"
    when :success
      "#{FLASH_BASE_CLASSES} flash__success"
    when :alert, :error
      "#{FLASH_BASE_CLASSES} flash__alert"
    when :warning
      "#{FLASH_BASE_CLASSES} flash__warning"
    else
      FLASH_BASE_CLASSES
    end
  end

  # Provides a human-friendly heading for a flash message key.
  #
  # @param key [Symbol, String]
  # @return [String]
  def flash_title(key)
    {
      notice: "Heads Up",
      info: "Heads Up",
      success: "Success",
      alert: "Needs Attention",
      error: "Something Went Wrong",
      warning: "Review Before Continuing"
    }.fetch(key.to_sym, key.to_s.titleize)
  end

  def ferpa_export_confirmation(record_description = "student-level education records")
    "FERPA reminder: This download may include #{record_description}. Download only when you have a legitimate educational interest, and store or share the file securely. Continue?"
  end

  def ferpa_export_notice(record_description = "student-level education records")
    "FERPA reminder: #{record_description} may include identifiable education records. Export only for legitimate educational or program review use, then store and share it securely."
  end

  # Renders question text in plain or rich format based on question config.
  # Rich prompts are sanitized to a strict set of inline tags.
  #
  # @param question [Question]
  # @return [ActiveSupport::SafeBuffer]
  def render_question_prompt(question)
    raw = question&.question_text.to_s
    return h(raw) unless question.respond_to?(:rich_text_prompt?) && question.rich_text_prompt?

    render_markdown_inline(raw)
  end

  # Emits a stylesheet tag for Tailwind, with a fallback if the asset pipeline
  # is unavailable (e.g., during development).
  #
  # @return [String, nil]
  def tailwind_stylesheet_tag
    stylesheet_link_tag("tailwind", "data-turbo-track": "reload")
  rescue StandardError => e
    if (asset = Rails.application.assets&.load_path&.find("tailwind.css"))
      prefix = Rails.application.config.assets.prefix.presence || "/assets"
      href = File.join(prefix, asset.digested_path)

      return tag.link(rel: "stylesheet", href:, "data-turbo-track": "reload")
    end

    Rails.logger.warn("tailwind.css could not be loaded: #{e.message}")
    nil
  end

  # Emits links for the consolidated app stylesheets, with resilient fallback
  # resolution for environments where logical asset lookup may intermittently fail.
  #
  # @return [String, nil]
  def consolidated_stylesheet_tags
    stylesheet_link_tag("application", "accessibility", "data-turbo-track": "reload")
  rescue StandardError => e
    names = %w[application.css accessibility.css]
    tags = names.filter_map { |name| stylesheet_fallback_tag(name) }

    Rails.logger.warn("consolidated stylesheets fallback used: #{e.class}: #{e.message}")

    return safe_join(tags, "\n") if tags.any?

    nil
  end

  private def stylesheet_fallback_tag(name)
    prefix = Rails.application.config.assets.prefix.presence || "/assets"
    candidates = [ name, "stylesheets/#{name}", "builds/#{name}" ]

    asset = candidates.lazy.map { |path| Rails.application.assets&.load_path&.find(path) }.find(&:present?)

    href = if asset&.respond_to?(:digested_path)
      File.join(prefix, asset.digested_path)
    else
      File.join(prefix, name)
    end

    tag.link(rel: "stylesheet", href:, "data-turbo-track": "reload")
  rescue StandardError
    nil
  end

  # Builds application button classes for the provided variant.
  #
  # @param variant [Symbol]
  # @param extra_classes [String]
  # @return [String]
  def button_classes(variant = :primary, extra_classes: "")
    base = "btn"

    variant_class = case variant.to_sym
    when :primary
      "btn-primary"
    when :secondary
      "btn-secondary"
    when :ghost
      "btn-ghost"
    when :subtle
      "btn-subtle"
    when :danger
      "btn-danger"
    when :success
      "btn-success"
    when :warning
      "btn-warning"
    else
      "btn-secondary"
    end

    [ base, variant_class, extra_classes.presence ].compact.join(" ")
  end

  # Backward-compatible alias for older views/helpers.
  def tailwind_button_classes(...)
    button_classes(...)
  end

  # Returns CSS classes for a survey status pill.
  #
  # @param status [String, Symbol]
  # @return [String]
  def survey_status_badge_classes(status)
    status_badge_classes(status)
  end

  # Returns CSS classes for feedback status badge.
  #
  # @param status [String, Symbol]
  # @return [String]
  def feedback_status_badge_classes(status)
    status_badge_classes(status)
  end

  # Returns app-wide status badge classes.
  #
  # @param status [String, Symbol]
  # @param extra_classes [String, nil]
  # @return [String]
  def status_badge_classes(status, extra_classes: nil)
    classes = [ "c-status-badge", "c-status-badge--#{badge_tone(status)}" ]
    classes << extra_classes if extra_classes.present?
    classes.join(" ")
  end

  # Renders an app-wide status badge.
  #
  # @param label [String]
  # @param value [String, Symbol, nil] optional tone source when the label differs from the status value
  # @param html_options [Hash]
  # @return [String]
  def status_badge(label, value: nil, **html_options)
    classes = status_badge_classes(value.presence || label, extra_classes: html_options.delete(:class))
    content_tag(:span, label, html_options.merge(class: classes))
  end

  # Returns lifecycle label for a survey in student-record contexts.
  #
  # @param survey [Survey]
  # @param rows [Array<Hash>] survey rows from StudentRecordsController
  # @return [String]
  def survey_lifecycle_label(survey, rows)
    return "Archived" unless survey&.is_active?

    row_list = Array(rows)
    return "Active" if row_list.blank?

    has_open_assignment = row_list.any? do |row|
      deadline = row[:available_until]
      deadline.blank? || deadline >= Time.current
    end

    has_open_assignment ? "Active" : "Closed"
  end

  # Returns CSS classes for survey lifecycle badge.
  #
  # @param label [String]
  # @return [String]
  def survey_lifecycle_badge_classes(label)
    status_badge_classes(label)
  end

  # Returns a human-friendly availability label for survey summaries.
  #
  # @param available_until [Time, Date, nil]
  # @return [String]
  def survey_availability_note(available_until)
    return "No deadline" if available_until.blank?

    date = available_until.to_date
    "Closes #{date.strftime('%B')} #{date.day}, #{date.year}"
  end

  # Formats a date like "January 9, 2026" (no leading zero).
  #
  # @param value [Time, Date]
  # @return [String]
  def format_calendar_date(value)
    date = value.to_date
    "#{date.strftime('%B')} #{date.day}, #{date.year}"
  end

  # Returns a human-friendly review meeting date/range for a survey offering.
  #
  # @param offering [SurveyOffering, nil]
  # @return [String, nil]
  def review_meetings_note(offering)
    return if offering.blank?

    start_date = offering.review_meetings_start
    end_date = offering.review_meetings_end
    return if start_date.blank? && end_date.blank?

    if start_date.present? && end_date.present?
      start_label = format_calendar_date(start_date)
      end_label = format_calendar_date(end_date)
      return start_label if start_label == end_label

      "#{start_label} – #{end_label}"
    elsif start_date.present?
      format_calendar_date(start_date)
    else
      format_calendar_date(end_date)
    end
  end

  # Generates a concise summary string from survey audit metadata.
  #
  # @param metadata [Hash]
  # @return [String]
  def summarize_survey_audit_metadata(metadata)
    data = metadata.with_indifferent_access
    fragments = []

    fragments << data[:note].to_s if data[:note].present?

    if data[:attributes].is_a?(Hash)
      data[:attributes].each do |attribute, change|
        change = change.with_indifferent_access
        before = humanize_audit_value(change[:before])
        after = humanize_audit_value(change[:after])
        next if before == after

        fragments << "#{attribute.to_s.titleize}: #{before} -> #{after}"
      end
    end

    if data[:associations].is_a?(Hash)
      data[:associations].each do |name, change|
        change = change.with_indifferent_access
        before = humanize_audit_list(change[:before])
        after = humanize_audit_list(change[:after])
        next if before == after

        fragments << "#{name.to_s.titleize}: #{before} -> #{after}"
      end
    end

    fragments = fragments.compact
    fragments = [ "No recorded changes" ] if fragments.empty?
    fragments.first(3).join(" | ")
  end

  # Renders a sortable column header link, preserving existing filters.
  #
  # @param label [String]
  # @param column [String]
  # @return [String]
  def sortable_header(label, column)
    active = @sort_column == column
    next_direction = active && @sort_direction == "asc" ? "desc" : "asc"

    preserved_query = request.query_parameters.slice(*SURVEY_SORTABLE_KEYS)
    target_params = preserved_query.merge("sort" => column, "direction" => next_direction)

    classes = [
      "inline-flex items-center gap-1 text-xs font-semibold uppercase tracking-wide text-slate-500 transition hover:text-slate-700"
    ]
    classes << "text-indigo-600" if active

    indicator = if active
      content_tag(:span, "(#{@sort_direction})", class: "text-[0.65rem] font-medium text-indigo-600")
    end
    label_content = indicator ? safe_join([ label, indicator ], " ") : label

    link_to label_content, admin_surveys_path(target_params), class: classes.join(" ")
  end

  # Supplies an accessible label for avatar placeholders and profile images.
  #
  # @param user [Object, nil]
  # @return [String]
  def avatar_aria_label(user)
    return "User avatar" if user.blank?

    name = user.respond_to?(:full_name) ? user.full_name.to_s.strip : ""
    name.present? ? "Profile picture for #{name}" : "User avatar"
  end

  private

  # Builds a unified badge class string.
  # The badge text itself remains the caller-provided input.
  #
  # @param value [String, Symbol]
  # @return [String]
  def unified_badge_classes(value)
    status_badge_classes(value)
  end

  # Resolves one of three badge tones from a free-form label.
  #
  # @param value [String, Symbol]
  # @return [Symbol]
  def badge_tone(value)
    text = value.to_s.downcase.squish

    return :success if text.in?([ "completed", "submitted", "active" ])
    return :warning if text.in?([ "assigned", "draft", "closed", "late", "overdue", "in progress" ])
    return :danger if text.in?([ "unassigned" ])

    :neutral
  end

  # Humanizes single audit attribute values for display.
  #
  # @param value [Object]
  # @return [String]
  def humanize_audit_value(value)
    return "none" if value.nil?
    return humanize_audit_list(value) if value.is_a?(Array)

    string = value.to_s.strip
    string.present? ? string : "none"
  end

  # Humanizes audit value arrays into comma-separated strings.
  #
  # @param values [Array]
  # @return [String]
  def humanize_audit_list(values)
    items = Array(values).map { |item| item.to_s.strip }.reject(&:blank?)
    return "none" if items.empty?

    items.join(", ")
  end
end
