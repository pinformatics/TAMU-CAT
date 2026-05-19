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
    title = question&.question_text.to_s.strip
    return if title.blank? || survey.blank? || student.blank?
    return unless Reports::DataAggregator::COMPETENCY_TITLES.include?(title)

    semester = survey.program_semester
    return if semester.blank?

    release_date = semester.course_grade_release_date
    student_viewer = viewer&.respond_to?(:role_student?) && viewer.role_student?
    if student_viewer && release_date.present? && !release_date.released?
      return {
        released: false,
        release_label: course_release_label(release_date.release_date)
      }
    end

    rating_rows = GradeCompetencyRating
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .where(
        student_id: student.student_id,
        competency_title: title,
        grade_import_batches: { program_semester_id: semester.id }
      )

    evidence_rows = GradeCompetencyEvidence
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .where(
        student_id: student.student_id,
        competency_title: title,
        grade_import_batches: { program_semester_id: semester.id }
      )
      .order(:course_code, :assignment_name, :updated_at)
      .to_a

    levels = rating_rows.filter_map { |rating| rating.aggregated_level&.to_f }
    targets = evidence_rows.filter_map(&:course_target_level).uniq.sort
    return if levels.empty? && targets.empty?

    {
      released: true,
      course_rating: CourseCompetencyRule.aggregate(levels, rule_key: SiteSetting.course_competency_rule),
      course_target_levels: targets,
      source_count: evidence_rows.size
    }
  end

  def render_course_competency_context(context)
    return if context.blank?

    if context[:released] == false
      return content_tag(:div, class: "c-context-panel c-context-panel--locked") do
        safe_join([
          content_tag(:span, "Course competency results", class: "c-context-panel__label"),
          content_tag(:strong, context[:release_label].presence || "Not released")
        ], " ")
      end
    end

    chips = []
    chips << content_tag(:span, "Course level #{format_competency_context_value(context[:course_rating])}", class: "c-context-panel__chip") if context[:course_rating].present?
    if context[:course_target_levels].present?
      target_label = context[:course_target_levels].join(", ")
      chips << content_tag(:span, "Course target #{target_label}", class: "c-context-panel__chip")
    end
    chips << content_tag(:span, pluralize(context[:source_count], "source"), class: "c-context-panel__meta") if context[:source_count].to_i.positive?

    return if chips.empty?

    content_tag(:div, class: "c-context-panel", aria: { label: "Imported course competency context" }) do
      safe_join(chips)
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
