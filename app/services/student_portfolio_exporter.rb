# frozen_string_literal: true

require "caxlsx"

class StudentPortfolioExporter
  PORTFOLIO_QUESTION_TEXT = "Please provide a link to your MHA Portfolio (Google Sites) as evidence for this survey."

  def initialize(actor_user:, params: {})
    @actor_user = actor_user
    @params = params.to_h.with_indifferent_access
  end

  def students
    @students ||= begin
      scope = base_scope.includes(:user, advisor: :user).left_outer_joins(:user)
      if params[:q].present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.strip)}%"
        scope = scope.where("users.name ILIKE :term OR users.email ILIKE :term OR students.uin ILIKE :term", term: term)
      end
      if params[:track].present?
        track_key = ProgramTrack.canonical_key(params[:track])
        scope = scope.where("LOWER(students.track) = ?", track_key) if track_key.present?
      end
      scope = scope.where(program_year: params[:program_year]) if params[:program_year].present?
      scope.order(Arel.sql("LOWER(COALESCE(users.name, users.email, '')) ASC"), :student_id)
    end
  end

  def rows
    @rows ||= begin
      answers = latest_portfolio_answers
      summaries = competency_summaries_by_student
      students.map do |student|
        answer = answers[student.student_id]
        competency_summary = summaries.fetch(student.student_id, empty_competency_summary)
        {
          student_id: student.student_id,
          name: student.user&.display_name,
          email: student.user&.email,
          uin: student.uin,
          track: student.track,
          program_year: student.program_year,
          year: student.program_year,
          cohort: student.program_year,
          advisor: student.advisor&.display_name,
          portfolio_url: answer&.response_value,
          submitted_at: answer&.updated_at
        }.merge(competency_summary)
      end
    end
  end

  def competency_summaries_by_student
    @competency_summaries_by_student ||= grouped_evidence.transform_values do |evidence_rows|
      statuses = evidence_rows.map { |row| GradeImports::TargetAttainmentReport.status_for(row.mapped_level, row.course_target_level) }
      denominator = statuses.count(:met) + statuses.count(:below_target)
      latest_row = evidence_rows.max_by(&:updated_at)

      {
        latest_course_semester: latest_row&.grade_import_batch&.program_semester&.name,
        course_count: evidence_rows.map(&:course_code).compact_blank.uniq.size,
        course_evidence_count: evidence_rows.size,
        course_competency_count: evidence_rows.map(&:competency_title).compact_blank.uniq.size,
        target_met_count: statuses.count(:met),
        below_target_count: statuses.count(:below_target),
        no_target_count: statuses.count(:no_target),
        target_met_rate: denominator.positive? ? ((statuses.count(:met).to_f / denominator) * 100).round(1) : nil
      }
    end
  end

  def workbook
    package = Axlsx::Package.new
    formatter = Exports::XlsxFormatter.new(package.workbook)

    package.workbook.add_worksheet(name: "Student Profile") do |sheet|
      header_row = formatter.add_header_row(sheet, workbook_headers)
      rows.each do |row|
        formatter.add_data_row(sheet, [
          row[:uin].to_s,
          row[:name],
          row[:email],
          row[:track],
          row[:year],
          row[:advisor],
          row[:portfolio_url],
          row[:submitted_at],
          row[:latest_course_semester],
          row[:course_count],
          row[:course_evidence_count],
          row[:course_competency_count],
          row[:target_met_count],
          row[:below_target_count],
          row[:no_target_count],
          row[:target_met_rate]
        ], types: workbook_types)
      end

      formatter.finish_table(
        sheet,
        header_row: header_row,
        column_count: workbook_headers.size,
        widths: [ 14, 24, 30, 18, 10, 24, 42, 22, 22, 16, 18, 18, 18, 18, 16, 18 ]
      )
    end
    package
  end

  private

  attr_reader :actor_user, :params

  def base_scope
    if actor_user&.role_advisor?
      Student.where(advisor_id: actor_user.advisor_profile&.advisor_id)
    else
      Student.all
    end
  end

  def latest_portfolio_answers
    student_ids = students.map(&:student_id)
    return {} if student_ids.empty?

    StudentQuestion
      .joins(:question)
      .where(student_id: student_ids, questions: { question_text: PORTFOLIO_QUESTION_TEXT })
      .select("student_questions.*")
      .order("student_questions.student_id ASC, student_questions.updated_at DESC, student_questions.id DESC")
      .each_with_object({}) do |answer, lookup|
        lookup[answer.student_id] ||= answer
      end
  end

  def grouped_evidence
    student_ids = students.map(&:student_id)
    return {} if student_ids.empty?

    GradeCompetencyEvidence
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .includes(grade_import_batch: :program_semester)
      .where(student_id: student_ids)
      .to_a
      .group_by(&:student_id)
  end

  def workbook_headers
    [
      "UIN",
      "Name",
      "Email",
      "Track",
      "Year",
      "Advisor",
      "Google Sites URL",
      "Submitted At",
      "Latest Course Semester",
      "Courses With Evidence",
      "Course Evidence Rows",
      "Course Competencies",
      "Course Targets Met",
      "Below Course Target",
      "No Course Target",
      "Course Target Met Rate"
    ]
  end

  def workbook_types
    [
      :string,
      :string,
      :string,
      :string,
      :string,
      :string,
      :string,
      :string,
      :string,
      :integer,
      :integer,
      :integer,
      :integer,
      :integer,
      :integer,
      :float
    ]
  end

  def empty_competency_summary
    {
      latest_course_semester: nil,
      course_count: 0,
      course_evidence_count: 0,
      course_competency_count: 0,
      target_met_count: 0,
      below_target_count: 0,
      no_target_count: 0,
      target_met_rate: nil
    }
  end
end
