require "test_helper"

class StudentPortfolioExporterTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @question = Question.create!(
      category: categories(:clinical_skills),
      question_text: StudentPortfolioExporter::PORTFOLIO_QUESTION_TEXT,
      question_order: 50,
      question_type: "evidence",
      is_required: true
    )
    StudentQuestion.create!(
      student: @student,
      question: @question,
      response_value: "https://sites.google.com/example/student"
    )
  end

  test "workbook exports uin and competency summary columns" do
    create_course_evidence_for(@student)
    exporter = StudentPortfolioExporter.new(actor_user: @admin, params: { q: @student.user.display_name })
    workbook = exporter.workbook.workbook
    sheet = workbook.worksheets.first

    assert_equal [
      "UIN",
      "Name",
      "Email",
      "Track",
      "Cohort",
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
    ], sheet.rows.first.cells.map(&:value)
    assert_equal @student.uin, sheet.rows.second.cells.first.value
    assert_equal "Fall 2025", sheet.rows.second.cells[8].value
    assert_equal 1, sheet.rows.second.cells[9].value
    assert_equal 1, sheet.rows.second.cells[12].value
    assert_equal 100.0, sheet.rows.second.cells[15].value
  end

  private

  def create_course_evidence_for(student)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = GradeImportFile.create!(
      grade_import_batch: batch,
      file_name: "Outcomes-26S-PHPM-601.csv",
      file_checksum: "portfolio-summary-test",
      status: "processed"
    )
    GradeCompetencyEvidence.create!(
      grade_import_batch: batch,
      grade_import_file: file,
      student: student,
      competency_title: Reports::DataAggregator::COMPETENCY_TITLES.first,
      course_code: "PHPM-601",
      assignment_name: "Course outcome",
      raw_grade: 4,
      mapped_level: 4,
      course_target_level: 3,
      source_key: "portfolio-summary-test",
      import_fingerprint: "portfolio-summary-test"
    )
  end
end
