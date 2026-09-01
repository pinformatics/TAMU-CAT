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

    assert_equal "Student Profile", sheet.name
    assert_equal [
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
      "Course Targets Achieved",
      "Below Course Target",
      "No Course Target",
      "Course Target Achievement Rate"
    ], sheet.rows.first.cells.map(&:value)
    assert_equal @student.uin, sheet.rows.second.cells.first.value
    assert_equal @student.program_year.to_s, sheet.rows.second.cells[4].value
    assert_equal "Fall 2025", sheet.rows.second.cells[8].value
    assert_equal 1, sheet.rows.second.cells[9].value
    assert_equal 1, sheet.rows.second.cells[12].value
    assert_equal 100.0, sheet.rows.second.cells[15].value
  end

  test "students scope filters by advisor search track and program year" do
    advisor_user = users(:advisor)

    advisor_exporter = StudentPortfolioExporter.new(actor_user: advisor_user, params: {})
    assert_equal advisor_user.advisor_profile.advisees.map(&:student_id).sort, advisor_exporter.students.map(&:student_id).sort

    filtered = StudentPortfolioExporter.new(
      actor_user: @admin,
      params: {
        q: @student.uin.first(4),
        track: @student.track,
        program_year: @student.program_year
      }
    ).students

    assert_includes filtered.map(&:student_id), @student.student_id
    assert filtered.all? { |student| student.track_key == @student.track_key && student.program_year == @student.program_year }
  end

  test "rows use empty competency summary when no reportable evidence exists" do
    exporter = StudentPortfolioExporter.new(actor_user: @admin, params: { q: @student.uin })
    row = exporter.rows.find { |entry| entry[:student_id] == @student.student_id }

    assert_equal "https://sites.google.com/example/student", row[:portfolio_url]
    assert_nil row[:latest_course_semester]
    assert_equal 0, row[:course_count]
    assert_equal 0, row[:course_evidence_count]
    assert_nil row[:target_met_rate]
  end

  test "rows tolerate missing advisor and course evidence without targets" do
    @student.update!(advisor: nil)
    create_course_evidence_for(@student, program_semester: nil, target_level: nil)

    exporter = StudentPortfolioExporter.new(actor_user: nil, params: { q: @student.uin, track: "not a real track" })
    row = exporter.rows.find { |entry| entry[:student_id] == @student.student_id }

    assert_nil row[:advisor]
    assert_nil row[:latest_course_semester]
    assert_equal 1, row[:course_count]
    assert_equal 1, row[:no_target_count]
    assert_nil row[:target_met_rate]
  end

  test "advisor without advisor profile sees no student rows" do
    advisor_user = User.create!(
      email: "advisor_without_profile_#{SecureRandom.hex(4)}@example.com",
      name: "Advisor Without Profile",
      role: "advisor",
      uid: "advisor-without-profile-#{SecureRandom.hex(4)}"
    )
    advisor_user.advisor_profile&.destroy!

    exporter = StudentPortfolioExporter.new(actor_user: advisor_user, params: {})

    assert_equal [], exporter.students.to_a
  ensure
    advisor_user&.destroy
  end

  test "latest portfolio answer returns empty when no students match and workbook types stay stable" do
    exporter = StudentPortfolioExporter.new(actor_user: @admin, params: { q: "no matching student" })

    assert_equal [], exporter.students.to_a
    assert_equal({}, exporter.send(:latest_portfolio_answers))
    assert_equal({}, exporter.send(:grouped_evidence))
    assert_equal 16, exporter.send(:workbook_headers).size
    assert_equal 16, exporter.send(:workbook_types).size
  end

  private

  def create_course_evidence_for(student, program_semester: program_semesters(:fall_2025), target_level: 3)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semester,
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
      course_target_level: target_level,
      source_key: "portfolio-summary-test-#{SecureRandom.hex(4)}",
      import_fingerprint: "portfolio-summary-test-#{SecureRandom.hex(4)}"
    )
  end
end
