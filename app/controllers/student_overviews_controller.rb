# frozen_string_literal: true

require "caxlsx"

# Staff-facing student overview hub. Admins see all students; advisors see only
# assigned advisees.
class StudentOverviewsController < ApplicationController
  before_action :require_staff_access!

  def index
    load_index_context

    render "staff/student_overviews/index"
  end

  def export_excel
    load_index_context
    package = build_student_overviews_workbook
    record_export_audit!(
      export_type: "student_overviews_excel",
      description: "Exported student overview workbook.",
      metadata: { student_count: @students.size }
    )

    send_data package.to_stream.read,
              filename: "student-overviews-#{Time.current.strftime('%Y%m%d-%H%M')}.xlsx",
              disposition: "attachment",
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  def show
    @student = accessible_student_scope(include_historical: true).includes(:user, advisor: :user).find(params[:id])
    @overview = overview_for(@student)
    @survey_rows = survey_rows_for(@student)
    @advisor_assignment_rows = advisor_assignment_rows_for(@student)
    @course_history_rows = course_history_rows_for(@student)
    @advisor_note_rows = advisor_note_rows_for(@student)
    @competency_payload = StudentCompetencyDashboard.new(
      student: @student,
      params: { semester: StudentCompetencyDashboard::ALL_SEMESTERS_VALUE }
    ).call
    @domain_heatmap = domain_heatmap_for(@competency_payload)
    @below_target_competencies = below_target_competencies_for(@competency_payload)

    render "staff/student_overviews/show"
  end

  def competency_history
    student = accessible_student_scope(include_historical: true).includes(:user).find(params[:id])
    exporter = StudentCompetencyHistoryExporter.new(student: student)
    record_export_audit!(
      export_type: "student_competency_history_csv",
      description: "Exported one student's competency history.",
      subject: student,
      metadata: { student_id: student.student_id }
    )

    send_data exporter.csv,
              filename: "student-#{student.student_id}-competency-history-#{Time.current.strftime('%Y%m%d-%H%M')}.csv",
              disposition: "attachment",
              type: "text/csv"
  end

  private

  def load_index_context
    @filters = overview_filters
    @track_options = ProgramTrack.names
    @student_lifecycle_filter_options = Student.lifecycle_filter_options
    @program_year_options = available_program_years
    @students = filtered_students.to_a
    insights = Reports::CompetencyInsights.new(user: current_user, params: heatmap_params).call
    @student_rows = overview_rows_for(@students, competency_attainment_lookup(insights[:target_attainment]))
    @heatmap_rows = insights[:heatmap]
  end

  def require_staff_access!
    return if current_user&.role_admin? || current_user&.role_advisor?

    redirect_to dashboard_path, alert: "Advisor or admin access is required to open this page."
  end

  def overview_filters
    {
      q: params[:q].to_s.strip,
      track: normalize_track(params[:track]),
      program_year: normalize_program_year(params[:program_year]),
      student_status: Student.normalize_lifecycle_filter(params[:student_status])
    }
  end

  def heatmap_params
    {
      q: @filters[:q],
      track: @filters[:track],
      program_year: @filters[:program_year],
      student_status: @filters[:student_status]
    }.compact_blank
  end

  def filtered_students
    scope = accessible_student_scope(include_historical: true)
      .with_lifecycle_filter(@filters[:student_status])
      .includes(:user, advisor: :user)
      .left_outer_joins(:user)

    if @filters[:q].present?
      term = "%#{ActiveRecord::Base.sanitize_sql_like(@filters[:q])}%"
      scope = scope.where(
        "users.name ILIKE :term OR users.email ILIKE :term OR students.uin ILIKE :term OR CAST(students.student_id AS TEXT) ILIKE :term",
        term: term
      )
    end

    scope = scope.where("LOWER(students.track) = ?", ProgramTrack.canonical_key(@filters[:track])) if @filters[:track].present?
    scope = scope.where(program_year: @filters[:program_year]) if @filters[:program_year].present?

    scope.order(Arel.sql("LOWER(COALESCE(users.name, users.email, '')) ASC"), :student_id)
  end

  def accessible_student_scope(include_historical: false)
    scope = if current_user&.role_admin?
      Student.all
    elsif current_user&.role_advisor? && current_advisor_profile.present?
      Student.where(advisor_id: current_advisor_profile.advisor_id)
    else
      Student.none
    end

    include_historical ? scope : scope.current_records
  end

  def available_program_years
    accessible_student_scope(include_historical: true)
      .with_lifecycle_filter(@filters[:student_status])
      .where.not(program_year: nil)
      .distinct
      .order(program_year: :desc)
      .pluck(:program_year)
      .map(&:to_s)
  end

  def overview_rows_for(students, competency_attainment_by_student = {})
    student_ids = students.map(&:student_id)
    assignments = SurveyAssignment.where(student_id: student_ids)
    assignment_counts = assignments.group(:student_id).count
    completed_counts = assignments.where.not(completed_at: nil).group(:student_id).count

    students.map do |student|
      assigned = assignment_counts[student.student_id].to_i
      completed = completed_counts[student.student_id].to_i

      {
        student: student,
        assigned_count: assigned,
        completed_count: completed,
        completion_rate: assigned.positive? ? ((completed.to_f / assigned) * 100).round : nil,
        competency_attainment: competency_attainment_by_student.fetch(
          student.student_id,
          { met_count: 0, total_count: Reports::DataAggregator::COMPETENCY_TITLES.size }
        )
      }
    end
  end

  def competency_attainment_lookup(rows)
    Array(rows).index_by { |row| row[:student_id] }
  end

  def overview_for(student)
    assignments = SurveyAssignment.where(student_id: student.student_id)
    completed = assignments.where.not(completed_at: nil).count
    assigned = assignments.count
    latest_response_at = StudentQuestion.where(student_id: student.student_id).maximum(:updated_at)
    latest_feedback_at = Feedback.where(student_id: student.student_id).maximum(:updated_at)
    latest_course_at = GradeCompetencyEvidence.where(student_id: student.student_id).maximum(:updated_at)

    {
      assigned_count: assigned,
      completed_count: completed,
      completion_rate: assigned.positive? ? ((completed.to_f / assigned) * 100).round : nil,
      feedback_count: Feedback.where(student_id: student.student_id).count,
      course_evidence_count: GradeCompetencyEvidence.where(student_id: student.student_id).count,
      course_count: GradeCompetencyEvidence.where(student_id: student.student_id).distinct.count(:course_code),
      latest_activity_at: [ latest_response_at, latest_feedback_at, latest_course_at ].compact.max
    }
  end

  def advisor_assignment_rows_for(student)
    student.advisor_assignments
      .includes(:assigned_by, advisor: :user)
      .ordered
      .limit(5)
      .map do |assignment|
        {
          advisor_name: assignment.advisor&.display_name || "Unassigned",
          starts_on: assignment.starts_on,
          ends_on: assignment.ends_on,
          current: assignment.current?,
          assigned_by_name: assignment.assigned_by&.display_name || assignment.assigned_by&.email
        }
      end
  end

  def course_history_rows_for(student)
    GradeCompetencyEvidence
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .includes(:grade_import_file, grade_import_batch: :program_semester)
      .where(student_id: student.student_id)
      .order(Arel.sql("grade_import_batches.created_at DESC"), :course_code, :competency_title)
      .limit(12)
      .map do |evidence|
        {
          semester: evidence.grade_import_batch&.program_semester&.name || "No semester",
          course_code: evidence.course_code,
          competency_title: evidence.competency_title,
          assessed_level: evidence.mapped_level,
          target_level: evidence.course_target_level,
          target_status: GradeImports::TargetAttainmentReport.ui_label(evidence.mapped_level, evidence.course_target_level),
          source_file: evidence.grade_import_file&.file_name,
          updated_at: evidence.updated_at
        }
      end
  end

  def advisor_note_rows_for(student)
    ConfidentialAdvisorNote
      .includes(:survey, advisor: :user)
      .where(student_id: student.student_id)
      .order(updated_at: :desc)
      .limit(6)
      .map do |note|
        {
          advisor_name: note.advisor&.display_name || "Advisor",
          survey_title: note.survey&.title || "Survey",
          body: note.body,
          updated_at: note.updated_at
        }
      end
  end

  def survey_rows_for(student)
    assignments = SurveyAssignment
      .includes(survey: :program_semester)
      .where(student_id: student.student_id)
      .where.not(completed_at: nil)
      .order(completed_at: :desc)
      .to_a

    survey_ids = assignments.map(&:survey_id)
    response_updates = StudentQuestion
      .joins(question: :category)
      .where(student_id: student.student_id, categories: { survey_id: survey_ids })
      .group("categories.survey_id")
      .maximum("student_questions.updated_at")
    feedback_counts = Feedback.where(student_id: student.student_id, survey_id: survey_ids).group(:survey_id).count

    assignments.map do |assignment|
      survey_response = SurveyResponse.build(student: student, survey: assignment.survey)

      {
        survey: assignment.survey,
        semester: assignment.survey&.semester.presence || assignment.survey&.program_semester&.name.presence || "Unscheduled",
        status: assignment_status(assignment),
        assigned_at: assignment.assigned_at,
        completed_at: assignment.completed_at,
        available_until: assignment.effective_available_until,
        last_response_at: response_updates[assignment.survey_id],
        feedback_count: feedback_counts[assignment.survey_id].to_i,
        survey_response: survey_response,
        download_token: survey_response.signed_download_token
      }
    end
  end

  def assignment_status(assignment)
    return "Completed" if assignment.completed_at.present?
    return "Overdue" if assignment.overdue?

    "Assigned"
  end

  def domain_heatmap_for(payload)
    payload[:domains].map do |domain|
      course_average = domain.dig(:averages, :course)
      self_average = domain.dig(:averages, :self)
      value = course_average || self_average

      {
        name: domain[:name],
        average: value,
        source: course_average.present? ? "Course" : "Self",
        status: heatmap_status(value)
      }
    end
  end

  def below_target_competencies_for(payload)
    payload[:domains].flat_map do |domain|
      domain[:competencies].filter_map do |competency|
        next unless competency[:self_below_target] || competency[:course_below_target]

        {
          domain: domain[:name],
          title: competency[:title],
          self_rating: competency[:self_rating],
          course_rating: competency[:course_rating],
          target: competency[:end_program_target]
        }
      end
    end
  end

  def heatmap_status(value)
    return "missing" if value.blank?
    return "strong" if value.to_f >= 4.0
    return "watch" if value.to_f >= 3.0

    "attention"
  end

  def normalize_track(value)
    ProgramTrack.name_for_key(ProgramTrack.canonical_key(value)).presence
  end

  def normalize_program_year(value)
    normalized = value.to_s.strip
    return if normalized.blank?
    return normalized if normalized.match?(/\A\d{4}\z/)

    nil
  end

  def build_student_overviews_workbook
    package = Axlsx::Package.new
    workbook = package.workbook

    add_student_overview_students_sheet(workbook)
    add_student_overview_heatmap_sheet(workbook)
    add_student_overview_filters_sheet(workbook)

    package
  end

  def add_student_overview_students_sheet(workbook)
    workbook.add_worksheet(name: "Students") do |sheet|
      sheet.add_row [ "Student Overview Export" ]
      sheet.add_row [ "Generated At", Time.current.iso8601 ]
      sheet.add_row []
      sheet.add_row [
        "Student",
        "Email",
        "UIN",
        "Track",
        "Year",
        "Status",
        "Advisor",
        "Assigned Surveys",
        "Completed Surveys",
        "Survey Completion Rate",
        "Competencies Meeting Target",
        "Competencies Total"
      ]

      Array(@student_rows).each do |row|
        student = row[:student]
        attainment = row[:competency_attainment] || {}

        sheet.add_row [
          student&.user&.display_name || student&.student_id,
          student&.user&.email,
          student&.uin,
          student&.track,
          student&.program_year,
          student&.lifecycle_label,
          student&.advisor&.display_name || "Unassigned",
          row[:assigned_count],
          row[:completed_count],
          row[:completion_rate],
          attainment[:met_count],
          attainment[:total_count]
        ]
      end
    end
  end

  def add_student_overview_heatmap_sheet(workbook)
    domain_names = Array(@heatmap_rows).first&.dig(:domains)&.map { |domain| domain[:name] }
    domain_names = Reports::DataAggregator::REPORT_DOMAINS if domain_names.blank?

    workbook.add_worksheet(name: "Domain Heatmap") do |sheet|
      sheet.add_row [ "Student Domain Heatmap" ]
      sheet.add_row [ "Generated At", Time.current.iso8601 ]
      sheet.add_row []
      sheet.add_row [ "Student", "Track", "Year", *domain_names ]

      Array(@heatmap_rows).each do |row|
        domain_lookup = Array(row[:domains]).index_by { |domain| domain[:name] }

        sheet.add_row [
          row[:student_name],
          row[:track],
          row[:program_year],
          *domain_names.map { |domain_name| domain_lookup.dig(domain_name, :average) }
        ]
      end
    end
  end

  def add_student_overview_filters_sheet(workbook)
    workbook.add_worksheet(name: "Filters") do |sheet|
      sheet.add_row [ "Filter", "Value" ]
      student_overview_export_filters.each do |label, value|
        sheet.add_row [ label, value ]
      end
    end
  end

  def student_overview_export_filters
    [
      [ "Search students", @filters[:q].presence || "All students" ],
      [ "Track", @filters[:track].presence || "All tracks" ],
      [ "Program year", @filters[:program_year].presence || "All years" ],
      [ "Student status", @filters[:student_status].presence || "Active" ]
    ]
  end
end
