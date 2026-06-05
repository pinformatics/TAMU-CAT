require "test_helper"
require "csv"
require "uri"

class Admin::CompetenciesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @other_advisor = users(:other_advisor)
    @student = users(:student)
    @other_student = users(:other_student)
    students(:student).update!(advisor_id: @advisor.id)
    students(:other_student).update!(advisor_id: @other_advisor.id)
  end

  test "advisor can view competencies matrix for assigned students only" do
    sign_in @advisor

    get competencies_path

    assert_response :success
    assert_includes response.body, "Competencies"
    assert_includes response.body, @student.email
    assert_includes response.body, competency_path(students(:student))
    refute_includes response.body, "Course competency rule"
    refute_includes response.body, "Global setting applied to course-derived competency values for all users."
    refute_includes response.body, @other_student.email
  end

  test "advisor old admin competency URL redirects to neutral shared route" do
    sign_in @advisor

    get admin_competencies_path

    assert_redirected_to competencies_path
  end

  test "advisor old admin competency URL redirects for head requests" do
    sign_in @advisor

    head admin_competencies_path

    assert_redirected_to competencies_path
  end

  test "student is redirected with shared staff-only warning" do
    sign_in @student

    get admin_competencies_path

    assert_redirected_to dashboard_path
    assert_equal ApplicationController::STAFF_ONLY_MESSAGE, flash[:alert]
  end

  test "admin can view competencies matrix" do
    sign_in @admin

    get admin_competencies_path

    assert_response :success
    assert_includes response.body, "Competencies"
    assert_includes response.body, "Course competency rule"
    assert_includes response.body, "Global setting applied to course-derived competency values for all users."
    assert_includes response.body, "c-disclosure-summary--compact"
    assert_includes response.body, "Details"
    assert_includes response.body, admin_competency_path(students(:student))
    assert_includes response.body, "Health Care Environment and Community"
  end

  test "competencies matrix renders domain headers competency headers and source score rows" do
    sign_in @admin
    fall = program_semesters(:fall_2025)
    domain_name = Reports::DataAggregator::REPORT_DOMAINS.first
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    create_course_rating(student: students(:student), competency_title: competency_title, level: 4.0, semester: fall)

    get admin_competencies_path(q: @student.email, semester: fall.name)

    assert_response :success
    assert_select "th.c-table__domain-header", text: domain_name
    assert_select "th.c-table__competency-header .c-table__competency-title", text: competency_title
    assert_select "tr.c-table-row--self th.c-table__source-cell", text: /Self/
    assert_select "tr.c-table-row--advisor th.c-table__source-cell", text: /Advisor/
    assert_select "tr.c-table-row--course th.c-table__source-cell", text: /Course/
    assert_select "tr.c-table-row--course td.c-table__score-cell .c-score-pill--course", text: "4"
  end

  test "competencies matrix remembers filters across page returns and clears them on request" do
    sign_in @admin
    unique_search = students(:student).uin

    get admin_competencies_path(q: unique_search, semester: program_semesters(:fall_2025).name)

    assert_response :success
    assert_select "input[name='q'][value='#{unique_search}']"
    assert_select "select[name='semester'] option[selected][value='#{program_semesters(:fall_2025).name}']"
    assert_includes response.body, @student.email
    refute_includes response.body, @other_student.email

    get admin_dashboard_path
    assert_response :success

    get admin_competencies_path

    assert_response :success
    assert_select "input[name='q'][value='#{unique_search}']"
    assert_select "select[name='semester'] option[selected][value='#{program_semesters(:fall_2025).name}']"
    assert_includes response.body, @student.email
    refute_includes response.body, @other_student.email

    get export_admin_competencies_path(format: :csv)

    assert_response :success
    csv = CSV.parse(response.body, headers: true)
    assert_equal [ @student.email ], csv.map { |row| row["Student Email"] }.uniq

    get admin_competencies_path(clear_filters: 1)

    assert_response :success
    assert_select "input[name='q'][value='#{unique_search}']", count: 0
    assert_select "select[name='semester'] option[selected][value='#{program_semesters(:fall_2025).name}']", count: 0
  end

  test "competency matrix export link preserves current filters" do
    sign_in @admin
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    semester = program_semesters(:fall_2025).name

    get admin_competencies_path, params: {
      q: @student.email,
      track: "Residential",
      program_year: "2026",
      advisor_id: @advisor.id,
      semester: semester,
      domain: Reports::DataAggregator::REPORT_DOMAINS.first,
      student_status: "all",
      competencies: [ competency_title ]
    }

    assert_response :success
    assert_select ".c-ferpa-export-notice", text: /Student-level competency matrix exports/
    assert_select "a[data-turbo='false'][data-turbo-confirm*='FERPA reminder']", text: "Export CSV"
    assert_link_path_and_query(
      "Export CSV",
      export_admin_competencies_path,
      "q" => @student.email,
      "track" => "residential",
      "program_year" => "2026",
      "advisor_id" => @advisor.id.to_s,
      "semester" => semester,
      "domain" => Reports::DataAggregator::REPORT_DOMAINS.first,
      "student_status" => "all",
      "competencies" => [ competency_title ]
    )
  end

  test "competencies matrix defaults to current students and can include archived students" do
    students(:other_student).archive!(archived_by: @admin, reason: "Historical competency review")
    sign_in @admin

    get admin_competencies_path

    assert_response :success
    refute_includes response.body, @other_student.email

    get admin_competencies_path(student_status: "all")

    assert_response :success
    assert_includes response.body, @other_student.email
    assert_includes response.body, "Archived"
  end

  test "competency overview compares ratings against program targets" do
    sign_in @admin
    student = students(:student)
    met_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    below_title = Reports::DataAggregator::COMPETENCY_TITLES.second

    [ met_title, below_title ].each do |title|
      CompetencyTargetLevel.create!(
        program_semester: program_semesters(:fall_2025),
        track: student.track,
        class_of: student.program_year,
        competency_title: title,
        target_level: 3
      )
    end

    create_course_rating(student: student, competency_title: met_title, level: 4.0)
    create_course_rating(student: student, competency_title: below_title, level: 2.0)

    get admin_competencies_path

    assert_response :success
    assert_includes response.body, "Details"
    assert_includes response.body, "c-score-pill--met"
    assert_includes response.body, "c-score-pill--below"
    assert_includes response.body, "c-table--sm"
    assert_includes response.body, "c-score-pill--self"
    assert_includes response.body, "c-score-pill--advisor"
    assert_includes response.body, "Course 4 vs target 3: meets target"
    refute_includes response.body, "Course score from imported course competency data"
  end

  test "competency overview uses submitted survey response versions when student question rows are absent" do
    sign_in @admin
    student = students(:student)
    survey = Survey.new(
      title: "Versioned Competency Survey",
      program_semester: program_semesters(:fall_2025),
      is_active: true
    )
    survey.save!(validate: false)
    section = SurveySection.create!(survey: survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = Category.create!(survey: survey, section: section, name: "Health Care Environment and Community")
    first_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    second_title = Reports::DataAggregator::COMPETENCY_TITLES.second
    first_question = category.questions.create!(
      question_text: first_title,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5]
    )
    second_question = category.questions.create!(
      question_text: second_title,
      question_type: "dropdown",
      question_order: 2,
      answer_options: %w[1 2 3 4 5]
    )

    StudentQuestion.where(student_id: student.student_id, question_id: [ first_question.id, second_question.id ]).delete_all
    SurveyResponseVersion.create!(
      student_id: student.student_id,
      survey_id: survey.id,
      event: "submitted",
      answers: {
        (first_question.id + 100).to_s => "4",
        (second_question.id + 100).to_s => "2"
      }
    )

    get admin_competencies_path(q: @student.email, semester: program_semesters(:fall_2025).name)

    assert_response :success
    assert_includes response.body, first_title
    assert_match(/>\s*4\s*</, response.body)
    assert_match(/>\s*2\s*</, response.body)
  end

  test "competency overview reads advisor feedback scores from survey feedback rows" do
    sign_in @admin
    student = students(:student)
    survey = surveys(:fall_2025)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    section = SurveySection.find_or_create_by!(survey: survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = survey.categories.create!(name: "Advisor Feedback Competencies", section: section)
    question = category.questions.create!(
      question_text: competency_title,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5],
      has_feedback: true
    )
    Feedback.create!(
      student: student,
      advisor: advisors(:advisor),
      survey: survey,
      category: category,
      question: question,
      average_score: 4
    )

    payload = Admin::CompetencyMatrix.new(
      params: { q: @student.email, semester: survey.program_semester.name },
      actor_user: @admin
    ).call
    row = payload[:students].find { |student_row| student_row[:id] == student.student_id }

    assert_equal 4.0, row.dig(:ratings, competency_title, :advisor_rating)
  end

  test "competency overview uses submitted advisor review survey values when feedback rows are absent" do
    sign_in @admin
    student = students(:student)
    survey = Survey.new(
      title: "Submitted Advisor Review Competency Survey",
      program_semester: program_semesters(:fall_2025),
      is_active: true
    )
    survey.save!(validate: false)
    section = SurveySection.create!(survey: survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = Category.create!(survey: survey, section: section, name: "Health Care Environment and Community")
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    question = category.questions.create!(
      question_text: competency_title,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5],
      has_feedback: true
    )
    SurveyResponseVersion.create!(
      student_id: student.student_id,
      survey_id: survey.id,
      event: "submitted",
      answers: { question.id.to_s => "3" }
    )
    AdvisorFeedbackSubmission.create!(
      student_id: student.student_id,
      survey_id: survey.id,
      advisor_id: @advisor.id,
      last_saved_at: Time.current,
      submitted_at: Time.current
    )

    payload = Admin::CompetencyMatrix.new(
      params: { q: @student.email, semester: survey.program_semester.name },
      actor_user: @admin
    ).call
    row = payload[:students].find { |student_row| student_row[:id] == student.student_id }

    assert_equal 3.0, row.dig(:ratings, competency_title, :advisor_rating)
  end

  test "admin can view detailed student competency dashboard" do
    sign_in @admin

    get admin_competency_path(students(:student))

    assert_response :success
    assert_includes response.body, "#{@student.display_name} Competencies"
    assert_includes response.body, "Student-facing competency modules"
    assert_includes response.body, "c-competency-guide-tips"
    assert_includes response.body, "The student's survey rating"
    assert_includes response.body, "Advisor legacy rating"
    assert_includes response.body, "Competency Snapshot"
    assert_includes response.body, "Semester Trend"
    assert_includes response.body, "c-staff-competency-workspace"
    assert_includes response.body, "Competency Comparison"
    assert_includes response.body, "<th>Goal</th>"
    refute_includes response.body, "c-interpretation-guide"
    refute_includes response.body, "c-section-group"
    assert_includes response.body, "Export CSV"
    assert_includes response.body, admin_competencies_path
  end

  test "advisor can view detailed dashboard for assigned student" do
    sign_in @advisor

    get competency_path(students(:student))

    assert_response :success
    assert_includes response.body, "#{@student.display_name} Competencies"
    assert_includes response.body, "Competency Snapshot"
    assert_includes response.body, competencies_path
  end

  test "advisor cannot view detailed dashboard for unassigned student and is redirected gracefully" do
    sign_in @advisor

    get competency_path(students(:other_student))

    assert_redirected_to competencies_path
    assert_equal "That student competency record is not available from your account.", flash[:alert]
  end

  test "advisor filter options stay scoped to assigned students" do
    sign_in @advisor

    get competencies_path, params: { advisor_id: @other_advisor.id }

    assert_response :success
    assert_includes response.body, "No students match the current filters."
    refute_includes response.body, @other_student.email
  end

  test "admin can update global course competency rule" do
    sign_in @admin

    patch course_rule_admin_competencies_path, params: { course_competency_rule: "avg" }

    assert_redirected_to admin_competencies_path
    assert_equal "avg", SiteSetting.course_competency_rule
  ensure
    SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
  end

  test "advisor cannot update global course competency rule" do
    sign_in @advisor

    patch course_rule_admin_competencies_path, params: { course_competency_rule: "avg" }

    assert_redirected_to dashboard_path
    assert_equal CourseCompetencyRule::DEFAULT_RULE, SiteSetting.course_competency_rule
  ensure
    SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
  end

  test "admin can export competencies as csv" do
    sign_in @admin
    student = students(:student)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first

    CompetencyTargetLevel.create!(
      program_semester: program_semesters(:fall_2025),
      track: student.track,
      class_of: student.program_year,
      competency_title: competency_title,
      target_level: 4
    )

    assert_difference -> { AdminActivityLog.where(action: "student_data_export").count }, 1 do
      get export_admin_competencies_path(format: :csv)
    end

    assert_response :success
    assert_equal "text/csv", response.media_type

    csv = CSV.parse(response.body, headers: true)
    assert_includes csv.headers, "Student ID"
    assert_includes csv.headers, "Course Competency Rule"
    assert_includes csv.headers, "#{competency_title} Program Target"
    assert csv.any?, "Expected exported CSV to include at least one row"
    assert_equal csv.map { |row| row["Student ID"] }.uniq.size, csv.size

    export_row = csv.find { |row| row["Student ID"].to_i == student.student_id }
    assert_equal "4", export_row["#{competency_title} Program Target"]
  end

  test "admin csv export uses selected semester program targets" do
    sign_in @admin
    student = students(:student)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    current_semester = ProgramSemester.current

    CompetencyTargetLevel.create!(
      program_semester: current_semester,
      track: student.track,
      class_of: student.program_year,
      competency_title: competency_title,
      target_level: 3
    )

    CompetencyTargetLevel.create!(
      program_semester: program_semesters(:spring_2026),
      track: student.track,
      class_of: student.program_year,
      competency_title: competency_title,
      target_level: 5
    )

    get export_admin_competencies_path(format: :csv, semester: program_semesters(:spring_2026).name)

    assert_response :success
    csv = CSV.parse(response.body, headers: true)
    export_row = csv.find { |row| row["Student ID"].to_i == student.student_id }

    assert_equal "5", export_row["#{competency_title} Program Target"]
    assert_equal program_semesters(:spring_2026).name, export_row["Semester Filter"]
  end

  test "admin csv export uses the same semester-scoped course ratings as the matrix" do
    sign_in @admin
    student = students(:student)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    fall = program_semesters(:fall_2025)

    create_course_rating(student: student, competency_title: competency_title, level: 2.0, semester: fall)
    create_course_rating(student: student, competency_title: competency_title, level: 4.0, semester: program_semesters(:spring_2025))
    create_course_rating(student: student, competency_title: competency_title, level: 5.0, semester: nil)

    payload = Admin::CompetencyMatrix.new(
      params: { q: @student.email, semester: fall.name },
      actor_user: @admin
    ).call
    matrix_row = payload[:students].find { |row| row[:id] == student.student_id }

    assert_in_delta 2.0, matrix_row.dig(:ratings, competency_title, :course_rating), 0.001

    get export_admin_competencies_path(format: :csv, q: @student.email, semester: fall.name)

    assert_response :success
    csv = CSV.parse(response.body, headers: true)
    export_row = csv.find { |row| row["Student ID"].to_i == student.student_id }

    refute_nil export_row
    assert_equal "2.0", export_row["#{competency_title} Course Rating"]
    assert_equal fall.name, export_row["Semester Filter"]
  end

  test "advisor export remains scoped to assigned students" do
    sign_in @advisor

    get export_competencies_path(format: :csv)

    assert_response :success
    csv = CSV.parse(response.body, headers: true)
    student_names = csv.map { |row| row["Student Name"] }.uniq

    assert_includes student_names, @student.display_name
    refute_includes student_names, @other_student.display_name
  end

  test "changing course competency rule updates matrix values for all rule options program-wide" do
    sign_in @admin
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    create_course_rating(student: students(:student), competency_title: competency_title, level: 3.0)
    create_course_rating(student: students(:student), competency_title: competency_title, level: 4.0)
    create_course_rating(student: students(:student), competency_title: competency_title, level: 1.0)
    create_course_rating(student: students(:student), competency_title: competency_title, level: 2.0)
    create_course_rating(student: students(:student), competency_title: competency_title, level: 1.0)

    {
      "max" => { value: 4.0, label: "Max" },
      "min" => { value: 1.0, label: "Min" },
      "avg" => { value: 2.2, label: "Avg" },
      "ceil_avg" => { value: 3.0, label: "Ceil(avg)" },
      "floor_avg" => { value: 2.0, label: "Floor(avg)" }
    }.each do |rule, expected|
      patch course_rule_admin_competencies_path, params: { course_competency_rule: rule }
      assert_redirected_to admin_competencies_path

      payload = Admin::CompetencyMatrix.new(params: {}, actor_user: @admin).call
      row = payload[:students].find { |student_row| student_row[:id] == students(:student).student_id }
      assert_in_delta expected[:value], row.dig(:ratings, competency_title, :course_rating), 0.001
      assert_equal expected[:label], payload[:course_competency_rule_label]
    end
  ensure
    SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
  end

  private

  def create_course_rating(student:, competency_title:, level:, semester: nil)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => false }
    )

    GradeCompetencyRating.create!(
      grade_import_batch: batch,
      student: student,
      competency_title: competency_title,
      aggregated_level: level,
      aggregation_rule: "max",
      evidence_count: 1
    )
  end

  def assert_link_path_and_query(label, expected_path, expected_query)
    link = css_select("a").find { |anchor| anchor.text.squish == label }
    assert link, "Expected to find #{label.inspect} link"

    uri = URI.parse(link["href"])
    assert_equal expected_path, uri.path

    query = Rack::Utils.parse_nested_query(uri.query)
    expected_query.each do |key, value|
      assert_equal value, query[key], "Expected #{label} query #{key}=#{value.inspect}; found #{query.inspect}"
    end
  end
end
