# frozen_string_literal: true

# Staff-facing student overview hub. Admins see all students; advisors see only
# assigned advisees.
class StudentOverviewsController < ApplicationController
  before_action :require_staff_access!

  def index
    @filters = overview_filters
    @track_options = ProgramTrack.names
    @student_lifecycle_filter_options = Student.lifecycle_filter_options
    @program_year_options = available_program_years
    @students = filtered_students.to_a
    insights = Reports::CompetencyInsights.new(user: current_user, params: heatmap_params).call
    @student_rows = overview_rows_for(@students, competency_attainment_lookup(insights[:target_attainment]))
    @heatmap_rows = insights[:heatmap]

    render "staff/student_overviews/index"
  end

  def show
    @student = accessible_student_scope(include_historical: true).includes(:user, advisor: :user).find(params[:id])
    @overview = overview_for(@student)
    @survey_rows = survey_rows_for(@student)
    @advisor_assignment_rows = advisor_assignment_rows_for(@student)
    @competency_payload = StudentCompetencyDashboard.new(
      student: @student,
      params: { semester: StudentCompetencyDashboard::ALL_SEMESTERS_VALUE }
    ).call
    @domain_heatmap = domain_heatmap_for(@competency_payload)
    @below_target_competencies = below_target_competencies_for(@competency_payload)

    render "staff/student_overviews/show"
  end

  private

  def require_staff_access!
    return if current_user&.role_admin? || current_user&.role_advisor?

    redirect_to dashboard_path, alert: "Advisor or admin access required."
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
end
