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
    heatmap_row = payload[:student_course_heatmap].find { |row| row[:course_code] == "PHPM-601" }
    assert_equal [ "Policy Analysis" ], heatmap_row[:competency_titles]
    assert_equal 1, heatmap_row[:below_count]
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
    assert_equal "5", parsed.first["Course Achievement Levels"]
    assert_equal "4", parsed.first["Course Target Levels"]
    assert_equal "1", parsed.first["Achieved"]
    assert_equal "0", parsed.first["Not Met"]
    assert_includes parsed.headers, "No Course Target"
    refute_includes parsed.headers, "No Target"
    assert_equal "100.0", parsed.first["Achieved Rate"]
    assert_equal "0.0", parsed.first["Not Achieved Rate"]
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

  test "advisor without profile sees no evidence" do
    advisor_without_profile = OpenStruct.new(role_advisor?: true, advisor_profile: nil)
    create_evidence!("advisor-no-profile", course_code: "PHPM-601", competency_title: "Policy Analysis", mapped_level: 5, course_target_level: 4)

    payload = Reports::CourseCompetencyReport.new(user: advisor_without_profile).call

    assert_equal 0, payload[:summary][:evidence_count]
    assert_empty payload[:course_contributions]
  end

  test "private summaries handle no-semester missing course and nil student branches" do
    service = Reports::CourseCompetencyReport.new
    no_semester_batch = OpenStruct.new(program_semester: nil)
    row = OpenStruct.new(
      id: nil,
      grade_import_batch: no_semester_batch,
      course_code: nil,
      competency_title: nil,
      student_id: 12345,
      student: nil,
      mapped_level: nil,
      course_target_level: nil
    )

    summary = service.send(:summary_for, [ row ])
    assert_equal 0, summary[:course_count]
    assert_equal 1, summary[:evidence_count]
    assert_nil summary[:met_rate]

    contribution = service.send(:course_contributions, [ row ]).first
    assert_equal "No course code", contribution[:course_code]
    assert_equal "No competency", contribution[:competency_title]
    assert_equal "No semester", contribution[:release_statuses]
    assert_nil contribution[:assessed_average]
    assert_nil contribution[:course_target_average]

    heatmap = service.send(:student_course_heatmap, [ row ]).first
    assert_equal "Student 12345", heatmap[:student_name]
    assert_equal "No course code", heatmap[:course_code]
    assert_equal "missing", heatmap[:status]
  end

  test "filter parsing ignores invalid release statuses and supports alternate param names" do
    invalid = Reports::CourseCompetencyReport.new(params: { release_status: "invalid", program_semester_id: @semester.id.to_s })
    assert_equal({ program_semester_id: @semester.id.to_s }, invalid.send(:filters))

    alternate = Reports::CourseCompetencyReport.new(
      params: {
        course_program_semester_id: @semester.id.to_s,
        course_code: " PHPM-601 ",
        course_track: "Residential",
        course_class_of: "2026",
        release_status: "released"
      }
    )

    assert_equal(
      {
        program_semester_id: @semester.id.to_s,
        course_code: "PHPM-601",
        track: "Residential",
        class_of: "2026",
        release_status: "released"
      },
      alternate.send(:filters)
    )
  end

  test "heatmap status and average helpers cover each branch" do
    service = Reports::CourseCompetencyReport.new

    assert_equal "attention", service.send(:heatmap_status, 5, [ :below_target ])
    assert_equal "missing", service.send(:heatmap_status, nil, [ :met ])
    assert_equal "strong", service.send(:heatmap_status, 4, [ :met ])
    assert_equal "watch", service.send(:heatmap_status, 3, [ :met ])
    assert_equal "attention", service.send(:heatmap_status, 2, [ :met ])
    assert_nil service.send(:average, [])
    assert_equal 2.5, service.send(:average, [ 2.0, nil, 3 ])
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
