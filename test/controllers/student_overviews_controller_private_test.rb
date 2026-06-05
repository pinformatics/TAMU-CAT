require "test_helper"

class StudentOverviewsControllerPrivateTest < ActionController::TestCase
  tests StudentOverviewsController

  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = students(:student)
    @other_student = students(:other_student)
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in @admin
  end

  test "normalizes overview filters track and program year" do
    @controller.params = ActionController::Parameters.new(
      q: "  jacob  ",
      track: "Residential",
      program_year: "2026",
      student_status: "graduated"
    )

    filters = @controller.send(:overview_filters)

    assert_equal "jacob", filters[:q]
    assert_equal "Residential", filters[:track]
    assert_equal "2026", filters[:program_year]
    assert_equal "graduated", filters[:student_status]

    assert_nil @controller.send(:normalize_program_year, "Class of 2026")
    assert_nil @controller.send(:normalize_program_year, "")
    assert_nil @controller.send(:normalize_track, "not-a-track")
  end

  test "accessible student scope honors admin advisor and fallback scopes" do
    assert_includes @controller.send(:accessible_student_scope, include_historical: true).map(&:student_id), @student.student_id
    assert_includes @controller.send(:accessible_student_scope, include_historical: false).map(&:student_id), @student.student_id

    sign_out @admin
    sign_in @advisor
    advisor_ids = @controller.send(:accessible_student_scope, include_historical: true).map(&:student_id)

    assert_includes advisor_ids, @student.student_id
    refute_includes advisor_ids, @other_student.student_id

    sign_out @advisor
    sign_in users(:student)

    assert_empty @controller.send(:accessible_student_scope, include_historical: true).to_a
  end

  test "staff access guard redirects non staff users" do
    sign_out @admin
    sign_in users(:student)
    captured = nil

    @controller.stub(:redirect_to, ->(*args, **kwargs) { captured = [ args, kwargs ]; true }) do
      @controller.send(:require_staff_access!)
    end

    assert_equal dashboard_path, captured.first.first
    assert_equal ApplicationController::STAFF_ONLY_MESSAGE, captured.second[:alert]
  end

  test "overview rows calculate completion and default competency attainment" do
    SurveyAssignment.where(student_id: @other_student.student_id).delete_all
    survey_assignments(:residential_assignment).update!(completed_at: Time.current)

    rows = @controller.send(
      :overview_rows_for,
      [ @student, @other_student ],
      @student.student_id => { met_count: 2, total_count: 17 }
    )

    student_row = rows.find { |row| row[:student] == @student }
    other_row = rows.find { |row| row[:student] == @other_student }

    assert_equal 1, student_row[:assigned_count]
    assert_equal 1, student_row[:completed_count]
    assert_equal 100, student_row[:completion_rate]
    assert_equal({ met_count: 2, total_count: 17 }, student_row[:competency_attainment])
    assert_equal 0, other_row[:assigned_count]
    assert_nil other_row[:completion_rate]
    assert_equal Reports::DataAggregator::COMPETENCY_TITLES.size, other_row[:competency_attainment][:total_count]
  end

  test "filtered students applies search track and program year filters" do
    @controller.instance_variable_set(:@filters, {
      q: @student.uin,
      track: @student.track,
      program_year: @student.program_year.to_s,
      student_status: "all"
    })

    students = @controller.send(:filtered_students).to_a

    assert_includes students, @student
    refute_includes students, @other_student
    assert_includes @controller.send(:available_program_years), @student.program_year.to_s
  end

  test "overview and assignment status cover no activity overdue assigned and completed" do
    SurveyAssignment.where(student_id: @other_student.student_id).delete_all

    overview = @controller.send(:overview_for, @other_student)
    assert_equal 0, overview[:assigned_count]
    assert_nil overview[:completion_rate]
    assert_nil overview[:latest_activity_at]

    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current, available_until: 1.day.from_now)
    assert_equal "Completed", @controller.send(:assignment_status, assignment)

    assignment.update!(completed_at: nil, available_until: 1.day.ago)
    assert_equal "Overdue", @controller.send(:assignment_status, assignment)

    assignment.update!(available_until: 1.day.from_now)
    assert_equal "Assigned", @controller.send(:assignment_status, assignment)
  end

  test "domain heatmap and below target helpers cover source and status branches" do
    payload = {
      domains: [
        {
          name: "Course Domain",
          averages: { course: 4.25, self: 2.0 },
          competencies: [
            { title: "Course Low", self_below_target: false, course_below_target: true, self_rating: 3, course_rating: 2, end_program_target: 4 }
          ]
        },
        {
          name: "Self Domain",
          averages: { course: nil, self: 3.25 },
          competencies: [
            { title: "Self Met", self_below_target: false, course_below_target: false, self_rating: 3.25, course_rating: nil, end_program_target: 3 }
          ]
        },
        {
          name: "Below Target Domain",
          averages: { course: nil, self: 2.5 },
          competencies: [
            { title: "Self Low", self_below_target: true, course_below_target: false, self_rating: 2.5, course_rating: nil, end_program_target: 3 }
          ]
        },
        {
          name: "Missing Domain",
          averages: { course: nil, self: nil },
          competencies: [
            { title: "Fine", self_below_target: false, course_below_target: false, self_rating: nil, course_rating: nil, end_program_target: nil }
          ]
        }
      ]
    }

    heatmap = @controller.send(:domain_heatmap_for, payload)
    assert_equal "Course", heatmap[0][:source]
    assert_equal "strong", heatmap[0][:status]
    assert_equal "Self", heatmap[1][:source]
    assert_equal 3.0, heatmap[1][:target_average]
    assert_equal "strong", heatmap[1][:status]
    assert_equal "attention", heatmap[2][:status]
    assert_equal "Self", heatmap[3][:source]
    assert_equal "missing", heatmap[3][:status]
    assert_equal "attention", @controller.send(:heatmap_status, 2.5)

    below = @controller.send(:below_target_competencies_for, payload)
    assert_equal [ "Course Low", "Self Low" ], below.map { |row| row[:title] }
  end

  test "course survey advisor note and export filter rows use fallbacks" do
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current)
    assignment.survey.update!(semester: nil)

    survey_rows = @controller.send(:survey_rows_for, @student)
    assert_includes survey_rows.map { |row| row[:semester] }, assignment.survey.program_semester.name

    assert_empty @controller.send(:course_history_rows_for, @other_student)
    assert_empty @controller.send(:advisor_note_rows_for, @other_student)

    @controller.instance_variable_set(:@filters, { q: "", track: "", program_year: "", student_status: "" })
    assert_equal(
      [
        [ "Search students", "All students" ],
        [ "Track", "All tracks" ],
        [ "Program year", "All years" ],
        [ "Student status", "Active" ]
      ],
      @controller.send(:student_overview_export_filters)
    )
  end

  test "advisor assignment rows handle unassigned and assigned-by fallbacks" do
    StudentAdvisorAssignment.where(student_id: @student.student_id).delete_all
    StudentAdvisorAssignment.create!(
      student: @student,
      advisor: nil,
      starts_on: Date.current,
      ends_on: Date.current + 1.day,
      primary_assignment: true,
      assigned_by: nil
    )
    StudentAdvisorAssignment.create!(
      student: @student,
      advisor: advisors(:advisor),
      starts_on: Date.current + 2.days,
      primary_assignment: true,
      assigned_by: users(:admin)
    )

    rows = @controller.send(:advisor_assignment_rows_for, @student)

    assert_includes rows.map { |row| row[:advisor_name] }, "Unassigned"
    assert_includes rows.map { |row| row[:advisor_name] }, advisors(:advisor).display_name
    assert_includes rows.map { |row| row[:assigned_by_name] }, users(:admin).display_name
    assert rows.any? { |row| row[:current] == true }
    assert rows.any? { |row| row[:current] == false }
  end

  test "course history rows show no semester fallback and source file" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: nil,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "student-overview-course-history.csv",
      file_checksum: "student-overview-course-history",
      status: "processed"
    )
    evidence = batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Outcome",
      course_code: "PHPM-701",
      competency_title: "Course History Competency",
      raw_grade: 4,
      mapped_level: 4,
      course_target_level: 5,
      source_key: "student-overview-course-history",
      import_fingerprint: "student-overview-course-history"
    )

    row = @controller.send(:course_history_rows_for, @student).find { |entry| entry[:course_code] == evidence.course_code }

    assert_equal "No semester", row[:semester]
    assert_equal file.file_name, row[:source_file]
    assert_equal "Below target", row[:target_status]
  end

  test "course history groups collapse competency rows by course source and semester" do
    rows = [
      {
        semester: "Spring 2026",
        course_code: "PHPM-633-700",
        competency_title: "Ethics",
        target_status: "Met",
        source_file: "Outcomes.csv"
      },
      {
        semester: "Spring 2026",
        course_code: "PHPM-633-700",
        competency_title: "Policy Analysis",
        target_status: "Below target",
        source_file: "Outcomes.csv"
      },
      {
        semester: "Spring 2026",
        course_code: "PHPM-631-600",
        competency_title: "Performance Improvement",
        target_status: "No target",
        source_file: "2026_comp.xlsx"
      }
    ]

    groups = @controller.send(:course_history_groups_for, rows)

    assert_equal 2, groups.size
    phpm_633 = groups.find { |group| group[:course_code] == "PHPM-633-700" }
    assert_equal "Spring 2026", phpm_633[:semester]
    assert_equal "Outcomes.csv", phpm_633[:source_file]
    assert_equal 2, phpm_633[:competency_count]
    assert_equal 1, phpm_633[:met_count]
    assert_equal 1, phpm_633[:below_target_count]
    assert_equal [ "Ethics", "Policy Analysis" ], phpm_633[:rows].map { |row| row[:competency_title] }

    phpm_631 = groups.find { |group| group[:course_code] == "PHPM-631-600" }
    assert_equal 1, phpm_631[:no_target_count]
  end

  test "student overview workbook handles nil rows blank heatmap domains and filter fallbacks" do
    @controller.instance_variable_set(:@student_rows, [
      {
        student: nil,
        assigned_count: 0,
        completed_count: 0,
        completion_rate: nil,
        competency_attainment: nil
      },
      {
        student: @student,
        assigned_count: 2,
        completed_count: 1,
        completion_rate: 50,
        competency_attainment: { met_count: 3, total_count: 17 }
      }
    ])
    @controller.instance_variable_set(:@heatmap_rows, [
      { student_name: "No domains", track: nil, program_year: nil, domains: [] }
    ])
    @controller.instance_variable_set(:@filters, { q: nil, track: nil, program_year: nil, student_status: nil })

    package = @controller.send(:build_student_overviews_workbook)

    assert package.to_stream.read.bytesize.positive?
  end
end
