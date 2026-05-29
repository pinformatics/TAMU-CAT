require "test_helper"
require "csv"

class Reports::CourseCompetencyReportTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @semester = program_semesters(:fall_2025)
    @batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: @semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    @file = @batch.grade_import_files.create!(
      file_name: "course-report.csv",
      file_checksum: "checksum-course-report",
      status: "processed"
    )
  end

  test "summarizes course contributions target attainment and heatmap rows" do
    create_evidence!("met", course_code: "PHPM-601", competency_title: "Policy Analysis", mapped_level: 5, course_target_level: 4)
    create_evidence!("below", course_code: "PHPM-601", competency_title: "Policy Analysis", mapped_level: 2, course_target_level: 4)
    create_evidence!("missing-target", course_code: "PHPM-602", competency_title: "Systems Thinking", mapped_level: 3, course_target_level: nil)

    payload = Reports::CourseCompetencyReport.new.call
    policy_row = payload[:course_contributions].find { |row| row[:course_code] == "PHPM-601" && row[:competency_title] == "Policy Analysis" }

    assert_equal 2, payload[:summary][:course_count]
    assert_equal 2, payload[:summary][:competency_count]
    assert_equal 3, payload[:summary][:evidence_count]
    assert_equal 50.0, payload[:summary][:met_rate]
    assert_equal 1, policy_row[:student_count]
    assert_equal 2, policy_row[:evidence_count]
    assert_equal 3.5, policy_row[:assessed_average]
    assert_equal 4.0, policy_row[:course_target_average]
    assert_equal 50.0, policy_row[:met_rate]
    assert payload[:target_attainment].any? { |row| row[:course_code] == "PHPM-601" && row[:competency_title] == "Policy Analysis" }
    assert payload[:student_course_heatmap].any? { |row| row[:course_code] == "PHPM-601" && row[:below_count] == 1 }
  end

  test "filters by course semester track class and release status" do
    release_date = @semester.course_grade_release_date || @semester.build_course_grade_release_date
    release_date.update!(release_date: 1.day.from_now)
    create_evidence!("embargoed", course_code: "PHPM-601", competency_title: "Policy Analysis", mapped_level: 5, course_target_level: 4)
    create_evidence!("other-course", course_code: "PHPM-602", competency_title: "Systems Thinking", mapped_level: 5, course_target_level: 4)

    payload = Reports::CourseCompetencyReport.new(
      params: {
        course_program_semester_id: @semester.id.to_s,
        course_code: "PHPM-601",
        course_track: @student.track,
        course_class_of: @student.program_year.to_s,
        release_status: "embargoed"
      }
    ).call

    assert_equal 1, payload[:summary][:evidence_count]
    assert_equal [ "PHPM-601" ], payload[:course_contributions].map { |row| row[:course_code] }
    assert_equal "Embargoed", payload[:course_contributions].first[:release_statuses]
  end

  test "csv exports contribution rows" do
    create_evidence!("csv", course_code: "PHPM-601", competency_title: "Policy Analysis", mapped_level: 5, course_target_level: 4)

    csv = Reports::CourseCompetencyReport.new(params: { course_code: "PHPM-601" }).csv
    parsed = CSV.parse(csv, headers: true)

    assert_equal "PHPM-601", parsed.first["Course"]
    assert_equal "Policy Analysis", parsed.first["Competency"]
    assert_equal "5.0", parsed.first["Assessed Average"]
    assert_equal "4.0", parsed.first["Course Target Average"]
    assert_equal "100.0", parsed.first["Met Rate"]
  end

  test "advisor user only sees assigned advisee evidence" do
    create_evidence!("advisor-student", course_code: "PHPM-601", competency_title: "Policy Analysis", mapped_level: 5, course_target_level: 4)
    @batch.grade_competency_evidences.create!(
      grade_import_file: @file,
      student: students(:other_student),
      assignment_name: "Assignment other",
      course_code: "PHPM-999",
      competency_title: "Systems Thinking",
      raw_grade: 5,
      mapped_level: 5,
      course_target_level: 4,
      source_key: "course-report-advisor-other",
      import_fingerprint: "fingerprint-course-report-advisor-other"
    )

    payload = Reports::CourseCompetencyReport.new(user: users(:advisor)).call
    courses = payload[:course_contributions].map { |row| row[:course_code] }

    assert_includes courses, "PHPM-601"
    refute_includes courses, "PHPM-999"
  end

  private

  def create_evidence!(suffix, course_code:, competency_title:, mapped_level:, course_target_level:)
    @batch.grade_competency_evidences.create!(
      grade_import_file: @file,
      student: @student,
      assignment_name: "Assignment #{suffix}",
      course_code: course_code,
      competency_title: competency_title,
      raw_grade: mapped_level,
      mapped_level: mapped_level,
      course_target_level: course_target_level,
      source_key: "course-report-#{suffix}",
      import_fingerprint: "fingerprint-course-report-#{suffix}"
    )
  end
end
