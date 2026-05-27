# frozen_string_literal: true

module Reports
  # Aggregates survey response data to support the advisor/admin analytics dashboard
  # and exports. All calculations respect the current user's data access scope
  # and any active filters passed from the client.
  class DataAggregator
    NUMERIC_PATTERN = /\A-?\d+(?:\.\d+)?\z/.freeze

    SCALE_MIN = 1.0
    SCALE_MAX = 5.0
    TIMELINE_MONTHS = 3

    COMPETENCY_TITLES = [
      "Public and Population Health Assessment",
      "Delivery, Organization, and Financing of Health Services and Health Systems",
      "Policy Analysis",
      "Legal & Ethical Bases for Health Services and Health Systems",
      "Ethics, Accountability, and Self-Assessment",
      "Organizational Dynamics",
      "Problem Solving, Decision Making, and Critical Thinking",
      "Team Building and Collaboration",
      "Strategic Planning",
      "Business Planning",
      "Communication",
      "Financial Management",
      "Performance Improvement",
      "Project Management",
      "Systems Thinking",
      "Data Analysis and Information Management",
      "Quantitative Methods for Health Services Delivery"
    ].freeze

    REPORT_DOMAINS = [
      "Health Care Environment and Community",
      "Leadership Skills",
      "Management Skills",
      "Analytic and Technical Skills"
    ].freeze
    RECENT_WINDOW = 90.days
    DATASET_SELECT = [
      "student_questions.id",
      "student_questions.id AS student_question_id",
      "student_questions.response_value",
      "student_questions.advisor_id",
      "student_questions.updated_at",
      "categories.id AS category_id",
      "categories.name AS category_name",
      "questions.question_text AS question_text",
      "questions.program_target_level AS program_target_level",
      "surveys.id AS survey_id",
      "surveys.title AS survey_title",
      "program_semesters.id AS program_semester_id",
      "program_semesters.name AS survey_semester",
      "students.track AS student_track",
      "students.program_year AS student_class_of",
      "students.program_year AS student_program_year",
      "students.student_id AS student_primary_id",
      "students.advisor_id AS owning_advisor_id"
    ].freeze

    FEEDBACK_SELECT = [
      "feedback.id",
      "feedback.id AS student_question_id",
      "feedback.average_score AS response_value",
      "feedback.advisor_id",
      "feedback.updated_at",
      "categories.id AS category_id",
      "categories.name AS category_name",
      "questions.question_text AS question_text",
      "questions.program_target_level AS program_target_level",
      "surveys.id AS survey_id",
      "surveys.title AS survey_title",
      "program_semesters.id AS program_semester_id",
      "program_semesters.name AS survey_semester",
      "students.track AS student_track",
      "students.program_year AS student_class_of",
      "students.program_year AS student_program_year",
      "students.student_id AS student_primary_id",
      "students.advisor_id AS owning_advisor_id"
    ].freeze

    def initialize(user:, params: {})
      @user = user
      @raw_params = params.to_h.with_indifferent_access
    end

    # Returns the option sets for filter dropdowns.
    def filter_options
      {
        tracks: available_tracks,
        semesters: available_semesters,
        advisors: available_advisors,
        categories: available_categories,
        surveys: available_surveys,
        students: available_students,
        competencies: available_competencies
      }
    end

    # Primary benchmark payload with summary cards and line-chart data.
    def benchmark
      @benchmark ||= build_benchmark_payload
    end

    # High-level competency metrics for the progress grid.
    def competency_summary
      @competency_summary ||= build_competency_summary
    end

    # Detailed competency metrics across the 17 program competencies.
    def competency_detail
      @competency_detail ||= build_competency_detail
    end

    # Track-level aggregate details used by exports.
    def track_summary
      @track_summary ||= build_track_summary
    end

    # Cards for quick overview tiles (alias for convenience).
    def summary_cards
      benchmark[:cards]
    end

    # Comprehensive payload used by PDF/Excel exports.
    def export_payload
      {
        generated_at: Time.current,
        filters: export_filters,
        benchmark: benchmark,
        competency_summary: competency_summary,
        competency_detail: competency_detail,
        track_summary: track_summary,
        employment_summary: employment_summary
      }
    end

    # Employment section: aggregate employment status, hours, and flexibility
    # across all respondents within the active filter scope.
    def employment_summary
      @employment_summary ||= build_employment_summary
    end

    private

    # ---------------------------------------------------------------------------
    # Employment summary helpers
    # ---------------------------------------------------------------------------

    EMPLOYMENT_FIELD_MAP = {
      "currently employed"           => :currently_employed,
      "where are you employed"       => :employer,
      "what is your title"           => :job_title,
      "hours per week"               => :hours_per_week,
      "flexible are your work hours" => :flexibility
    }.freeze

    def employment_field_key(question_text)
      normalized = question_text.to_s.downcase
      EMPLOYMENT_FIELD_MAP.each { |pattern, key| return key if normalized.include?(pattern) }
      nil
    end

    def build_employment_summary
      # Pull all employment-related responses respecting the standard filter scope.
      # Note: custom select must include student_questions.question_id so ActiveRecord
      # doesn't raise MissingAttributeError when materialising StudentQuestion records.
      rows = employment_response_scope
        .select(
          "student_questions.student_id",
          "student_questions.question_id",
          "student_questions.response_value",
          "questions.question_text",
          "questions.question_type"
        )

      # Group responses by student so each student contributes once per field.
      by_student = Hash.new { |h, k| h[k] = {} }
      rows.each do |record|
        field = employment_field_key(record.question_text)
        next unless field

        by_student[record.student_id][field] ||= parse_employment_value(record)
      end

      # Aggregate buckets
      status_counts   = Hash.new(0)   # "Yes" / "No" / "No response"
      hours_dist      = Hash.new(0)   # bucket label => count
      flex_dist       = Hash.new(0)   # "1".."5" => count
      total_employed  = 0
      total_responded = by_student.size

      by_student.each_value do |fields|
        employed = fields[:currently_employed]
        if employed.blank?
          status_counts["No response"] += 1
          next
        end

        if employed.casecmp?("Yes")
          status_counts["Employed"] += 1
          total_employed += 1

          hours_value = parse_employment_integer(fields[:hours_per_week])
          if hours_value
            bucket = hours_bucket(hours_value)
            hours_dist[bucket] += 1
          end

          flex_raw = fields[:flexibility].to_s.strip
          flex_digit = flex_raw[/\A(\d+)/, 1]
          flex_dist[flex_digit] += 1 if flex_digit && ("1".."5").include?(flex_digit)
        elsif employed.casecmp?("No")
          status_counts["Not employed"] += 1
        else
          status_counts["No response"] += 1
        end
      end

      employment_rate = total_responded > 0 ? (total_employed.to_f / total_responded * 100).round(1) : nil

      # Build sorted distributions for the charting layer
      hours_labels  = %w[<10 10–19 20–29 30–39 40–49 50+]
      hours_data    = hours_labels.map { |label| hours_dist[label] }

      flex_labels = [ "1 — No flexibility", "2 — Limited", "3 — Some", "4 — Flexible", "5 — Very flexible" ]
      flex_data   = (1..5).map { |n| flex_dist[n.to_s] }

      {
        total_respondents:  total_responded,
        employment_rate:    employment_rate,
        status_counts:      status_counts.map { |label, count| { label: label, count: count } },
        hours_distribution: { labels: hours_labels, data: hours_data },
        flexibility_distribution: { labels: flex_labels, data: flex_data }
      }
    end

    def employment_response_scope
      scope = StudentQuestion
        .joins(:student)
        .merge(accessible_student_relation)
        .joins(question: { category: { survey: :program_semester } })
        .where("LOWER(categories.name) LIKE ?", "%employment%")

      scope = scope.where(students: { track: filters[:track] }) if filters[:track]
      if filters[:semester]
        scope = scope.where("LOWER(program_semesters.name) = ?", filters[:semester].downcase)
      end
      scope = scope.where(surveys: { id: filters[:survey_id] }) if filters[:survey_id]
      scope = scope.where(students: { advisor_id: filters[:advisor_id] }) if filters[:advisor_id]
      scope = scope.where(student_questions: { student_id: filters[:student_id] }) if filters[:student_id]

      scope
    end

    def parse_employment_value(record)
      raw = record.response_value
      return raw if raw.is_a?(String) && !raw.start_with?("{", "[")

      begin
        parsed = JSON.parse(raw.to_s)
        case parsed
        when Hash
          parsed["answer"] || parsed["value"] || parsed["rating"] || raw
        when Array
          parsed.first.to_s
        else
          raw
        end
      rescue JSON::ParserError
        raw
      end
    end

    def parse_employment_integer(value)
      candidate = value.to_s.strip
      return nil if candidate.blank?
      return nil unless candidate.match?(/\A\d+\z/)

      Integer(candidate, 10)
    rescue ArgumentError, TypeError
      nil
    end

    def hours_bucket(n)
      case n
      when 0..9   then "<10"
      when 10..19 then "10–19"
      when 20..29 then "20–29"
      when 30..39 then "30–39"
      when 40..49 then "40–49"
      else             "50+"
      end
    end

    attr_reader :user

    def filters
      return @filters if defined?(@filters)

      sanitized = {}
      assign_filter(sanitized, :track) { |val| val unless val.casecmp?("all") }
      assign_filter(sanitized, :semester) { |val| val unless val.casecmp?("all") }
      assign_filter(sanitized, :survey_id) do |val|
        id = val.to_i
        id if id.positive?
      end
      assign_filter(sanitized, :category_id) { |val| parse_category_filter(val) }
      assign_filter(sanitized, :student_id) do |val|
        id = val.to_i
        id if id.positive? && accessible_student_ids.include?(id)
      end
      assign_filter(sanitized, :advisor_id) do |val|
        id = val.to_i
        id if id.positive? && accessible_advisor_ids.include?(id)
      end
      assign_filter(sanitized, :competency) do |val|
        slug = normalize_competency_slug(val)
        slug if slug && competency_lookup.key?(slug)
      end

      @filters = sanitized
    end

    def assign_filter(hash, key)
      raw = @raw_params[key]
      return if raw.blank?

      value = yield raw.to_s
      hash[key] = value if value.present?
    end

    def accessible_student_relation
      return Student.none unless user
      return Student.all if user.role_admin? || user.role_advisor?

      advisor = user.advisor_profile
      advisor ? Student.where(advisor_id: advisor.advisor_id) : Student.none
    end

    def accessible_student_ids
      @accessible_student_ids ||= accessible_student_relation.pluck(:student_id)
    end

    def scoped_student_relation
      return @scoped_student_relation if defined?(@scoped_student_relation)

      relation = accessible_student_relation
      relation = relation.where(track: filters[:track]) if filters[:track]
      relation = relation.where(advisor_id: filters[:advisor_id]) if filters[:advisor_id]
      relation = relation.where(student_id: filters[:student_id]) if filters[:student_id]

      if filters[:survey_id] || filters[:semester]
        assignment_students = scoped_assignment_scope.select(:student_id)
        relation = relation.where(student_id: assignment_students)
      end

      @scoped_student_relation = relation.distinct
    end

    def scoped_student_ids
      @scoped_student_ids ||= scoped_student_relation.pluck(:student_id)
    end

    def accessible_advisor_ids
      @accessible_advisor_ids ||= begin
        ids = accessible_student_relation.where.not(advisor_id: nil).distinct.pluck(:advisor_id)
        advisor_id = user&.advisor_profile&.advisor_id
        ids << advisor_id if advisor_id
        ids.compact.uniq
      end
    end

    def base_scope
      StudentQuestion
        .joins(:student)
        .merge(accessible_student_relation)
        .joins(question: { category: { survey: :program_semester } })
        .where.not(response_value: [ nil, "" ])
    end

    def filtered_scope
      scope = base_scope
      if filters[:track]
        scope = scope.where(students: { track: filters[:track] })
      end
      if filters[:semester]
        scope = scope.where("LOWER(program_semesters.name) = ?", filters[:semester].downcase)
      end
      if filters[:survey_id]
        scope = scope.where(surveys: { id: filters[:survey_id] })
      end
      category_ids = selected_category_ids
      scope = scope.where(categories: { id: category_ids }) if category_ids.present?
      if filters[:competency]
        competency_name = competency_lookup[filters[:competency]]&.dig(:name)
        if competency_name.present?
          scope = scope.where("LOWER(questions.question_text) = ?", competency_name.downcase)
        end
      end
      if filters[:student_id]
        scope = scope.where(student_questions: { student_id: filters[:student_id] })
      end
      if filters[:advisor_id]
        scope = scope.where(students: { advisor_id: filters[:advisor_id] })
      end
      scope
    end

    def feedback_scope
      Feedback
        .joins(:student)
        .merge(accessible_student_relation)
        .joins(:question)
        .joins(question: { category: { survey: :program_semester } })
        .where.not(average_score: nil)
    end

    def filtered_feedback_scope
      scope = feedback_scope
      if filters[:track]
        scope = scope.where(students: { track: filters[:track] })
      end
      if filters[:semester]
        scope = scope.where("LOWER(program_semesters.name) = ?", filters[:semester].downcase)
      end
      if filters[:survey_id]
        scope = scope.where(surveys: { id: filters[:survey_id] })
      end
      category_ids = selected_category_ids
      scope = scope.where(categories: { id: category_ids }) if category_ids.present?
      if filters[:competency]
        competency_name = competency_lookup[filters[:competency]]&.dig(:name)
        if competency_name.present?
          scope = scope.where("LOWER(questions.question_text) = ?", competency_name.downcase)
        end
      end
      if filters[:student_id]
        scope = scope.where(feedback: { student_id: filters[:student_id] })
      end
      if filters[:advisor_id]
        scope = scope.where(feedback: { advisor_id: filters[:advisor_id] })
      end
      scope
    end

    def dataset_rows
      @dataset_rows ||= begin
        rows = []
        filtered_scope.select(DATASET_SELECT).find_each(batch_size: 1_000) do |record|
          next unless assignment_completed?(record.student_primary_id, record.survey_id)
          next unless (row = build_dataset_row(record, is_advisor_entry: false))

          rows << row
        end
        filtered_feedback_scope.select(FEEDBACK_SELECT).find_each(batch_size: 1_000) do |record|
          next unless assignment_completed?(record.student_primary_id, record.survey_id)
          next unless (row = build_dataset_row(record, is_advisor_entry: true))

          rows << row
        end
        rows
      end
    end

    def student_response_groups
      @student_response_groups ||= group_student_rows(dataset_rows.reject { |row| row[:advisor_entry] })
    end

    def student_survey_response_pairs
      @student_survey_response_pairs ||= begin
        filtered_scope
          .distinct
          .pluck("student_questions.student_id", "surveys.id")
          .each_with_object({}) do |(student_id, survey_id), memo|
            next unless student_id && survey_id
            next unless assignment_completed?(student_id, survey_id)

            memo[[ student_id, survey_id ]] = true
          end
      end
    end

    def assignment_pair_key(student_id, survey_id)
      return nil if student_id.blank? || survey_id.blank?

      [ student_id, survey_id ]
    end

    def parse_numeric(value)
      str = value.to_s.strip
      return nil unless NUMERIC_PATTERN.match?(str)

      str.to_f
    rescue StandardError
      nil
    end

    def average(values)
      return nil if values.blank?

      values.sum.to_f / values.size
    end

    def safe_percent(numerator, denominator)
      return nil if denominator.to_f.zero?

      (numerator.to_f / denominator.to_f) * 100.0
    end

    def alignment_percent(student_avg, advisor_avg)
      return nil if student_avg.nil? || advisor_avg.nil?

      gap = (student_avg - advisor_avg).abs
      max_gap = (SCALE_MAX - SCALE_MIN)
      return nil if max_gap <= 0

      clamped_gap = [ gap, max_gap ].min
      ((max_gap - clamped_gap) / max_gap) * 100.0
    end

    def build_benchmark_payload
      Rails.logger.debug "--- Starting build_benchmark_payload ---"
      Rails.logger.debug "Filters applied: #{@raw_params.inspect}"
      Rails.logger.debug "Dataset rows count: #{dataset_rows.size}"

      benchmark_thresholds = {
        students_goal_percent: 80.0,
        competencies_goal_percent: 85.0
      }

      benchmark_attainment = benchmark_attainment_stats(
        dataset_rows,
        competencies_goal_percent: benchmark_thresholds[:competencies_goal_percent]
      )

      cards = []

      overall_source_label = rating_source_label(benchmark_attainment.dig(:source_breakdown, :overall))
      overall_meta = {
        goal_percent: benchmark_thresholds[:students_goal_percent],
        students_met_goal: benchmark_attainment[:overall][:students_meeting_count],
        competencies_goal_percent: benchmark_thresholds[:competencies_goal_percent]
      }
      overall_meta[:name] = overall_source_label if overall_source_label.present?

      cards << build_card(
        key: "benchmark_attainment_overall",
        title: "Benchmark Attainment",
        value: benchmark_attainment[:overall][:students_meeting_percent],
        unit: "percent",
        precision: 0,
        change: nil,
        description: "Percent of students meeting target in at least #{benchmark_thresholds[:competencies_goal_percent].to_i}% of competencies.",
        sample_size: benchmark_attainment[:overall][:total_students],
        meta: overall_meta
      )

      cards << build_card(
        key: "benchmark_not_meeting_overall",
        title: "Below Benchmark",
        value: benchmark_attainment[:overall][:students_not_meeting_percent],
        unit: "percent",
        precision: 0,
        change: nil,
        description: "Percent of students below the benchmark threshold.",
        sample_size: benchmark_attainment[:overall][:total_students]
      )

      track_summaries = []
      benchmark_attainment[:by_track].each do |track_key, stats|
        track_label = track_key.to_s.strip
        next if track_label.blank?

        track_source_label = rating_source_label(benchmark_attainment.dig(:source_breakdown, :by_track, track_key))

        track_summaries << {
          label: track_label,
          percent: stats[:students_meeting_percent],
          students_met_goal: stats[:students_meeting_count],
          sample_size: stats[:total_students],
          source_label: track_source_label
        }
      end

      if track_summaries.any?
        total_track_students = track_summaries.sum { |entry| entry[:sample_size].to_i }
        cards << build_card(
          key: "benchmark_attainment_by_track",
          title: "Benchmark by Track",
          value: nil,
          unit: "percent",
          precision: 0,
          change: nil,
          description: "Percent of students meeting the benchmark broken down by track.",
          sample_size: total_track_students,
          meta: {
            goal_percent: benchmark_thresholds[:students_goal_percent],
            competencies_goal_percent: benchmark_thresholds[:competencies_goal_percent],
            tracks: track_summaries
          }
        )
      end

      alignment_card = build_alignment_card
      cards << alignment_card if alignment_card

      completion_stats = completion_stats()
      cards << build_card(
        key: "completion_rate",
        title: "Survey Completion",
        value: completion_stats[:completion_rate],
        unit: "percent",
        precision: 0,
        change: completion_stats[:trend],
        description: "Percent of assigned surveys submitted.",
        sample_size: completion_stats[:total_assignments]
      )

      competency_summary_data = competency_summary
      Rails.logger.debug "Competency Summary (for Leading Competency card): #{competency_summary_data.first.inspect}"

      Rails.logger.debug "--- Finished build_benchmark_payload ---"

      {
        completion_rate: completion_stats[:completion_rate],
        cards: cards.compact,
        timeline: build_timeline,
        benchmark_attainment: benchmark_attainment
      }
    end

    def build_alignment_card
      summary = alignment_summary
      return nil unless summary

      build_card(
        key: "student_advisor_alignment",
        title: "Student & Advisor Alignment",
        value: summary[:percent],
        unit: "percent",
        precision: 0,
        change: summary[:change],
        description: "Percent alignment between student self-assessments and advisor ratings.",
        sample_size: summary[:sample_size],
        meta: summary[:meta]
      )
    end

    def benchmark_attainment_stats(rows, competencies_goal_percent:)
      goal = competencies_goal_percent.to_f

      grouped = Hash.new { |hash, key| hash[key] = {} }

      rows.each do |row|
        student_id = row[:student_id]
        next if student_id.blank?

        competency_title = normalized_competency_title(row[:question_text])
        next if competency_title.blank?

        existing = grouped[student_id][competency_title]
        if existing.nil?
          grouped[student_id][competency_title] = row
          next
        end

        existing_time = existing[:updated_at]
        incoming_time = row[:updated_at]

        preferred = if existing[:advisor_entry] && !row[:advisor_entry]
          false
        elsif !existing[:advisor_entry] && row[:advisor_entry]
          true
        elsif existing_time.present? && incoming_time.present?
          incoming_time > existing_time
        else
          false
        end

        grouped[student_id][competency_title] = row if preferred
      end

      per_student = {}
      per_track = Hash.new { |hash, key| hash[key] = { students: 0, meeting: 0 } }
      per_track_source_counts = Hash.new { |hash, key| hash[key] = { advisor: 0, student: 0 } }
      overall_source_counts = { advisor: 0, student: 0 }

      grouped.each do |student_id, competency_map|
        competency_rows = competency_map.values
        next if competency_rows.blank?

        achieved = 0
        advisor_entries = 0
        student_entries = 0

        competency_rows.each do |row|
          target = row[:program_target_level].presence || 4.0
          achieved += 1 if row[:score].to_f >= target.to_f
          if row[:advisor_entry]
            advisor_entries += 1
          else
            student_entries += 1
          end
        end

        total = competency_rows.size
        percent_met = safe_percent(achieved, total) || 0.0
        meets_goal = percent_met >= goal

        track = competency_rows.first[:track]
        track_key = track.to_s

        overall_source_counts[:advisor] += advisor_entries
        overall_source_counts[:student] += student_entries
        per_track_source_counts[track_key][:advisor] += advisor_entries
        per_track_source_counts[track_key][:student] += student_entries
        per_student[student_id] = {
          track: track,
          competencies_total: total,
          competencies_met: achieved,
          competencies_met_percent: percent_met,
          meets_benchmark: meets_goal
        }

        per_track[track_key][:students] += 1
        per_track[track_key][:meeting] += 1 if meets_goal
      end

      total_students = per_student.size
      meeting_students = per_student.values.count { |s| s[:meets_benchmark] }
      meeting_percent = safe_percent(meeting_students, total_students)
      not_meeting_percent = meeting_percent.nil? ? nil : (100.0 - meeting_percent)

      {
        overall: {
          total_students: total_students,
          students_meeting_count: meeting_students,
          students_meeting_percent: meeting_percent,
          students_not_meeting_percent: not_meeting_percent,
          competencies_goal_percent: goal
        },
        by_track: per_track.transform_values do |stats|
          meeting_pct = safe_percent(stats[:meeting], stats[:students])
          {
            total_students: stats[:students],
            students_meeting_count: stats[:meeting],
            students_meeting_percent: meeting_pct
          }
        end,
        per_student: per_student,
        source_breakdown: {
          overall: overall_source_counts,
          by_track: per_track_source_counts.transform_values { |counts| counts.dup }
        }
      }
    end

    def rating_source_label(source_counts)
      counts = source_counts || {}
      advisor = counts[:advisor].to_i
      student = counts[:student].to_i

      return nil if advisor.zero? && student.zero?

      if advisor.positive? && student.positive?
        "Advisor & student ratings"
      elsif advisor.positive?
        "Advisor ratings"
      else
        "Student self-ratings"
      end
    end

    def build_card(key:, title:, value:, unit:, precision:, description:, change:, sample_size:, meta: nil)
      tracks = meta.is_a?(Hash) ? Array(meta[:tracks]) : []
      return nil if value.nil? && tracks.blank?

      {
        key: key,
        title: title,
        value: value,
        unit: unit,
        precision: precision,
        description: description,
        change: change,
        change_direction: change_direction(change),
        sample_size: sample_size,
        meta: meta
      }
    end

    def change_direction(change)
      return "flat" if change.nil?
      return "up" if change.positive?
      return "down" if change.negative?

      "flat"
    end

    def percent_change_for(role)
      role_key = role == :advisor ? :advisor_entry : :student_entry
      recent_range = (Time.current - RECENT_WINDOW)..Time.current
      previous_range = (Time.current - (RECENT_WINDOW * 2))...(Time.current - RECENT_WINDOW)

      recent_scores = scores_for(role_key, recent_range)
      previous_scores = scores_for(role_key, previous_range)

      recent_avg = average(recent_scores)
      previous_avg = average(previous_scores)

      return nil if recent_avg.nil? || previous_avg.nil? || previous_avg.zero?

      ((recent_avg - previous_avg) / previous_avg) * 100.0
    end

    def scores_for(role_key, range)
      dataset_rows.filter do |row|
        matches_role = role_key == :advisor_entry ? row[:advisor_entry] : !row[:advisor_entry]
        matches_role && range.cover?(row[:updated_at])
      end.map { |row| row[:score] }
    end

    def build_timeline
      return [] if dataset_rows.empty? && course_rating_rows.empty?

      buckets = Hash.new { |hash, key| hash[key] = { student_rows: [], advisor_rows: [], course_rows: [] } }

      dataset_rows.each do |row|
        month = row[:updated_at].in_time_zone.beginning_of_month
        bucket = buckets[month]
        if row[:advisor_entry]
          bucket[:advisor_rows] << row
        else
          bucket[:student_rows] << row
        end
      end

      course_rating_rows.each do |row|
        month = row[:updated_at].in_time_zone.beginning_of_month
        buckets[month][:course_rows] << row
      end

      buckets.keys.sort.last(TIMELINE_MONTHS).map do |month|
        student_rows = buckets[month][:student_rows]
        advisor_rows = buckets[month][:advisor_rows]
        course_rows = buckets[month][:course_rows]
        student_avg = average(student_rows.map { |row| row[:score] })
        advisor_avg = average(advisor_rows.map { |row| row[:score] })
        course_avg = average(course_rows.map { |row| row[:score] })

        student_target_percent = target_percent_for_rows(student_rows)
        advisor_target_percent = target_percent_for_rows(advisor_rows)
        course_target_percent = target_percent_for_rows(course_rows)
        {
          label: month.strftime("%b %Y"),
          student: student_avg,
          advisor: advisor_avg,
          course: course_avg,
          student_target_percent: student_target_percent,
          advisor_target_percent: advisor_target_percent,
          course_target_percent: course_target_percent,
          alignment: alignment_percent(student_avg, advisor_avg)
        }
      end
    end

    def target_percent_for_rows(rows)
      total_students = scoped_student_ids.size
      return nil if total_students.zero?

      by_student = group_student_rows(rows)
      met = 0

      scoped_student_ids.each do |student_id|
        entries = by_student[student_id] || []
        next if entries.blank?

        score_avg = average(entries.map { |row| row[:score] })
        target_levels = entries.map { |row| row[:program_target_level] }.compact.map(&:to_f)
        target_avg = average(target_levels)
        next if score_avg.nil? || target_avg.nil?

        met += 1 if score_avg >= target_avg
      end

      safe_percent(met, total_students)
    end

    def alignment_trend_change
      timeline = build_timeline
      return nil unless timeline.size >= 2

      latest = timeline[-1][:alignment]
      previous = timeline[-2][:alignment]
      return nil if latest.nil? || previous.nil?

      latest - previous
    end

    def alignment_summary
      student_rows = dataset_rows.reject { |row| row[:advisor_entry] }
      advisor_rows = dataset_rows.select { |row| row[:advisor_entry] }

      student_avg = average(student_rows.map { |row| row[:score] })
      advisor_avg = average(advisor_rows.map { |row| row[:score] })
      alignment = alignment_percent(student_avg, advisor_avg)
      return nil if alignment.nil?

      paired_students = group_student_rows(dataset_rows).count do |_student_id, rows|
        next false if rows.blank?

        has_student = rows.any? { |row| !row[:advisor_entry] }
        has_advisor = rows.any? { |row| row[:advisor_entry] }
        has_student && has_advisor
      end
      return nil if paired_students.zero?

      {
        percent: alignment,
        change: alignment_trend_change,
        sample_size: paired_students,
        meta: {
          name: "Advisor & student ratings",
          advisor_average: advisor_avg,
          student_average: student_avg
        }
      }
    end

    def build_competency_summary
      Rails.logger.debug "--- Building Competency Summary ---"
      assigned_total_students = assigned_student_ids_in_scope.size
      grouped = Hash.new { |hash, key| hash[key] = { rows: [], category_ids: [] } }

      dataset_rows.each do |row|
        slug = category_id_to_slug[row[:category_id]] || normalize_domain_slug(row[:category_name]) || "category_#{row[:category_id]}"
        entry = grouped[slug]
        entry[:rows] << row
        entry[:category_ids] << row[:category_id]
        entry[:name] ||= category_group_lookup[slug]&.dig(:name) || row[:category_name] || "Domain"
      end

      summary = grouped.map do |slug, data|
        rows = data[:rows]
        next if rows.blank?

        student_rows = rows.reject { |row| row[:advisor_entry] }
        advisor_rows = rows.select { |row| row[:advisor_entry] }
        student_avg = average(student_rows.map { |row| row[:score] })
        advisor_avg = average(advisor_rows.map { |row| row[:score] })

        student_group = group_student_rows(student_rows)
        attainment_counts = attainment_counts_for_group(student_group, total_students: assigned_total_students)
        attainment_percentages = attainment_percentages(attainment_counts)

        advisor_group = group_student_rows(advisor_rows)
        advisor_attainment_counts = attainment_counts_for_group(advisor_group, total_students: assigned_total_students)
        advisor_attainment_percentages = attainment_percentages(advisor_attainment_counts)
        course_breakdown = build_competency_course_breakdown(rows)
        course_average = course_domain_average_lookup[slug]
        course_target_percent = course_domain_target_percent_lookup[slug]

        student_target_percent = target_percent_for_rows(student_rows)
        advisor_target_percent = target_percent_for_rows(advisor_rows)
        target_level = average(rows.map { |row| row[:program_target_level] }.compact.map(&:to_f))

        {
          id: slug,
          name: data[:name],
          category_ids: data[:category_ids].uniq,
          student_average: student_avg,
          advisor_average: advisor_avg,
          course_average: course_average,
          gap: advisor_avg && student_avg ? (advisor_avg - student_avg) : nil,
          change: percent_change_for_category(rows),
          status: student_avg && target_level && student_avg >= target_level ? "on_track" : "watch",
          student_sample: student_rows.size,
          advisor_sample: advisor_rows.size,
          achieved_count: attainment_counts[:achieved_count],
          not_met_count: attainment_counts[:not_met_count],
          not_assessed_count: attainment_counts[:not_assessed_count],
          achieved_percent: attainment_percentages[:achieved_percent],
          not_met_percent: attainment_percentages[:not_met_percent],
          not_assessed_percent: attainment_percentages[:not_assessed_percent],
          student_target_percent: student_target_percent,
          advisor_target_percent: advisor_target_percent,
          course_target_percent: course_target_percent,
          program_target_level: target_level,
          total_students: attainment_counts[:total_students],
          courses: course_breakdown
        }
      end.compact

      summary = summary.select { |entry| REPORT_DOMAINS.include?(entry[:name]) }
      order_lookup = domain_order_names.each_with_index.to_h
      summary = summary.sort_by { |entry| order_lookup.fetch(entry[:name], Float::INFINITY) }

      Rails.logger.debug "Generated competency summary: #{summary.inspect}"
      summary
    end

    def percent_change_for_category(rows)
      recent_range = (Time.current - RECENT_WINDOW)..Time.current
      previous_range = (Time.current - (RECENT_WINDOW * 2))...(Time.current - RECENT_WINDOW)

      recent_scores = rows.filter { |row| !row[:advisor_entry] && recent_range.cover?(row[:updated_at]) }.map { |row| row[:score] }
      previous_scores = rows.filter { |row| !row[:advisor_entry] && previous_range.cover?(row[:updated_at]) }.map { |row| row[:score] }

      recent_avg = average(recent_scores)
      previous_avg = average(previous_scores)
      return nil if recent_avg.nil? || previous_avg.nil? || previous_avg.zero?

      ((recent_avg - previous_avg) / previous_avg) * 100.0
    end



    def build_competency_detail
      Rails.logger.debug "--- Building Competency Detail ---"
      assigned_total_students = assigned_student_ids_in_scope.size
      buckets = Hash.new do |hash, key|
        hash[key] = {
          student_rows: [],
          advisor_rows: [],
          domain_name: nil,
          domain_slug: nil
        }
      end

      dataset_rows.each do |row|
        slug = competency_slug(row[:question_text])
        next unless slug && competency_lookup.key?(slug)

        bucket = buckets[slug]
        bucket[:domain_name] ||= row[:category_name]
        bucket[:domain_slug] ||= category_id_to_slug[row[:category_id]] || normalize_domain_slug(row[:category_name])
        if row[:advisor_entry]
          bucket[:advisor_rows] << row
        else
          bucket[:student_rows] << row
        end
      end

      items = COMPETENCY_TITLES.map do |title|
        slug = competency_slug(title)
        bucket = buckets[slug]
        student_rows = bucket&.dig(:student_rows) || []
        advisor_rows = bucket&.dig(:advisor_rows) || []

        student_avg = average(student_rows.map { |row| row[:score] })
        advisor_avg = average(advisor_rows.map { |row| row[:score] })

        student_group = group_student_rows(student_rows)
        attainment_counts = attainment_counts_for_group(student_group, total_students: assigned_total_students)
        attainment_percentages = attainment_percentages(attainment_counts)

        advisor_group = group_student_rows(advisor_rows)
        advisor_attainment_counts = attainment_counts_for_group(advisor_group, total_students: assigned_total_students)
        advisor_attainment_percentages = attainment_percentages(advisor_attainment_counts)
        course_average = course_competency_average_lookup[title]
        course_target_percent = course_competency_target_percent_lookup[title]

        student_target_percent = target_percent_for_rows(student_rows)
        advisor_target_percent = target_percent_for_rows(advisor_rows)
        target_level = average((student_rows + advisor_rows).map { |row| row[:program_target_level] }.compact.map(&:to_f))

        {
          id: slug,
          name: title,
          domain_id: bucket&.dig(:domain_slug),
          domain_name: bucket&.dig(:domain_name),
          student_average: student_avg,
          advisor_average: advisor_avg,
          course_average: course_average,
          gap: advisor_avg && student_avg ? (advisor_avg - student_avg) : nil,
          achieved_count: attainment_counts[:achieved_count],
          not_met_count: attainment_counts[:not_met_count],
          not_assessed_count: attainment_counts[:not_assessed_count],
          achieved_percent: attainment_percentages[:achieved_percent],
          not_met_percent: attainment_percentages[:not_met_percent],
          not_assessed_percent: attainment_percentages[:not_assessed_percent],
          student_target_percent: student_target_percent,
          advisor_target_percent: advisor_target_percent,
          course_target_percent: course_target_percent,
          program_target_level: target_level,
          total_students: attainment_counts[:total_students]
        }
      end

      detail = {
        domains: available_categories.map { |entry| { id: entry[:id], name: entry[:name] } },
        items: items
      }
      Rails.logger.debug "Generated competency detail: #{detail.inspect}"
      detail
    end

    def build_track_summary
      rows_by_track = dataset_rows
                       .group_by { |row| row[:track].to_s.strip }

      program_track_names.map do |track_name|
        rows = rows_by_track[track_name] || []
        track_total_students = assigned_student_count_for_track(track_name)

        student_rows = rows.reject { |row| row[:advisor_entry] }
        advisor_rows = rows.select { |row| row[:advisor_entry] }

        student_avg = average(student_rows.map { |row| row[:score] })
        advisor_avg = average(advisor_rows.map { |row| row[:score] })

        student_by_person = group_student_rows(student_rows)
        attainment_counts = attainment_counts_for_group(student_by_person, total_students: track_total_students)
        attainment_percentages = attainment_percentages(attainment_counts)

        {
          id: ProgramTrack.canonical_key(track_name).presence || track_name.parameterize(separator: "_").presence || "track_#{track_name.object_id}",
          track: track_name,
          student_average: student_avg,
          advisor_average: advisor_avg,
          gap: advisor_avg && student_avg ? (advisor_avg - student_avg) : nil,
          submissions: student_by_person.size,
          achieved_count: attainment_counts[:achieved_count],
          not_met_count: attainment_counts[:not_met_count],
          not_assessed_count: attainment_counts[:not_assessed_count],
          achieved_percent: attainment_percentages[:achieved_percent],
          not_met_percent: attainment_percentages[:not_met_percent],
          not_assessed_percent: attainment_percentages[:not_assessed_percent],
          total_students: attainment_counts[:total_students]
        }
      end
    end

    def completion_stats
      return @completion_stats if defined?(@completion_stats)

      assignments = scoped_assignment_scope
                    .select(:student_id, :survey_id, :completed_at)
                    .distinct
                    .to_a

      total = assignments.size
      completed = assignments.count { |assignment| assignment.completed_at.present? }

      if total.zero?
        total = scoped_student_ids.size
        completed = 0
      end

      rate = total.to_f.zero? ? nil : (completed.to_f / total.to_f * 100.0)

      stats = {
        total_assignments: total,
        completed_assignments: completed,
        completion_rate: rate,
        trend: nil
      }
      Rails.logger.debug "Completion Stats: #{stats.inspect}"
      @completion_stats = stats
    end

    def available_tracks
      program_track_names
    end

    def program_track_names
      return @program_track_names if defined?(@program_track_names)

      names = if ProgramTrack.data_source_ready?
        ProgramTrack.active.ordered.pluck(:name)
      else
        ProgramTrack.names
      end

      @program_track_names = Array(names).map { |name| name.to_s.strip }.reject(&:blank?).uniq
    end

    def normalized_track_name(value)
      text = value.to_s.strip
      text.presence || "Unspecified Track"
    end

    def available_semesters
      base_scope.distinct.pluck("program_semesters.name").compact.sort
    end

    def available_categories
      entries = category_group_lookup
        .values
        .select { |entry| REPORT_DOMAINS.include?(entry[:name]) }
        .map { |entry| { id: entry[:id], name: entry[:name], category_ids: entry[:ids] } }

      order_lookup = domain_order_names.each_with_index.to_h
      entries.sort_by do |entry|
        [ order_lookup.fetch(entry[:name], Float::INFINITY), entry[:name].to_s.downcase ]
      end
    end

    def domain_order_names
      return @domain_order_names if defined?(@domain_order_names)

      @domain_order_names = if filters[:survey_id]
        categories = Category.where(survey_id: filters[:survey_id]).select(:id, :name)
        categories = if Category.column_names.include?("position")
          categories.order(:position, :id)
        else
          categories.order(:id)
        end

        ordered_names = categories.map { |category| category.name.to_s.strip }.reject(&:blank?)
        ordered_names & REPORT_DOMAINS
      else
        REPORT_DOMAINS
      end
    end

    def available_surveys
      base_scope
        .distinct
        .pluck("surveys.id", "surveys.title", "program_semesters.name")
        .map { |id, title, semester| { id: id, title: title, semester: semester } }
        .sort_by { |entry| entry[:title].to_s.downcase }
    end

    def available_advisors
      Advisor
        .where(advisor_id: accessible_advisor_ids)
        .includes(:user)
        .map { |advisor| { id: advisor.advisor_id, name: advisor.display_name } }
        .sort_by { |entry| entry[:name].to_s.downcase }
    end

    def available_students
      accessible_student_relation
        .includes(:user)
        .map do |student|
          {
            id: student.student_id,
            name: student.user.display_name,
            track: student.track,
            advisor_id: student.advisor_id
          }
        end
        .sort_by { |entry| entry[:name].to_s.downcase }
    end

    def available_competencies
      COMPETENCY_TITLES.map do |title|
        {
          id: competency_slug(title),
          name: title
        }
      end
    end

    def competency_lookup
      @competency_lookup ||= available_competencies.index_by { |entry| entry[:id] }
    end

    def course_competency_average_lookup
      @course_competency_average_lookup ||= begin
        grouped = reportable_course_rating_scope.group_by(&:competency_title)
        grouped.transform_values do |ratings|
          levels = ratings.filter_map { |rating| rating.aggregated_level&.to_f }
          CourseCompetencyRule.aggregate(levels, rule_key: active_course_competency_rule)
        end
      end
    end

    def course_competency_target_percent_lookup
      @course_competency_target_percent_lookup ||= begin
        grouped = course_rating_rows.group_by { |row| normalized_competency_title(row[:question_text]) }
        grouped.transform_values { |rows| target_percent_for_rows(rows) }
      end
    end

    def course_domain_average_lookup
      @course_domain_average_lookup ||= begin
        grouped = Hash.new { |hash, key| hash[key] = [] }

        course_competency_average_lookup.each do |title, avg|
          next if avg.nil?

          slug = domain_slug_for_competency(title)
          next if slug.blank?

          grouped[slug] << avg
        end

        grouped.transform_values { |values| average(values) }
      end
    end

    def course_domain_target_percent_lookup
      @course_domain_target_percent_lookup ||= begin
        grouped = Hash.new { |hash, key| hash[key] = [] }

        course_rating_rows.each do |row|
          slug = domain_slug_for_competency(row[:question_text])
          next if slug.blank?

          grouped[slug] << row
        end

        grouped.transform_values { |rows| target_percent_for_rows(rows) }
      end
    end

    def reportable_course_rating_scope
      @reportable_course_rating_scope ||= begin
        scope = GradeCompetencyRating
          .joins(:grade_import_batch, student: :user)
          .merge(GradeImportBatch.reportable)
          .where(student_id: accessible_student_relation.select(:student_id))

        scope = scope.where(students: { track: filters[:track] }) if filters[:track]
        scope = scope.where(students: { advisor_id: filters[:advisor_id] }) if filters[:advisor_id]
        scope = scope.where(student_id: filters[:student_id]) if filters[:student_id]
        if filters[:semester]
          semester = ProgramSemester.find_by_name_case_insensitive(filters[:semester])
          scope = semester ? scope.where(grade_import_batches: { program_semester_id: semester.id }) : scope.none
        end

        if filters[:competency]
          competency_name = competency_lookup[filters[:competency]]&.dig(:name)
          scope = scope.where(competency_title: competency_name) if competency_name.present?
        elsif filters[:category_id]
          scope = scope.where(competency_title: competency_titles_for_domain_filter)
        end

        scope.to_a
      end
    end

    def competency_titles_for_domain_filter
      slug = filters[:category_id]
      return COMPETENCY_TITLES if slug.blank?

      COMPETENCY_TITLES.select { |title| domain_slug_for_competency(title) == slug }
    end

    def domain_slug_for_competency(title)
      slug = competency_slug(title)
      return nil if slug.blank?

      return @domain_slug_for_competency[slug] if defined?(@domain_slug_for_competency) && @domain_slug_for_competency.key?(slug)

      @domain_slug_for_competency ||= {}

      domain_name = competency_detail_domain_lookup[slug]
      @domain_slug_for_competency[slug] = normalize_domain_slug(domain_name)
    end

    def competency_detail_domain_lookup
      @competency_detail_domain_lookup ||= begin
        lookup = {}

        dataset_rows.each do |row|
          slug = competency_slug(row[:question_text])
          next if slug.blank? || row[:category_name].blank?

          lookup[slug] ||= row[:category_name]
        end

        lookup
      end
    end

    def domain_slug(value)
      value.to_s.parameterize(separator: "_")
    end

    def normalize_domain_slug(value)
      slug = domain_slug(value)
      slug.presence
    end

    def category_group_lookup
      return @category_group_lookup if defined?(@category_group_lookup)

      groups = {}

      base_scope
        .distinct
        .pluck("categories.id", "categories.name")
        .each do |id, name|
          next unless id && name.present?

          slug = normalize_domain_slug(name)
          next unless slug

          entry = groups[slug] ||= { id: slug, name: name, ids: [] }
          entry[:name] ||= name
          entry[:ids] << id
        end

      groups.each_value { |entry| entry[:ids].uniq! }

      @category_group_lookup = groups
    end

    def category_id_to_slug
      return @category_id_to_slug if defined?(@category_id_to_slug)

      mapping = {}
      category_group_lookup.each do |slug, entry|
        entry[:ids].each { |id| mapping[id] = slug }
      end

      @category_id_to_slug = mapping
    end

    def parse_category_filter(raw)
      value = raw.to_s.strip
      return nil if value.blank? || value.casecmp?("all")

      if value.match?(/\A\d+\z/)
        slug = category_id_to_slug[value.to_i]
        return slug if slug
      end

      slug = normalize_domain_slug(value)
      return slug if slug && category_group_lookup.key?(slug)

      nil
    end

    def selected_category_ids
      slug = filters[:category_id]
      return [] unless slug

      category_group_lookup[slug]&.dig(:ids) || []
    end

    def normalize_competency_slug(value)
      competency_slug(value).presence
    end

    def normalized_competency_title(value)
      text = value.to_s.strip
      return text if text.blank?

      text.sub(/\s+Reflection\z/i, "")
    end

    def competency_slug(value)
      normalized_competency_title(value).to_s.parameterize(separator: "_")
    end

    def export_filters
      advisor_map = available_advisors.index_by { |advisor| advisor[:id] }
      category_map = available_categories.index_by { |category| category[:id] }
      survey_map = available_surveys.index_by { |survey| survey[:id] }
      student_map = available_students.index_by { |student| student[:id] }
      competency_map = available_competencies.index_by { |entry| entry[:id] }

      {
        track: filters[:track] || "All tracks",
        semester: filters[:semester] || "All semesters",
        advisor: filters[:advisor_id] ? advisor_map[filters[:advisor_id]]&.dig(:name) : "All advisors",
        domain: filters[:category_id] ? category_map[filters[:category_id]]&.dig(:name) : "All domains",
        competency: filters[:competency] ? competency_map[filters[:competency]]&.dig(:name) : "All competencies",
        course_competency_rule: active_course_competency_rule_label,
        survey: filters[:survey_id] ? format_survey_label(survey_map[filters[:survey_id]]) : "All surveys",
        student: filters[:student_id] ? student_map[filters[:student_id]]&.dig(:name) : "All students"
      }
    end

    def active_course_competency_rule
      @active_course_competency_rule ||= SiteSetting.course_competency_rule
    end

    def active_course_competency_rule_label
      CourseCompetencyRule.label_for(active_course_competency_rule)
    end

    def format_survey_label(entry)
      return nil unless entry

      [ entry[:title], entry[:semester] ].compact.join(" · ")
    end

    def build_competency_course_breakdown(rows)
      rows.group_by { |row| row[:survey_id] }.map do |_survey_id, survey_rows|
        student_rows = survey_rows.reject { |row| row[:advisor_entry] }
        advisor_rows = survey_rows.select { |row| row[:advisor_entry] }
        student_group = group_student_rows(student_rows)
        counts = attainment_counts_for_group(student_group)
        percents = attainment_percentages(counts)

        {
          id: survey_rows.first[:survey_id],
          title: survey_rows.first[:survey_title],
          semester: survey_rows.first[:survey_semester],
          student_average: average(student_rows.map { |row| row[:score] }),
          advisor_average: average(advisor_rows.map { |row| row[:score] }),
          achieved_count: counts[:achieved_count],
          not_met_count: counts[:not_met_count],
          not_assessed_count: counts[:not_assessed_count],
          achieved_percent: percents[:achieved_percent],
          not_met_percent: percents[:not_met_percent],
          not_assessed_percent: percents[:not_assessed_percent]
        }
      end.sort_by { |course| course[:title].to_s.downcase }
    end

    def build_course_competency_breakdown(rows)
      rows.group_by { |row| row[:category_id] }.map do |_category_id, category_rows|
        student_rows = category_rows.reject { |row| row[:advisor_entry] }
        advisor_rows = category_rows.select { |row| row[:advisor_entry] }
        student_group = group_student_rows(student_rows)
        counts = attainment_counts_for_group(student_group)
        percents = attainment_percentages(counts)

        {
          id: category_rows.first[:category_id],
          name: category_rows.first[:category_name],
          student_average: average(student_rows.map { |row| row[:score] }),
          advisor_average: average(advisor_rows.map { |row| row[:score] }),
          achieved_count: counts[:achieved_count],
          not_met_count: counts[:not_met_count],
          not_assessed_count: counts[:not_assessed_count],
          achieved_percent: percents[:achieved_percent],
          not_met_percent: percents[:not_met_percent],
          not_assessed_percent: percents[:not_assessed_percent]
        }
      end.sort_by { |competency| competency[:name].to_s.downcase }
    end

    def build_dataset_row(record, is_advisor_entry: false)
      value = parse_numeric(record.response_value)
      return nil unless value

      effective_target_level = competency_target_level_for_record(record)

      {
        id: record.student_question_id,
        score: value,
        advisor_entry: is_advisor_entry,
        updated_at: record.updated_at,
        category_id: record.category_id,
        category_name: record.category_name,
        question_text: record.question_text,
        program_target_level: effective_target_level,
        survey_id: record.survey_id,
        survey_title: record.survey_title,
        program_semester_id: record.program_semester_id,
        survey_semester: record.survey_semester,
        track: record.student_track,
        student_id: record.student_primary_id,
        advisor_id: record.owning_advisor_id || record.advisor_id
      }
    end

    def course_rating_rows
      @course_rating_rows ||= reportable_course_rating_scope.filter_map do |rating|
        target_level = course_target_level_for_rating(rating)
        next if target_level.nil?

        {
          student_id: rating.student_id,
          score: rating.aggregated_level.to_f,
          advisor_entry: false,
          updated_at: rating.updated_at,
          category_id: nil,
          category_name: competency_detail_domain_lookup[competency_slug(rating.competency_title)],
          question_text: rating.competency_title,
          program_target_level: target_level,
          survey_id: nil,
          survey_title: nil,
          survey_semester: nil,
          track: rating.student&.track,
          advisor_id: rating.student&.advisor_id
        }
      end
    end

    def course_target_level_for_rating(rating)
      student = rating.student
      return nil unless student

      title = normalized_competency_title(rating.competency_title)
      program_semester_id = target_program_semester_id_for_rating(rating)
      target_from_dataset = course_target_level_from_dataset(
        student_id: student.student_id,
        competency_title: title,
        program_semester_id: program_semester_id
      )
      return target_from_dataset if target_from_dataset.present?

      fallback_course_target_level(student: student, competency_title: title, program_semester_id: program_semester_id)
    end

    def target_program_semester_id_for_rating(rating)
      rating.grade_import_batch&.program_semester_id || selected_report_program_semester&.id || ProgramSemester.current&.id
    end

    def selected_report_program_semester
      return nil if filters[:semester].blank?

      @selected_report_program_semester ||= ProgramSemester.find_by_name_case_insensitive(filters[:semester])
    end

    def course_target_level_from_dataset(student_id:, competency_title:, program_semester_id:)
      return nil if program_semester_id.blank?

      matching_rows = dataset_rows.select do |row|
        row[:student_id] == student_id &&
          row[:program_semester_id] == program_semester_id &&
          normalized_competency_title(row[:question_text]) == competency_title
      end

      average(matching_rows.map { |row| row[:program_target_level] }.compact.map(&:to_f))
    end

    def fallback_course_target_level(student:, competency_title:, program_semester_id:)
      track = target_track_key(student[:track])
      return nil if track.blank? || competency_title.blank? || program_semester_id.blank?

      records = competency_target_records_by_semester_track_and_title[[ program_semester_id, track, competency_title ]] || []
      return nil if records.blank?

      class_of = student.class_of
      program_year = student.program_year

      if class_of.present?
        exact_class = records.find { |record| record.class_of.present? && record.class_of.to_i == class_of.to_i }
        return exact_class.target_level if exact_class
      end

      class_fallback = records.find { |record| record.class_of.nil? }
      return class_fallback.target_level if class_fallback

      if program_year.present?
        exact_year = records.find { |record| record.program_year.present? && record.program_year.to_i == program_year.to_i }
        return exact_year.target_level if exact_year
      end

      year_fallback = records.find { |record| record.program_year.nil? }
      return year_fallback.target_level if year_fallback

      records.first&.target_level
    end

    def competency_target_records_by_semester_track_and_title
      @competency_target_records_by_semester_track_and_title ||= begin
        records = CompetencyTargetLevel
          .select(:program_semester_id, :track, :program_year, :class_of, :competency_title, :target_level)
          .to_a

        records.group_by do |record|
          [ record.program_semester_id, target_track_key(record.track), normalized_competency_title(record.competency_title) ]
        end
               .transform_values do |rows|
          rows.sort_by do |row|
            [
              row.class_of.present? ? 0 : 1,
              row.program_year.present? ? 0 : 1,
              row.program_semester_id || Float::INFINITY
            ]
          end
        end
      end
    end

    def competency_target_level_for_record(record)
      fallback = record.respond_to?(:program_target_level) ? record.program_target_level : nil
      return fallback unless record.respond_to?(:program_semester_id) && record.respond_to?(:student_track)

      semester_id = record.program_semester_id
      track = target_track_key(record.student_track)
      title = normalized_competency_title(record.question_text)
      class_of = record.respond_to?(:student_class_of) ? record.student_class_of : nil
      program_year = record.respond_to?(:student_program_year) ? record.student_program_year : nil

      lookup_bundle = competency_target_level_lookup_bundle

      lookup_bundle[:class_of_exact][[ semester_id, track, class_of, title ]] ||
        lookup_bundle[:class_of_exact][[ semester_id, track, nil, title ]] ||
        (class_of.nil? ? lookup_bundle[:class_of_any][[ semester_id, track, title ]] : nil) ||
        lookup_bundle[:program_year_exact][[ semester_id, track, program_year, title ]] ||
        lookup_bundle[:program_year_exact][[ semester_id, track, nil, title ]] ||
        (program_year.nil? ? lookup_bundle[:program_year_any_year][[ semester_id, track, title ]] : nil) ||
        fallback
    end

    def competency_target_level_lookup_bundle
      @competency_target_level_lookup_bundle ||= begin
        class_of_exact = {}
        class_of_any = {}
        program_year_exact = {}
        program_year_any_year = {}

        CompetencyTargetLevel
          .select(:id, :program_semester_id, :track, :program_year, :class_of, :competency_title, :target_level)
          .find_each do |row|
            semester_id = row.program_semester_id
            track = target_track_key(row.track)
            title = normalized_competency_title(row.competency_title)
            program_year = row.program_year
            class_of = row.class_of

            class_of_exact[[ semester_id, track, class_of, title ]] = row.target_level
            program_year_exact[[ semester_id, track, program_year, title ]] = row.target_level

            if class_of.present?
              any_class_key = [ semester_id, track, title ]
              existing = class_of_any[any_class_key]
              if existing.nil? || class_of.to_i < existing[:class_of]
                class_of_any[any_class_key] = { class_of: class_of.to_i, level: row.target_level }
              end
            end

            next if program_year.blank?

            any_year_key = [ semester_id, track, title ]
            existing = program_year_any_year[any_year_key]
            if existing.nil? || program_year.to_i < existing[:year]
              program_year_any_year[any_year_key] = { year: program_year.to_i, level: row.target_level }
            end
          end

        {
          class_of_exact: class_of_exact,
          class_of_any: class_of_any.transform_values { |entry| entry[:level] },
          program_year_exact: program_year_exact,
          program_year_any_year: program_year_any_year.transform_values { |entry| entry[:level] }
        }
      end
    end

    def competency_target_level_any_year_lookup
      competency_target_level_lookup_bundle[:program_year_any_year]
    end

    def sanitize_tracks(values)
      values
        .filter_map { |value| normalize_track(value) }
        .uniq { |value| value.downcase }
        .sort_by { |value| value.downcase }
    end

    def normalize_track(value)
      trimmed = value.to_s.strip
      trimmed.presence
    end

    def target_track_key(value)
      ProgramTrack.canonical_key(value) || value.to_s.strip.downcase.presence
    end

    def group_student_rows(rows)
      rows.reject { |row| row[:student_id].blank? }
          .group_by { |row| row[:student_id] }
    end

    def attainment_counts_for_group(student_rows_group, total_students: nil)
      achieved = 0
      not_met = 0

      student_rows_group.each_value do |entries|
        score_avg = average(entries.map { |row| row[:score] })
        next if score_avg.nil?

        target_levels = entries.map { |row| row[:program_target_level] }.compact.map(&:to_f)
        target_avg = average(target_levels)
        next if target_avg.nil?

        if score_avg >= target_avg
          achieved += 1
        else
          not_met += 1
        end
      end

      assessed = achieved + not_met
      total_students ||= scoped_student_ids.size
      not_assessed = [ total_students - assessed, 0 ].max

      {
        achieved_count: achieved,
        not_met_count: not_met,
        not_assessed_count: not_assessed,
        total_students: total_students
      }
    end

    def attainment_percentages(counts)
      total = counts[:total_students]
      return { achieved_percent: nil, not_met_percent: nil, not_assessed_percent: nil } if total.zero?

      {
        achieved_percent: safe_percent(counts[:achieved_count], total),
        not_met_percent: safe_percent(counts[:not_met_count], total),
        not_assessed_percent: safe_percent(counts[:not_assessed_count], total)
      }
    end

    def student_competency_averages
      @student_competency_averages ||= begin
        per_student = Hash.new { |hash, key| hash[key] = Hash.new { |inner, slug| inner[slug] = [] } }

        dataset_rows.each do |row|
          next if row[:advisor_entry]
          slug = competency_slug(row[:question_text])
          next unless slug && competency_lookup.key?(slug)

          per_student[row[:student_id]][slug] << row[:score]
        end

        per_student.transform_values do |competencies|
          competencies.transform_values { |scores| average(scores) }
        end
      end
    end

    def scoped_assignment_scope
      scope = SurveyAssignment
              .joins(:survey, :student)
              .where(student_id: accessible_student_relation.select(:student_id))

      scope = scope.where(students: { track: filters[:track] }) if filters[:track]
      scope = scope.where(students: { advisor_id: filters[:advisor_id] }) if filters[:advisor_id]
      scope = scope.where(student_id: filters[:student_id]) if filters[:student_id]
      scope = scope.where(surveys: { id: filters[:survey_id] }) if filters[:survey_id]
      if filters[:semester]
        scope = scope.joins(survey: :program_semester)
        scope = scope.where("LOWER(program_semesters.name) = ?", filters[:semester].downcase)
      end

      scope
    end

    def completed_assignment_pairs
      @completed_assignment_pairs ||= begin
        scoped_assignment_scope
          .where.not(completed_at: nil)
          .pluck(:student_id, :survey_id)
          .each_with_object({}) do |(student_id, survey_id), memo|
            key = assignment_pair_key(student_id, survey_id)
            memo[key] = true if key
          end
      end
    end

    def assignment_completed?(student_id, survey_id)
      return false if student_id.blank? || survey_id.blank?

      completed_assignment_pairs[assignment_pair_key(student_id, survey_id)] || false
    end

    def assigned_student_ids_in_scope
      @assigned_student_ids_in_scope ||= scoped_assignment_scope
                                         .distinct
                                         .pluck(:student_id)
                                         .compact
                                         .uniq
    end

    def assigned_student_count_for_survey(survey_id)
      return 0 if survey_id.blank?

      scoped_assignment_scope
        .where(survey_id: survey_id)
        .distinct
        .count(:student_id)
    end

    def assigned_student_count_for_track(track_name)
      scoped_assignment_scope
        .where(students: { track: track_name })
        .distinct
        .count(:student_id)
    end
  end
end
