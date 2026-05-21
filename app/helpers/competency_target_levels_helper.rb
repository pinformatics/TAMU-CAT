# frozen_string_literal: true

module CompetencyTargetLevelsHelper
  # Returns the effective competency target level for a question in the context
  # of a survey + student (semester, track, class/cohort).
  #
  # Falls back to Question#program_target_level when no matching
  # CompetencyTargetLevel exists (or when context is missing).
  def effective_competency_target_level(question:, survey:, student:, fallback: nil)
    fallback ||= question&.respond_to?(:program_target_level) ? question.program_target_level : nil
    return fallback unless question && survey && student

    semester_id = survey.respond_to?(:program_semester_id) ? survey.program_semester_id : nil
    track = if student.respond_to?(:track_before_type_cast)
      student.track_before_type_cast
    else
      student[:track]
    end
    title = question.respond_to?(:question_text) ? question.question_text.to_s.strip : ""

    return fallback if semester_id.blank? || track.blank? || title.blank?

    lookup = competency_target_level_lookup(program_semester_id: semester_id, track: track, class_of: student.respond_to?(:program_year) ? student.program_year : nil)
    lookup[title].presence || fallback
  end

  def course_competency_context_for(question:, survey:, student:, viewer: nil)
    title = canonical_course_competency_title(question&.question_text)
    return if title.blank? || survey.blank? || student.blank?

    cache_key = [
      student.student_id,
      title,
      viewer&.respond_to?(:role_student?) && viewer.role_student? ? "student" : "staff"
    ]
    @_course_competency_context_cache ||= {}
    return @_course_competency_context_cache[cache_key] if @_course_competency_context_cache.key?(cache_key)

    student_viewer = viewer&.respond_to?(:role_student?) && viewer.role_student?
    competency = Competency.find_by_normalized_title(title) if defined?(Competency)

    evidence_rows = GradeCompetencyEvidence
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .includes(grade_import_batch: { program_semester: :course_grade_release_date })
      .where(student_id: student.student_id)
    evidence_rows = if competency&.id.present?
      evidence_rows.where(
        "grade_competency_evidences.competency_id = :competency_id OR grade_competency_evidences.competency_title = :title",
        competency_id: competency.id,
        title: title
      )
    else
      evidence_rows.where(competency_title: title)
    end
    evidence_rows = evidence_rows
      .order(:course_code, :assignment_name, :updated_at)
      .to_a

    released_rows = student_viewer ? evidence_rows.select { |row| course_evidence_released?(row) } : evidence_rows
    embargoed_rows = student_viewer ? evidence_rows.reject { |row| course_evidence_released?(row) } : []

    context = if released_rows.any?
      {
        released: true,
        entries: course_competency_evidence_entries(released_rows)
      }
    elsif embargoed_rows.any?
      {
        released: false,
        release_label: embargoed_release_label(embargoed_rows)
      }
    end

    @_course_competency_context_cache[cache_key] = context
  end

  def render_course_competency_context(context)
    return if context.blank?

    if context[:released] == false
      return content_tag(:div, class: "c-context-panel c-context-panel--locked") do
        safe_join([
          content_tag(:span, "Course competency evidence", class: "c-context-panel__label"),
          content_tag(:strong, context[:release_label].presence || "Not released")
        ], " ")
      end
    end

    entries = Array(context[:entries])
    return if entries.empty?

    rows = entries.map do |entry|
      parts = [
        content_tag(:strong, "Mastery level: #{entry[:mastery_level]}", class: "c-context-panel__value"),
        content_tag(:span, entry[:course_code], class: "c-context-panel__chip"),
        content_tag(:span, entry[:semester_name], class: "c-context-panel__meta")
      ]

      if entry[:course_target_levels].present?
        parts << content_tag(:span, "Course target: #{entry[:course_target_levels].join(', ')}", class: "c-context-panel__meta")
      end

      if entry[:source_count].to_i > 1
        parts << content_tag(:span, pluralize(entry[:source_count], "source"), class: "c-context-panel__meta")
      end

      content_tag(:div, class: "c-context-panel__row") do
        safe_join(parts, " ")
      end
    end

    content_tag(:div, class: "c-context-panel c-context-panel--stacked", aria: { label: "Imported course competency evidence" }) do
      safe_join([
        content_tag(:span, "Course competency evidence", class: "c-context-panel__label"),
        content_tag(:div, safe_join(rows), class: "c-context-panel__rows")
      ])
    end
  end

  private

  def course_release_label(value)
    return "Visible now" if value.blank?

    "Available #{I18n.l(value.in_time_zone, format: :long)}"
  end

  def format_competency_context_value(value)
    return value if value.blank?

    number_with_precision(value, precision: 2, strip_insignificant_zeros: true)
  end

  def canonical_course_competency_title(value)
    raw_title = value.to_s.strip
    return if raw_title.blank?
    return raw_title if Reports::DataAggregator::COMPETENCY_TITLES.include?(raw_title)

    if defined?(Competency)
      competency = Competency.find_by_normalized_title(raw_title)
      return competency.title if competency
    end

    normalized = if defined?(Competency)
      Competency.normalize_title(raw_title)
    else
      raw_title.downcase.gsub("&", " and ").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
    end

    Reports::DataAggregator::COMPETENCY_TITLES.find do |known_title|
      comparable = if defined?(Competency)
        Competency.normalize_title(known_title)
      else
        known_title.downcase.gsub("&", " and ").gsub(/[^\p{Alnum}]+/, " ").squeeze(" ").strip
      end
      comparable == normalized
    end
  end

  def course_evidence_released?(row)
    release = row.grade_import_batch&.program_semester&.course_grade_release_date
    release.blank? || release.released?
  end

  def embargoed_release_label(rows)
    release_dates = Array(rows).filter_map do |row|
      row.grade_import_batch&.program_semester&.course_grade_release_date&.release_date
    end

    release_dates.any? ? course_release_label(release_dates.min) : "Not released"
  end

  def course_competency_evidence_entries(rows)
    Array(rows).group_by do |row|
      [
        row.grade_import_batch&.program_semester_id || "no-semester",
        row.course_code.presence || "Unspecified course"
      ]
    end.map do |(_semester_id, course_code), grouped_rows|
      first_row = grouped_rows.first
      mastery_level = CourseCompetencyRule.aggregate(
        grouped_rows.filter_map { |row| row.mapped_level&.to_f },
        rule_key: SiteSetting.course_competency_rule
      )

      next if mastery_level.blank?

      semester = first_row.grade_import_batch&.program_semester

      {
        course_code: format_course_code_for_context(course_code),
        semester_name: semester&.name.presence || "No semester assigned",
        semester_sort: semester&.created_at || Time.at(0),
        mastery_level: format_competency_context_value(mastery_level),
        course_target_levels: grouped_rows.filter_map(&:course_target_level).uniq.sort.map { |level| format_competency_context_value(level) },
        source_count: grouped_rows.size
      }
    end.compact.sort_by { |entry| [ entry[:semester_sort], entry[:course_code] ] }
  end

  def format_course_code_for_context(course_code)
    normalized = course_code.to_s.strip
    return "Unspecified course" if normalized.blank?

    if (match = normalized.match(/\A([A-Za-z]+)-(\d+)(?:-(.+))?\z/))
      suffix = match[3].present? ? "-#{match[3]}" : ""
      "#{match[1].upcase} #{match[2]}#{suffix}"
    else
      normalized
    end
  end

  # Memoized per-request lookup for a semester+track+class_of context.
  # Uses class-specific values when present, with a nil-class fallback.
  def competency_target_level_lookup(program_semester_id:, track:, class_of: nil)
    @_competency_target_level_lookup ||= {}

    cache_key = [ program_semester_id, track.to_s, class_of ].freeze
    return @_competency_target_level_lookup[cache_key] if @_competency_target_level_lookup.key?(cache_key)

    titles = Reports::DataAggregator::COMPETENCY_TITLES

    scoped = CompetencyTargetLevel.where(
      program_semester_id: program_semester_id,
      track: track,
      competency_title: titles
    )

    exact_levels = scoped.where(class_of: class_of).pluck(:competency_title, :target_level).to_h
    fallback_levels = class_of.nil? ? {} : scoped.where(class_of: nil).pluck(:competency_title, :target_level).to_h

    # If the student has no cohort year recorded, fall back to any available class
    # for that competency (deterministically: lowest class_of). This keeps the
    # UI from hiding target levels when the data exists but the student record is
    # missing cohort year.
    any_year_levels = {}
    if class_of.nil?
      scoped.where.not(class_of: nil)
            .order(:class_of)
            .pluck(:competency_title, :target_level, :class_of)
            .each do |row_title, row_level, _row_class|
        any_year_levels[row_title] ||= row_level
      end
    end

    @_competency_target_level_lookup[cache_key] = fallback_levels.merge(any_year_levels).merge(exact_levels)
  end
end
