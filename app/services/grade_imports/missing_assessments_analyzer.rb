# frozen_string_literal: true

module GradeImports
  # For each course in a batch, finds students who have grade-derived
  # evidence for SOME competency in that course but not for a competency
  # other students in the same course were assessed on -- i.e. the course
  # (or its instructor) appears to have skipped assessing them on that
  # competency. Surfaced so an admin can email the instructor with the
  # exact students/competencies that still need grades mapped.
  class MissingAssessmentsAnalyzer
    MAX_GROUPS = 50

    def self.call(batch:)
      new(batch: batch).call
    end

    def initialize(batch:)
      @batch = batch
    end

    def call
      groups = evidence_by_course.flat_map do |course_code, rows|
        roster = rows.map { |row| row[:student] }.compact.uniq { |student| student.student_id }
        competencies = rows.map { |row| row[:competency_title] }.compact_blank.uniq

        competencies.filter_map do |competency_title|
          assessed_ids = rows.select { |row| row[:competency_title] == competency_title }
                              .filter_map { |row| row[:student]&.student_id }.to_set
          missing_students = roster.reject { |student| assessed_ids.include?(student.student_id) }
          next if missing_students.empty?

          {
            course_code: course_code,
            competency_title: competency_title,
            roster_count: roster.size,
            assessed_count: assessed_ids.size,
            missing_count: missing_students.size,
            missing_students: missing_students.map { |student| student_summary(student) }
                                               .sort_by { |summary| summary[:name].to_s.downcase }
          }
        end
      end

      groups = groups.sort_by { |group| [ group[:course_code].to_s, group[:competency_title].to_s ] }.first(MAX_GROUPS)

      {
        requires_review: groups.any?,
        groups: groups,
        counts: {
          courses_affected: groups.map { |g| g[:course_code] }.uniq.size,
          groups: groups.size,
          students_affected: groups.sum { |g| g[:missing_count] }
        }
      }
    end

    private

    attr_reader :batch

    def evidence_by_course
      batch.grade_competency_evidences
           .includes(student: :user)
           .filter_map { |evidence| row_for(evidence) }
           .group_by { |row| row[:course_code] }
    end

    def row_for(evidence)
      course_code = evidence.course_code.presence
      return nil if course_code.blank?
      return nil if evidence.student.blank?

      {
        course_code: course_code,
        competency_title: evidence.competency_title,
        student: evidence.student
      }
    end

    def student_summary(student)
      {
        student_id: student.student_id,
        name: student.user&.name.presence || "Student #{student.student_id}",
        email: student.user&.email
      }
    end
  end
end
