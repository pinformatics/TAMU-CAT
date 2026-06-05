require "caxlsx"

# Provides survey-focused completion and advisor-feedback rollups across
# students for staff members (advisors and admins).
class StudentRecordsController < ApplicationController
  before_action :require_staff_access!

  # Displays student survey completion matrices grouped by semester/survey.
  #
  # @return [void]
  def index
    load_index_context
    flash.now[:notice] = "Canceled feedback editing." if params[:cancelled_feedback].to_s == "1"
  end

  # Exports Survey Records as an Excel workbook with one worksheet per survey.
  #
  # @return [void]
  def export_excel
    load_index_context

    package = build_student_records_workbook(@student_records)
    record_export_audit!(
      export_type: "survey_records_excel",
      description: "Exported survey records Excel workbook.",
      metadata: { student_count: @students.size, filters: student_records_export_filters.to_h }
    )
    send_data package.to_stream.read,
              filename: "survey-records-#{Time.current.strftime('%Y%m%d-%H%M%S')}.xlsx",
              disposition: "attachment",
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  private

  def load_index_context
    @search_query = params[:q].to_s.strip
    @survey_query = params[:survey_query].to_s.strip
    @survey_filter_id = params[:survey_id].to_s.strip.presence
    @semester_filter = params[:semester].to_s.strip.presence
    @track_filter = normalize_track_filter(params[:track])
    @program_year_filter = normalize_program_year_filter(params[:program_year])
    @student_lifecycle_filter = Student.normalize_lifecycle_filter(params[:student_status])
    @status_filter = normalize_status_filter(params[:status])
    @sort_key = normalize_sort_key(params[:sort])

    @survey_filter_options = survey_filter_scope
                             .map do |survey|
      label = [ survey.title.to_s, survey.semester.to_s.presence ].compact.join(" · ")
      [ label, survey.id ]
    end

    @semester_filter_options = ProgramSemester.ordered.pluck(:name).compact
    @track_filter_options = ProgramTrack.names
    @student_lifecycle_filter_options = Student.lifecycle_filter_options
    @program_year_options = available_program_years

    @students = load_students
    @student_records = build_student_records(@students)
  end

  # Ensures only advisors and admins can access survey records.
  #
  # @return [void]
  def require_staff_access!
    return if current_user&.role_admin? || current_user&.role_advisor?

    redirect_to dashboard_path, alert: STAFF_ONLY_MESSAGE
  end

  # Loads students accessible to the current staff member.
  #
  # @return [ActiveRecord::Relation<Student>]
  def load_students
    scope = base_student_scope.with_lifecycle_filter(@student_lifecycle_filter)

    scope = scope
            .left_joins(:user)
            .includes(:user, advisor: :user)

    if @track_filter.present?
      scope = scope.where(track: @track_filter)
    end

    if @program_year_filter.present?
      scope = scope.where(program_year: @program_year_filter.to_i)
    end

    if @search_query.present?
      lowered_query = @search_query.downcase
      query_like = "%#{ActiveRecord::Base.sanitize_sql_like(lowered_query)}%"

      scope = scope.where(
        "LOWER(users.name) LIKE :q OR LOWER(users.email) LIKE :q OR CAST(students.uin AS TEXT) LIKE :q",
        q: query_like
      )
    end

    scope.order(Arel.sql("LOWER(users.name) ASC"))
  end

  # Builds a nested data structure summarizing survey completion for each
  # student.
  #
  # @param students [Enumerable<Student>]
  # @return [Array<Hash>]
  def build_student_records(students)
    return [] if students.blank?

    student_ids = students.map(&:student_id)

    surveys = filtered_surveys
    return [] if surveys.blank?

    survey_ids = surveys.map(&:id)

    feedback_lookup = load_feedback_lookup(student_ids, survey_ids)
    assignments_lookup = load_assignment_lookup(student_ids, survey_ids)
    admin_update_lookup = load_admin_update_lookup(student_ids, survey_ids)
    feedback_submission_lookup = load_feedback_submission_lookup(student_ids, survey_ids)
    employment_lookup = load_employment_export_lookup(student_ids, survey_ids)
    responses_matrix = Hash.new do |hash, student_id|
      hash[student_id] = Hash.new { |inner, survey_id| inner[survey_id] = [] }
    end

    StudentQuestion
      .joins(question: :category)
      .where(student_id: student_ids, categories: { survey_id: survey_ids })
      .select("student_questions.id, student_questions.student_id, categories.survey_id, student_questions.question_id, student_questions.updated_at")
      .find_each do |record|
        responses_matrix[record.student_id][record.survey_id] << {
          question_id: record.question_id,
          updated_at: record.updated_at
        }
      end

    grouped = surveys.group_by(&:semester)

    sorted_semesters = grouped.keys.sort_by { |sem| semester_sort_key(sem) }.reverse

    sorted_semesters.map do |semester|
      {
        semester: semester.presence || "Unscheduled",
        surveys: grouped[semester].map do |survey|
          students_for_survey = filter_students_for_survey(students, survey)
          {
            survey: survey,
            rows: begin
              rows = students_for_survey.filter_map do |student|
                responses = responses_matrix[student.student_id][survey.id]
                answered_ids = responses.map { |entry| entry[:question_id] }.uniq
                survey_response = SurveyResponse.build(student: student, survey: survey)

                feedbacks_for_pair = Array(feedback_lookup.dig(student.student_id, survey.id))
                feedback_last_updated = feedbacks_for_pair.filter_map(&:updated_at).max
                feedback_submission = feedback_submission_lookup[[ student.student_id, survey.id ]]
                feedback_status_label, feedback_status_timestamp = feedback_status_for_row(
                  feedbacks_for_pair: feedbacks_for_pair,
                  feedback_last_updated: feedback_last_updated,
                  feedback_submission: feedback_submission
                )

                assignment = assignments_lookup.dig(student.student_id, survey.id)
                next if assignment.nil?

                assigned_at = assignment&.created_at
                completed_at = assignment&.completed_at
                available_until = assignment&.available_until
                status_text = if completed_at.present?
                  "Completed"
                else
                  "Assigned"
                end

                {
                  student: student,
                  advisor: student.advisor,
                  status: status_text,
                  assigned_at: assigned_at,
                  completed_at: completed_at,
                  available_until: available_until,
                  admin_updated_at: admin_update_lookup[[ student.student_id, survey.id ]],
                  survey: survey,
                  survey_response: survey_response,
                  download_token: survey_response.signed_download_token,
                  feedbacks: feedbacks_for_pair,
                  feedback_last_updated_at: feedback_last_updated,
                  feedback_status_label: feedback_status_label,
                  feedback_status_timestamp: feedback_status_timestamp,
                  employment_data: employment_lookup.fetch(
                    [ student.student_id, survey.id ],
                    default_employment_export_data
                  )
                }
              end

              if @status_filter.present?
                rows = rows.select { |row| row[:status].to_s.downcase == @status_filter }
              end

              sort_student_record_rows(rows)
            end
          }
        end
      }
    end.reject { |block| block[:surveys].blank? }
  end

  def filtered_surveys
    scope = survey_filter_scope.includes(:questions, :track_assignments)

    if @survey_filter_id.present?
      scope = scope.where(id: @survey_filter_id)
    end

    scope
  end

  def survey_filter_scope
    scope = Survey
            .includes(:program_semester, :track_assignments)
            .order(created_at: :desc)

    if @semester_filter.present?
      scope = scope.left_joins(:program_semester).where(program_semesters: { name: @semester_filter })
    end

    if @survey_query.present?
      scope = scope.where("LOWER(surveys.title) LIKE ?", sanitized_search_pattern(@survey_query))
    end

    scope.distinct
  end

  def filter_students_for_survey(students, survey)
    students
  end

  def survey_track_keys(survey)
    track_values = if survey.respond_to?(:track_list)
      survey.track_list
    else
      []
    end

    keys = Array(track_values)
           .compact
           .map { |value| ProgramTrack.canonical_key(value) }
           .compact
           .uniq
    return keys if keys.any?

    legacy_key = ProgramTrack.canonical_key(survey&.track)
    return [ legacy_key ] if legacy_key.present?

    title = survey&.title.to_s.downcase
    return [ "executive" ] if title.include?("executive")
    return [ "residential" ] if title.include?("residential")

    []
  end

  def normalize_status_filter(value)
    normalized = value.to_s.strip.downcase
    return nil if normalized.blank? || normalized == "all"

    return "completed" if normalized == "completed"
    return "assigned" if normalized == "assigned"
    return "unassigned" if normalized == "unassigned"

    nil
  end

  def normalize_sort_key(value)
    normalized = value.to_s.strip.downcase
    return "name_asc" if normalized.blank? || normalized == "default"

    allowed = %w[
      name_asc
      name_desc
      status
      due_asc
      due_desc
      completed_desc
      track
      program_year_asc
      program_year_desc
    ]

    allowed.include?(normalized) ? normalized : "name_asc"
  end

  def normalize_track_filter(value)
    key = ProgramTrack.canonical_key(value)
    name = ProgramTrack.name_for_key(key)
    name.presence
  end

  def normalize_program_year_filter(value)
    normalized = value.to_s.strip
    return nil if normalized.blank?
    return normalized if normalized.match?(/\A\d{4}\z/)

    nil
  end

  def sort_student_record_rows(rows)
    return rows if rows.blank?

    case @sort_key
    when "name_desc"
      rows.sort_by { |row| row_student_name(row) }.reverse
    when "status"
      rows.sort_by do |row|
        [ status_sort_value(row[:status]), row_student_name(row) ]
      end
    when "track"
      rows.sort_by do |row|
        [ row_track(row), row_student_name(row) ]
      end
    when "program_year_asc"
      rows.sort_by do |row|
        year = row_program_year(row)
        [ year || Float::INFINITY, row_student_name(row) ]
      end
    when "program_year_desc"
      rows.sort_by do |row|
        year = row_program_year(row)
        [ year ? -year : Float::INFINITY, row_student_name(row) ]
      end
    when "due_asc"
      rows.sort_by do |row|
        [ row[:available_until].presence || Time.utc(3000, 1, 1), row_student_name(row) ]
      end
    when "due_desc"
      rows.sort_by do |row|
        [ row[:available_until].presence || Time.utc(0, 1, 1), row_student_name(row) ]
      end.reverse
    when "completed_desc"
      rows.sort_by do |row|
        [ row[:completed_at].presence || Time.utc(0, 1, 1), row_student_name(row) ]
      end.reverse
    else
      rows.sort_by { |row| row_student_name(row) }
    end
  end

  def row_student_name(row)
    student = row[:student]
    student&.user&.name.to_s.downcase
  end

  def row_track(row)
    student = row[:student]
    label = student&.track.to_s.strip
    normalized = normalize_track_filter(label)
    normalized.to_s.downcase.presence || "zzzz"
  end

  def row_program_year(row)
    student = row[:student]
    return nil unless student

    value = if student.respond_to?(:program_year) && student.program_year.present?
      student.program_year
    elsif student.respond_to?(:[]) && student[:class_of].present?
      student[:class_of]
    end

    value.to_i.nonzero? ? value.to_i : nil
  end

  def status_sort_value(status)
    case status.to_s.downcase
    when "completed" then 0
    when "assigned" then 1
    when "unassigned" then 2
    else 3
    end
  end

  def base_student_scope
    user = current_user
    has_admin_privileges = user&.role_admin?

    if has_admin_privileges
      Student.all
    elsif current_advisor_profile.present?
      Student.where(advisor_id: current_advisor_profile.advisor_id)
    else
      Student.none
    end
  end

  def available_program_years
    base_student_scope
      .with_lifecycle_filter(@student_lifecycle_filter)
      .where.not(program_year: nil)
      .distinct
      .order(program_year: :desc)
      .pluck(:program_year)
      .map(&:to_s)
  end

  def sanitized_search_pattern(value)
    pattern = ActiveRecord::Base.sanitize_sql_like(value.to_s.downcase)
    "%#{pattern}%"
  end

  # Produces a sortable key for semester labels (e.g., "Fall 2024").
  #
  # @param semester [String, nil]
  # @return [Array<Integer>]
  def semester_sort_key(semester)
    return [ 0, 0 ] if semester.blank?

    term, year = semester.to_s.split
    year_value = year.to_i
    term_value = case term&.downcase
    when "spring" then 1
    when "summer" then 2
    when "fall" then 3
    else 0
    end

    [ year_value, term_value ]
  end

  # Determines whether a question counts toward completion metrics.
  #
  # @param question [Question, nil]
  # @return [Boolean]
  def required_question?(question)
    return false unless question

    SurveyQuestionRules.required_indicator?(question, branch_parent_ids: [])
  end

  # Preloads feedback entries for the provided student and survey ids.
  #
  # @param student_ids [Array<Integer>]
  # @param survey_ids [Array<Integer>]
  # @return [Hash{Integer=>Hash{Integer=>Array<Feedback>}}]
  def load_feedback_lookup(student_ids, survey_ids)
    return {} if student_ids.blank? || survey_ids.blank?

    Feedback
      .includes(:category, advisor: :user)
      .where(student_id: student_ids, survey_id: survey_ids)
      .each_with_object(Hash.new { |hash, sid| hash[sid] = {} }) do |feedback, memo|
        memo[feedback.student_id][feedback.survey_id] ||= []
        memo[feedback.student_id][feedback.survey_id] << feedback
      end
      .tap do |lookup|
        lookup.each_value do |survey_hash|
          survey_hash.each_value do |entries|
            entries.sort_by! do |feedback|
              [
                feedback.category&.name.to_s.downcase,
                feedback.category_id || 0,
                feedback.id || 0
              ]
            end
          end
        end
      end
  end

  # Preloads survey assignments for the provided student/survey pairs.
  #
  # @param student_ids [Array<Integer>]
  # @param survey_ids [Array<Integer>]
  # @return [Hash{Integer=>Hash{Integer=>SurveyAssignment}}]
  def load_assignment_lookup(student_ids, survey_ids)
    return {} if student_ids.blank? || survey_ids.blank?

    SurveyAssignment
      .where(student_id: student_ids, survey_id: survey_ids)
      .each_with_object(Hash.new { |hash, sid| hash[sid] = {} }) do |assignment, memo|
        memo[assignment.student_id][assignment.survey_id] = assignment
      end
  end

  def load_admin_update_lookup(student_ids, survey_ids)
    return {} if student_ids.blank? || survey_ids.blank?

    SurveyResponseVersion
      .where(student_id: student_ids, survey_id: survey_ids, event: %w[admin_edited admin_deleted])
      .group(:student_id, :survey_id)
      .maximum(:created_at)
  end

  def load_feedback_submission_lookup(student_ids, survey_ids)
    return {} if student_ids.blank? || survey_ids.blank?

    AdvisorFeedbackSubmission
      .where(student_id: student_ids, survey_id: survey_ids)
      .order(updated_at: :desc)
      .each_with_object({}) do |submission, memo|
        key = [ submission.student_id, submission.survey_id ]
        memo[key] ||= submission
      end
  end

  def load_employment_export_lookup(student_ids, survey_ids)
    return {} if student_ids.blank? || survey_ids.blank?

    StudentQuestion
      .joins(question: :category)
      .includes(question: :category)
      .where(student_id: student_ids, categories: { survey_id: survey_ids })
      .where("LOWER(categories.name) LIKE ?", "%employment%")
      .each_with_object({}) do |response, memo|
        question = response.question
        category = question&.category
        survey_id = category&.survey_id
        field_key = employment_field_key_for(question&.question_text)

        next if survey_id.blank? || field_key.blank?

        key = [ response.student_id, survey_id ]
        memo[key] ||= default_employment_export_data

        formatted_value = format_employment_answer(response)
        next if formatted_value.blank?

        memo[key][field_key] = formatted_value
      end
  end

  def feedback_status_for_row(feedbacks_for_pair:, feedback_last_updated:, feedback_submission:)
    if feedback_submission&.submitted_at.present?
      return [ "Submitted", feedback_submission.submitted_at ]
    end

    has_any_feedback_data = feedbacks_for_pair.any? do |feedback|
      feedback.average_score.present? || feedback.comments.present?
    end

    has_any_draft = has_any_feedback_data || feedback_submission.present?
    return [ "No Feedback", nil ] unless has_any_draft

    [ "Draft", feedback_last_updated || feedback_submission&.last_saved_at ]
  end

  def build_student_records_workbook(student_records)
    package = Axlsx::Package.new
    workbook = package.workbook
    used_sheet_names = {}
    worksheet_count = 0

    Array(student_records).each do |semester_block|
      semester_name = semester_block[:semester]

      Array(semester_block[:surveys]).each do |survey_block|
        survey = survey_block[:survey]
        rows = Array(survey_block[:rows])
        base_name = survey.title.to_s.strip.presence || "Survey #{survey.id}"
        sheet_name = unique_worksheet_name(base_name, used_sheet_names)
        worksheet_count += 1

        workbook.add_worksheet(name: sheet_name) do |sheet|
          sheet.add_row [ "Survey", survey.title ]
          sheet.add_row [ "Semester", semester_name ]
          sheet.add_row []
          sheet.add_row [
            "Student",
            "Student Email",
            "UIN",
            "Advisor",
            "Track",
            "Program Year",
            "Employment Status",
            "Employer (Name and Address)",
            "Job Title",
            "Avg Hours/Week",
            "Work Schedule Flexibility",
            "Survey Status",
            "Completed At",
            "Feedback Status",
            "Feedback Updated At"
          ]

          rows.each do |row|
            student = row[:student]
            advisor = row[:advisor]
            employment_data = row[:employment_data] || {}

            sheet.add_row [
              student&.user&.name,
              student&.user&.email,
              student&.uin,
              advisor&.name,
              student&.track,
              row_program_year(row),
              employment_data[:currently_employed],
              employment_data[:employer],
              employment_data[:job_title],
              employment_data[:hours_per_week],
              employment_data[:work_schedule_flexibility],
              row[:status],
              row[:completed_at]&.iso8601,
              row[:feedback_status_label],
              row[:feedback_status_timestamp]&.iso8601
            ]
          end
        end
      end
    end

    add_empty_student_records_sheet(workbook) if worksheet_count.zero?

    package
  end

  def add_empty_student_records_sheet(workbook)
    workbook.add_worksheet(name: "Survey Records") do |sheet|
      sheet.add_row [ "Survey Records Export" ]
      sheet.add_row [ "Generated At", Time.current.iso8601 ]
      sheet.add_row [ "Result", "No survey records matched the current filters." ]
      sheet.add_row []
      sheet.add_row [ "Filter", "Value" ]
      student_records_export_filters.each do |label, value|
        sheet.add_row [ label, value ]
      end
    end
  end

  def student_records_export_filters
    [
      [ "Search students", @search_query.presence || "All students" ],
      [ "Search surveys", @survey_query.presence || "All surveys" ],
      [ "Survey", @survey_filter_id.presence || "All surveys" ],
      [ "Semester", @semester_filter.presence || "All semesters" ],
      [ "Status", @status_filter.presence&.titleize || "All statuses" ],
      [ "Track", @track_filter.presence || "All tracks" ],
      [ "Program year", @program_year_filter.presence || "All years" ],
      [ "Student status", @student_lifecycle_filter.presence || "Active" ]
    ]
  end

  def unique_worksheet_name(base_name, used_sheet_names)
    cleaned = base_name.gsub(/[\[\]\:\*\?\/\\]/, " ").squish
    cleaned = "Sheet" if cleaned.blank?
    cleaned = cleaned[0, 31]

    return cleaned.tap { used_sheet_names[cleaned] = true } unless used_sheet_names[cleaned]

    suffix = 2
    loop do
      suffix_text = " (#{suffix})"
      prefix_limit = 31 - suffix_text.length
      candidate = "#{cleaned[0, prefix_limit]}#{suffix_text}"
      unless used_sheet_names[candidate]
        used_sheet_names[candidate] = true
        return candidate
      end
      suffix += 1
    end
  end

  def default_employment_export_data
    {
      currently_employed: nil,
      employer: nil,
      job_title: nil,
      hours_per_week: nil,
      work_schedule_flexibility: nil
    }
  end

  def employment_field_key_for(question_text)
    normalized = question_text.to_s.downcase
    return :currently_employed if normalized.include?("currently employed")
    return :employer if normalized.include?("where are you employed")
    return :job_title if normalized.include?("what is your title")
    return :hours_per_week if normalized.include?("hours per week")
    return :work_schedule_flexibility if normalized.include?("flexible are your work hours")

    nil
  end

  def format_employment_answer(response)
    question = response.question
    answer = response.answer
    return nil if answer.blank?

    case answer
    when Hash
      selected_value = answer["answer"] || answer[:answer] || answer["value"] || answer[:value] || answer["rating"] || answer[:rating]
      selected_text = employment_choice_label(question, selected_value)
      other_text = (answer["text"] || answer[:text] || answer["other_text"] || answer[:other_text]).to_s.strip

      if other_text.present?
        return other_text if selected_text.blank? || selected_text.casecmp?("Other") || selected_value.to_s == "0"

        return "#{selected_text}: #{other_text}"
      end

      selected_text.presence || selected_value.to_s.strip.presence
    when Array
      answer.filter_map { |entry| entry.to_s.strip.presence }.join(", ").presence
    else
      raw_text = answer.to_s.strip
      return nil if raw_text.blank?

      employment_choice_label(question, raw_text).presence || raw_text
    end
  end

  def employment_choice_label(question, value)
    text = value.to_s.strip
    return nil if text.blank?
    return text unless question&.choice_question?

    question
      .answer_option_pairs
      .find { |(_label, pair_value)| pair_value.to_s == text }
      &.first
      &.to_s
      &.strip
      .presence || text
  end
end
