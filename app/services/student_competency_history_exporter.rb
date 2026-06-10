# frozen_string_literal: true

require "csv"

class StudentCompetencyHistoryExporter
  def initialize(student:)
    @student = student
  end

  def rows
    course_evidence_rows + derived_rating_rows
  end

  def csv
    CSV.generate(headers: true) do |csv|
      csv << headers
      rows.each do |row|
        csv << headers.map { |header| row[header] }
      end
    end
  end

  private

  attr_reader :student

  def headers
    [
      "Source Type",
      "Semester",
      "Course",
      "Competency",
      "Assessed Level",
      "Course Target Level",
      "Target Met",
      "Evidence Count",
      "Source File",
      "Assignment",
      "Updated At"
    ]
  end

  def course_evidence_rows
    course_evidence.map do |evidence|
      {
        "Source Type" => "Course evidence",
        "Semester" => evidence.grade_import_batch&.program_semester&.name || "No semester",
        "Course" => evidence.course_code,
        "Competency" => evidence.competency_title,
        "Assessed Level" => evidence.mapped_level,
        "Course Target Level" => evidence.course_target_level,
        "Target Met" => GradeImports::TargetAttainmentReport.export_label(evidence.mapped_level, evidence.course_target_level),
        "Evidence Count" => 1,
        "Source File" => evidence.grade_import_file&.file_name,
        "Assignment" => evidence.assignment_name,
        "Updated At" => evidence.updated_at&.iso8601
      }
    end
  end

  def derived_rating_rows
    derived_ratings.map do |rating|
      {
        "Source Type" => "Derived course rating",
        "Semester" => rating.grade_import_batch&.program_semester&.name || "No semester",
        "Course" => "All imported courses",
        "Competency" => rating.competency_title,
        "Assessed Level" => rating.aggregated_level,
        "Course Target Level" => nil,
        "Target Met" => nil,
        "Evidence Count" => rating.evidence_count,
        "Source File" => nil,
        "Assignment" => "Aggregated #{rating.aggregation_rule}",
        "Updated At" => rating.updated_at&.iso8601
      }
    end
  end

  def course_evidence
    @course_evidence ||= GradeCompetencyEvidence
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .includes(:grade_import_file, grade_import_batch: :program_semester)
      .where(student_id: student.student_id)
      .order(Arel.sql("grade_import_batches.created_at ASC"), :course_code, :competency_title, :updated_at)
  end

  def derived_ratings
    @derived_ratings ||= GradeCompetencyRating
      .joins(:grade_import_batch)
      .merge(GradeImportBatch.reportable)
      .includes(grade_import_batch: :program_semester)
      .where(student_id: student.student_id)
      .order(Arel.sql("grade_import_batches.created_at ASC"), :competency_title, :updated_at)
  end
end
