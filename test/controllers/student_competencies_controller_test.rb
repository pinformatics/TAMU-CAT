require "test_helper"
require "uri"

class StudentCompetenciesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student_user = users(:student)
    @student = students(:student)
    @admin = users(:admin)
    @survey = surveys(:fall_2025)
    @competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
  end

  test "student can view competency dashboard" do
    sign_in @student_user

    get student_competencies_path

    assert_response :success
    assert_includes response.body, "My Competencies"
    assert_includes response.body, "How To Read This Page"
    assert_includes response.body, "What Changed Since Last Semester?"
    assert_includes response.body, "End-of-program target"
    assert_includes response.body, @competency_title
    assert_select "#competencySnapshotPanel.c-chart-panel--scrollable"
    assert_select ".c-chart-frame--radar canvas#competencyRadarChart"
  end

  test "student dashboard hides advisor column when advisor competencies are empty" do
    sign_in @student_user

    get student_competencies_path(semester: @survey.semester)

    assert_response :success
    assert_select "th", text: "Advisor", count: 0
    refute_includes response.body, "\"label\":\"Advisor\""
  end

  test "student dashboard shows advisor column when advisor competencies exist" do
    category = @survey.categories.create!(name: "Advisor Competency")
    question = category.questions.create!(
      question_text: @competency_title,
      question_type: "integer",
      question_order: 1
    )
    Feedback.create!(
      student: @student,
      advisor: advisors(:advisor),
      category: category,
      question: question,
      survey: @survey,
      average_score: 4
    )

    sign_in @student_user

    get student_competencies_path(semester: @survey.semester)

    assert_response :success
    assert_select "th", text: "Advisor"
    assert_includes response.body, "\"label\":\"Advisor\""
  end

  test "student dashboard shows advisor column from submitted advisor review survey values" do
    survey = Survey.new(
      title: "Submitted Advisor Review Student Dashboard Survey",
      program_semester: @survey.program_semester,
      is_active: true
    )
    survey.save!(validate: false)
    section = SurveySection.create!(survey: survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = Category.create!(survey: survey, section: section, name: "Health Care Environment and Community")
    question = category.questions.create!(
      question_text: @competency_title,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5],
      has_feedback: true
    )
    SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: survey.id,
      event: "submitted",
      answers: { question.id.to_s => "3" }
    )
    AdvisorFeedbackSubmission.create!(
      student_id: @student.student_id,
      survey_id: survey.id,
      advisor_id: advisors(:advisor).advisor_id,
      last_saved_at: Time.current,
      submitted_at: Time.current
    )

    sign_in @student_user

    get student_competencies_path(semester: @survey.semester)

    assert_response :success
    assert_select "th", text: "Advisor"
    assert_includes response.body, "\"label\":\"Advisor\""
    assert_includes response.body, "\"Advisor\",\"data\":[3.0"
  end

  test "student can export competencies as csv" do
    sign_in @student_user

    assert_difference -> { AdminActivityLog.where(action: "student_data_export").count }, 1 do
      get student_competencies_path(format: :csv)
    end

    assert_response :success
    assert_includes response.media_type, "text/csv"
    assert_includes response.body, "Competency"
    assert_includes response.body, @competency_title

    activity = AdminActivityLog.where(action: "student_data_export").order(created_at: :desc).first
    assert_equal "my_competencies_csv", activity.metadata["export_type"]
    assert_equal @student, activity.subject
  end

  test "student can download competencies as pdf" do
    fake_pdf = Object.new
    def fake_pdf.pdf_from_string(_html, *_args)
      "%PDF-1.4"
    end

    sign_in @student_user

    assert_difference -> { AdminActivityLog.where(action: "student_data_export").count }, 1 do
      WickedPdf.stub(:new, fake_pdf) do
        get student_competencies_path(format: :pdf)
      end
    end

    assert_response :success
    assert_includes response.media_type, "application/pdf"
    assert_equal "%PDF-1.4", response.body

    activity = AdminActivityLog.where(action: "student_data_export").order(created_at: :desc).first
    assert_equal "my_competencies_pdf", activity.metadata["export_type"]
    assert_equal @student, activity.subject
  end

  test "student dashboard includes all semesters option and honors source filters" do
    sign_in @student_user

    get student_competencies_path(semester: "all", sources: [ "self" ])

    assert_response :success
    assert_select "select[name='semester'] option[selected='selected']", "All semesters"
    assert_select "input[name='sources[]'][value='self'][checked='checked']"
    assert_select "th", text: "Self"
    assert_select "th", text: "Course", count: 0
    assert_select "th", text: "End-of-Program Target", count: 0
    refute_includes response.body, "\"label\":\"Course\""
  end

  test "student competency exports preserve semester and source filters" do
    sign_in @student_user

    get student_competencies_path(semester: "all", sources: [ "self" ])

    assert_response :success
    assert_select ".c-ferpa-export-notice", text: /Student-level competency exports/
    assert_select "a[data-turbo='false'][data-turbo-confirm*='FERPA reminder']", text: "Export CSV"
    assert_select "a[data-turbo='false'][data-turbo-confirm*='FERPA reminder']", text: "Download PDF"
    csv_link = assert_link_path_and_query(
      "Export CSV",
      student_competencies_path(format: :csv),
      "semester" => "all",
      "sources" => [ "self" ]
    )
    pdf_link = assert_link_path_and_query(
      "Download PDF",
      student_competencies_path(format: :pdf),
      "semester" => "all",
      "sources" => [ "self" ]
    )

    [ csv_link, pdf_link ].each do |link|
      assert_includes link["data-turbo-confirm"], "FERPA reminder"
      assert_includes link["data-turbo-confirm"], "student-level competency data"
      assert_includes link["data-turbo-confirm"], "legitimate educational interest"
    end
  end

  test "future release date hides course ratings from student dashboard" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: @survey.program_semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: @competency_title,
      aggregated_level: 4,
      aggregation_rule: "max",
      evidence_count: 1
    )
    @survey.program_semester.create_course_grade_release_date!(release_date: 2.days.from_now)

    sign_in @student_user

    get student_competencies_path(semester: @survey.semester)

    assert_response :success
    assert_includes response.body, "Embargoed"
    refute_match(/<td>4\.0<\/td>/, response.body)
  end

  test "student dashboard shows course competency sources and levels" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: @survey.program_semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "PHPM-601.xlsx",
      file_checksum: "sources-checksum-1",
      status: "processed"
    )
    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: @competency_title,
      aggregated_level: 5,
      aggregation_rule: "max",
      evidence_count: 2
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Community Assessment",
      course_code: "PHPM-601-700",
      competency_title: @competency_title,
      raw_grade: 71,
      mapped_level: 1,
      course_target_level: 3,
      row_number: 2,
      source_key: "source-community-assessment",
      import_fingerprint: "fingerprint-community-assessment"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Population Final",
      course_code: "PHPM-633-700",
      competency_title: @competency_title,
      raw_grade: 98,
      mapped_level: 5,
      course_target_level: 4,
      row_number: 3,
      source_key: "source-population-final",
      import_fingerprint: "fingerprint-population-final"
    )

    sign_in @student_user

    get student_competencies_path(semester: @survey.semester)

    assert_response :success
    refute_includes response.body, "<th>Course Sources</th>"
    assert_select "td details.c-cell-details", count: 1
    assert_select "td details.c-cell-details[open]", count: 0
    assert_includes response.body, "2 sources"
    assert_includes response.body, "PHPM-601-700"
    assert_includes response.body, "Competency level 1"
    assert_includes response.body, "Course target level 3"
    assert_includes response.body, "PHPM-633-700"
    assert_includes response.body, "Competency level 5"
    assert_includes response.body, "Course target level 4"
    refute_includes response.body, "Community Assessment"
    refute_includes response.body, "Raw 71.0"
    refute_includes response.body, "PHPM-601.xlsx"
  end

  test "student dashboard shows end of program target from competency targets for student track and year" do
    CompetencyTargetLevel.create!(
      program_semester: @survey.program_semester,
      track: @student.track,
      class_of: @student.program_year.to_i + 1,
      competency_title: @competency_title,
      target_level: 2
    )
    CompetencyTargetLevel.create!(
      program_semester: @survey.program_semester,
      track: @student.track,
      class_of: @student.program_year,
      competency_title: @competency_title,
      target_level: 5
    )

    sign_in @student_user

    get student_competencies_path(semester: @survey.semester)

    assert_response :success
    assert_select "th", "End-of-Program Target"
    refute_includes response.body, "<th>Course Target</th>"
    assert_includes response.body, "End-of-program expectation"
    assert_select ".c-score-pill--program", text: "5"
    assert_select ".c-score-pill--program", text: "2", count: 0
  end

  test "student dashboard hides sources from other semesters" do
    other_survey = surveys(:spring_2025)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: other_survey.program_semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "PHPM-999.xlsx",
      file_checksum: "sources-checksum-other-semester",
      status: "processed"
    )
    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: @competency_title,
      aggregated_level: 5,
      aggregation_rule: "max",
      evidence_count: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Other Semester Assignment",
      course_code: "PHPM-999-700",
      competency_title: @competency_title,
      raw_grade: 99,
      mapped_level: 5,
      row_number: 4,
      source_key: "source-other-semester",
      import_fingerprint: "fingerprint-other-semester"
    )

    sign_in @student_user

    get student_competencies_path(semester: @survey.semester)

    assert_response :success
    refute_includes response.body, "PHPM-999-700"
  end

  test "student dashboard defaults to current semester and includes earlier enrollment semesters" do
    student = students(:other_student)
    student.update!(program_year: 2027, track: "Residential")
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:spring_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "PHPM-650.xlsx",
      file_checksum: "student-data-semester-checksum",
      status: "processed"
    )
    batch.grade_competency_ratings.create!(
      student: student,
      competency_title: @competency_title,
      aggregated_level: 4,
      aggregation_rule: "max",
      evidence_count: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: student,
      assignment_name: "Course Evidence",
      course_code: "PHPM-650-700",
      competency_title: @competency_title,
      raw_grade: 90,
      mapped_level: 4,
      course_target_level: 5,
      row_number: 5,
      source_key: "source-student-data-semester",
      import_fingerprint: "fingerprint-student-data-semester"
    )

    sign_in users(:other_student)

    get student_competencies_path

    assert_response :success
    assert_select "select[name='semester'] option", "Spring 2025"
    assert_select "select[name='semester'] option[selected='selected']", ProgramSemester.current.name
    refute_includes response.body, "PHPM-650-700"

    get student_competencies_path(semester: "Spring 2025")

    assert_response :success
    assert_includes response.body, "PHPM-650-700"
    assert_includes response.body, "Competency level 4"
  end

  test "admin cannot view student competency dashboard" do
    sign_in @admin

    get student_competencies_path

    assert_redirected_to dashboard_path
  end

  private

  def assert_link_path_and_query(label, expected_path, expected_query)
    link = css_select("a").find { |anchor| anchor.text.squish == label }
    assert link, "Expected to find #{label.inspect} link"

    uri = URI.parse(link["href"])
    assert_equal expected_path, uri.path

    query = Rack::Utils.parse_nested_query(uri.query)
    expected_query.each do |key, value|
      assert_equal value, query[key], "Expected #{label} query #{key}=#{value.inspect}; found #{query.inspect}"
    end

    link
  end
end
