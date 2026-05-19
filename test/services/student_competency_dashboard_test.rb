require "test_helper"
require "securerandom"

class StudentCompetencyDashboardTest < ActiveSupport::TestCase
  setup do
    @student = students(:student)
    @admin = users(:admin)
    @competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
  end

  teardown do
    SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
  end

  test "semester options are limited to the student cohort window through current semester" do
    ProgramSemester.create!(name: "Fall 2026")
    ProgramSemester.create!(name: "Spring 2027")

    payload = StudentCompetencyDashboard.new(student: @student).call

    assert_equal [ "Fall 2025" ], payload[:semesters]
    assert_equal "Fall 2025", payload[:filters][:semester]
    refute_includes payload[:semesters], "Spring 2025"
    refute_includes payload[:semesters], "Spring 2026"
  end

  test "semester param outside the cohort window falls back to the allowed default" do
    payload = StudentCompetencyDashboard.new(student: @student, params: { semester: "Spring 2025" }).call

    assert_equal "Fall 2025", payload[:filters][:semester]
  end

  test "semester filter includes only course ratings from the selected import semester" do
    fall = program_semesters(:fall_2025)

    create_course_record(level: 2.0, semester: fall, course_code: "PHPM-601-700")
    create_course_record(level: 4.0, semester: program_semesters(:spring_2025), course_code: "PHPM-602-700")
    create_course_record(level: 5.0, semester: nil, course_code: "PHPM-LEGACY-700")

    payload = StudentCompetencyDashboard.new(student: @student, params: { semester: fall.name }).call
    competency = find_competency(payload, @competency_title)

    assert_in_delta 2.0, competency[:course_rating], 0.001
    assert_equal [ "PHPM-601-700" ], competency[:course_sources].map { |source| source[:course_code] }
  end

  test "future release date hides course ratings and sources from dashboard payload and csv" do
    fall = program_semesters(:fall_2025)
    fall.create_course_grade_release_date!(release_date: 2.days.from_now)
    create_course_record(level: 4.0, semester: fall, course_code: "PHPM-EMBARGO-700")

    payload = StudentCompetencyDashboard.new(student: @student, params: { semester: fall.name }).call
    competency = find_competency(payload, @competency_title)

    refute payload[:course_released]
    assert_nil competency[:course_rating]
    assert_empty competency[:course_sources]
    refute_includes payload[:csv], "PHPM-EMBARGO-700"
  end

  test "advisor legacy ratings stay separate from course-derived ratings" do
    create_advisor_feedback(score: 1.0)
    create_course_record(level: 5.0, semester: program_semesters(:fall_2025), course_code: "PHPM-COURSE-700")

    payload = StudentCompetencyDashboard.new(student: @student, params: { semester: "Fall 2025" }).call
    competency = find_competency(payload, @competency_title)

    assert_in_delta 1.0, competency[:advisor_rating], 0.001
    assert_in_delta 5.0, competency[:course_rating], 0.001
  end

  test "all semesters view includes released course rows and marks unreleased rows as embargoed" do
    fall = program_semesters(:fall_2025)
    spring = program_semesters(:spring_2025)
    second_title = Reports::DataAggregator::COMPETENCY_TITLES.second
    fall.create_course_grade_release_date!(release_date: 2.days.from_now)

    create_course_record(level: 2.0, semester: spring, course_code: "PHPM-SPRING-700")
    create_course_record(level: 5.0, semester: fall, course_code: "PHPM-FALL-700")
    create_course_record(level: 4.0, semester: fall, course_code: "PHPM-EMBARGO-700", competency_title: second_title)

    payload = StudentCompetencyDashboard.new(student: @student, params: { semester: "all" }).call
    released_competency = find_competency(payload, @competency_title)
    embargoed_competency = find_competency(payload, second_title)

    assert_nil payload[:filters][:semester]
    assert_equal "Released course results only", payload[:release_label]
    assert_equal [ "PHPM-SPRING-700" ], released_competency[:course_sources].map { |source| source[:course_code] }
    assert_equal "present", released_competency[:course_status]
    assert_equal "embargoed", embargoed_competency[:course_status]
    assert_empty embargoed_competency[:course_sources]
  end

  test "source filters control datasets and csv columns" do
    payload = StudentCompetencyDashboard.new(
      student: @student,
      params: { semester: "Fall 2025", sources: [ "self", "target" ] }
    ).call

    assert_equal [ "self", "target" ], payload[:visible_sources]
    assert_equal [ "Self", "End Program Target" ], payload[:radar_chart][:datasets].map { |dataset| dataset[:label] }
    assert_includes payload[:csv], "Self Rating"
    assert_includes payload[:csv], "End of Program Target"
    refute_includes payload[:csv], "Course Rating"
  end

  test "summary and row metadata include domain averages timestamps and below target flags" do
    updated_at = Time.zone.local(2026, 5, 1, 10, 0, 0)
    create_self_rating(value: 2, updated_at: updated_at)
    CompetencyTargetLevel.create!(
      program_semester: program_semesters(:fall_2025),
      track: @student.track,
      program_year: @student.program_year,
      competency_title: @competency_title,
      target_level: 4
    )

    payload = StudentCompetencyDashboard.new(student: @student, params: { semester: "Fall 2025" }).call
    competency = find_competency(payload, @competency_title)

    assert_equal "present", competency[:self_status]
    assert_equal updated_at.to_i, competency[:self_updated_at].to_i
    assert competency[:self_below_target]
    assert_includes payload[:summary][:growth_areas].map { |area| area[:title] }, @competency_title
    assert payload[:domain_averages].values.any? { |averages| averages[:self].present? }
  end

  private

  def find_competency(payload, title)
    payload[:domains]
      .flat_map { |domain| domain[:competencies] }
      .find { |competency| competency[:title] == title }
  end

  def create_course_record(level:, semester:, course_code:, competency_title: @competency_title)
    unique = SecureRandom.hex(6)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "#{course_code}.xlsx",
      file_checksum: "student-dashboard-#{unique}",
      status: "processed"
    )
    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: competency_title,
      aggregated_level: level,
      aggregation_rule: "max",
      evidence_count: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Course Evidence #{unique}",
      course_code: course_code,
      competency_title: competency_title,
      raw_grade: 90,
      mapped_level: level.to_i,
      row_number: 2,
      source_key: "student-dashboard-source-#{unique}",
      import_fingerprint: "student-dashboard-fingerprint-#{unique}"
    )
  end

  def create_self_rating(value:, updated_at:)
    survey = surveys(:fall_2025)
    section = SurveySection.find_or_create_by!(
      survey: survey,
      title: SurveySection::MHA_COMPETENCY_SECTION_TITLE
    )
    category = survey.categories.create!(
      name: "Student Competency Ratings #{SecureRandom.hex(4)}",
      section: section
    )
    question = category.questions.create!(
      question_text: @competency_title,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5]
    )

    StudentQuestion.create!(
      student: @student,
      question: question,
      response_value: value.to_s,
      created_at: updated_at,
      updated_at: updated_at
    )
  end

  def create_advisor_feedback(score:)
    survey = surveys(:fall_2025)
    section = SurveySection.find_or_create_by!(
      survey: survey,
      title: SurveySection::MHA_COMPETENCY_SECTION_TITLE
    )
    category = survey.categories.create!(
      name: "Advisor Legacy Ratings #{SecureRandom.hex(4)}",
      section: section
    )
    question = category.questions.create!(
      question_text: @competency_title,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5],
      has_feedback: true
    )

    Feedback.create!(
      student: @student,
      advisor: advisors(:advisor),
      survey: survey,
      category: category,
      question: question,
      average_score: score
    )
  end
end
