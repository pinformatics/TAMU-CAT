# frozen_string_literal: true

class AdvisorAttentionList
  DEFAULT_LIMIT = 25

  def initialize(students:, semester: nil, limit: DEFAULT_LIMIT)
    @students = Array(students)
    @semester = semester.presence || ProgramSemester.current&.name
    @limit = limit
  end

  def call
    students.filter_map { |student| attention_row_for(student) }
            .sort_by { |row| [ -row[:priority], row[:student_name].to_s.downcase ] }
            .first(limit)
  end

  private

  attr_reader :students, :semester, :limit

  def attention_row_for(student)
    missing_assignments = incomplete_assignment_count(student)
    dashboard = StudentCompetencyDashboard.new(student: student, params: { semester: semester }).call
    below_target = below_target_competencies(dashboard)

    return if missing_assignments.zero? && below_target.empty?

    {
      student_id: student.student_id,
      student_name: student.user&.display_name || student.full_name,
      email: student.user&.email,
      semester: dashboard.dig(:filters, :semester).presence || "All semesters",
      missing_survey_count: missing_assignments,
      below_target_competencies: below_target,
      priority: missing_assignments + below_target.size,
      detail_path_params: { semester: dashboard.dig(:filters, :semester) }
    }
  end

  def incomplete_assignment_count(student)
    scope = student.survey_assignments.incomplete
    if semester.present?
      scope = scope.joins(survey: :program_semester)
                   .where("LOWER(program_semesters.name) = ?", semester.downcase)
    end

    scope.count
  end

  def below_target_competencies(dashboard)
    dashboard[:domains].flat_map do |domain|
      domain[:competencies].filter_map do |competency|
        next unless competency[:self_below_target] || competency[:course_below_target]

        {
          title: competency[:title],
          self_rating: competency[:self_rating],
          course_rating: competency[:course_rating],
          target: competency[:end_program_target]
        }
      end
    end
  end
end
