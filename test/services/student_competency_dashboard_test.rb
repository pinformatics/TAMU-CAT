require "test_helper"
require "csv"
require "securerandom"
require "ostruct"

class StudentCompetencyDashboardTest < ActiveSupport::TestCase
  setup do
    @student = students(:student)
    @admin = users(:admin)
    @competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    domain = Domain.find_or_create_by!(name: Reports::DataAggregator::REPORT_DOMAINS.first)
    Reports::DataAggregator::COMPETENCY_TITLES.each_with_index do |title, index|
      Competency.find_or_create_by!(title: title) do |competency|
        competency.domain = domain
        competency.position = index
      end
    end
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

  test "committed course evidence appears when derived rating row is missing" do
    ProgramSemester.update_all(current: false)
    spring = program_semesters(:spring_2026)
    spring.update!(current: true)
    unique = SecureRandom.hex(6)
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: spring,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "Outcomes-26S-PHPM-602-601.csv",
      file_checksum: "student-dashboard-evidence-only-#{unique}",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Course Evidence #{unique}",
      course_code: "PHPM-602-601",
      competency_title: @competency_title,
      raw_grade: 90,
      mapped_level: 4,
      row_number: 2,
      source_key: "student-dashboard-evidence-only-source-#{unique}",
      import_fingerprint: "student-dashboard-evidence-only-fingerprint-#{unique}"
    )

    payload = StudentCompetencyDashboard.new(student: @student, params: { semester: "Spring 2026" }).call
    competency = find_competency(payload, @competency_title)

    assert_in_delta 4.0, competency[:course_rating], 0.001
    assert_equal "present", competency[:course_status]
    assert_equal [ "PHPM-602-601" ], competency[:course_sources].map { |source| source[:course_code] }
  end

  test "course data prefers canonical competency id when imported title drifts" do
    records = create_course_record(level: 4.0, semester: program_semesters(:fall_2025), course_code: "PHPM-CANON-700")
    records[:rating].update_columns(competency_title: "Typo #{@competency_title}")
    records[:evidence].update_columns(competency_title: "Typo #{@competency_title}")

    payload = StudentCompetencyDashboard.new(student: @student, params: { semester: "Fall 2025" }).call
    competency = find_competency(payload, @competency_title)

    assert_in_delta 4.0, competency[:course_rating], 0.001
    assert_equal [ "PHPM-CANON-700" ], competency[:course_sources].map { |source| source[:course_code] }
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

  test "checkpoint progress maps matching offerings to named stages" do
    service = StudentCompetencyDashboard.new(student: @student)
    offering = Struct.new(:stage, :survey, :active?, :available_from, :available_until).new(
      "midpoint",
      Struct.new(:program_semester).new(program_semesters(:fall_2025)),
      false,
      2.days.ago,
      1.day.ago
    )

    SurveyOffering.stub(:data_source_ready?, true) do
      SurveyOffering.stub(:where, SurveyOffering) do
        SurveyOffering.stub(:joins, SurveyOffering) do
          SurveyOffering.stub(:merge, SurveyOffering) do
            SurveyOffering.stub(:includes, [ offering ]) do
              service.stub(:self_trend_by_semester, { "Fall 2025" => 4.0 }) do
                service.stub(:course_trend_by_semester, { "Fall 2025" => 3.0 }) do
                  checkpoints = service.send(:checkpoint_progress)

                  midpoint = checkpoints.find { |checkpoint| checkpoint[:key] == "midpoint" }
                  assert_equal %w[initial midpoint final], checkpoints.map { |checkpoint| checkpoint[:key] }
                  assert_equal [ "Fall 2025" ], midpoint[:semesters]
                  assert_equal 4.0, midpoint[:self_average]
                  assert_equal 3.0, midpoint[:course_average]
                  assert_nil checkpoints.find { |checkpoint| checkpoint[:key] == "initial" }[:self_average]
                end
              end
            end
          end
        end
      end
    end
  end

  test "checkpoint progress is unavailable when offering data is missing" do
    service = StudentCompetencyDashboard.new(student: @student)

    SurveyOffering.stub(:data_source_ready?, false) do
      service.stub(:self_trend_by_semester, { "Fall 2025" => 4.0 }) do
        service.stub(:course_trend_by_semester, { "Fall 2025" => 3.0 }) do
          checkpoints = service.send(:checkpoint_progress)

          assert_equal %w[initial midpoint final], checkpoints.map { |checkpoint| checkpoint[:key] }
          assert checkpoints.all? { |checkpoint| checkpoint[:semesters].empty? }
          assert checkpoints.all? { |checkpoint| checkpoint[:self_average].nil? }
          assert checkpoints.all? { |checkpoint| checkpoint[:course_average].nil? }
          refute checkpoints.any? { |checkpoint| checkpoint[:available] }
        end
      end
    end
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

  test "summary keeps strongest and lowest domains separate for small domain sets" do
    [
      { rows: [], strongest: [], lowest: [] },
      { rows: [ [ "Only", 3.5 ] ], strongest: [ "Only" ], lowest: [ "Only" ] },
      { rows: [ [ "Strong", 4.5 ], [ "Low", 2.5 ] ], strongest: [ "Strong" ], lowest: [ "Low" ] },
      { rows: [ [ "Strong", 4.5 ], [ "Middle", 3.5 ], [ "Low", 2.5 ] ], strongest: [ "Strong" ], lowest: [ "Low" ] },
      { rows: [ [ "Strong", 5.0 ], [ "Next", 4.0 ], [ "Second lowest", 2.0 ], [ "Low", 1.0 ] ], strongest: [ "Strong", "Next" ], lowest: [ "Low", "Second lowest" ] }
    ].each do |definition|
      service = StudentCompetencyDashboard.new(student: @student)
      rows = definition[:rows].map do |name, score|
        { name: name, averages: { self: score, course: nil }, competencies: [] }
      end

      service.stub(:domain_rows, rows) do
        summary = service.send(:student_summary)

        assert_equal definition[:strongest], summary[:strongest_domains].map { |domain| domain[:name] }
        assert_equal definition[:lowest], summary[:lowest_domains].map { |domain| domain[:name] }
      end
    end
  end

  test "all semesters view uses graduated student's latest data semester target" do
    ProgramSemester.create!(name: "Fall 2026", current: true)
    @student.update!(status: "graduated", graduated_at: Time.zone.local(2026, 5, 15))

    create_self_rating(
      value: 3,
      updated_at: Time.zone.local(2026, 4, 15, 10, 0, 0),
      survey: surveys(:spring_2026_residential)
    )
    CompetencyTargetLevel.create!(
      program_semester: program_semesters(:spring_2026),
      track: @student.track,
      program_year: @student.program_year,
      competency_title: @competency_title,
      target_level: 3
    )
    CompetencyTargetLevel.create!(
      program_semester: ProgramSemester.find_by!(name: "Fall 2026"),
      track: @student.track,
      program_year: @student.program_year,
      competency_title: @competency_title,
      target_level: 5
    )

    payload = StudentCompetencyDashboard.new(student: @student, params: { semester: "all" }).call
    competency = find_competency(payload, @competency_title)

    assert_equal 3, competency[:end_program_target]
    refute competency[:self_below_target]
  end

  test "change summary compares selected semester with the previous semester" do
    ProgramSemester.update_all(current: false)
    program_semesters(:spring_2026).update!(current: true)

    create_self_rating(value: 2, updated_at: Time.zone.local(2025, 10, 1, 10, 0, 0), survey: surveys(:fall_2025))
    create_self_rating(value: 4, updated_at: Time.zone.local(2026, 3, 1, 10, 0, 0), survey: surveys(:spring_2026_residential))

    payload = StudentCompetencyDashboard.new(
      student: @student,
      params: { semester: "Spring 2026", sources: [ "self" ] }
    ).call

    assert_equal "Spring 2026", payload[:change_summary][:current_semester]
    assert_equal "Fall 2025", payload[:change_summary][:previous_semester]
    assert_includes payload[:change_summary][:headline], "Compared with Fall 2025"
    assert_includes payload[:change_summary][:source_changes].first[:sentence], "Self-assessment average increased from 2 to 4"

    competency_change = payload[:change_summary][:competency_changes].find { |change| change[:title] == @competency_title }
    assert_equal "increased", competency_change[:direction]
    assert_in_delta 2.0, competency_change[:delta], 0.001
  end

  test "semester trend includes self advisor and course series when data exists in the trend period" do
    ProgramSemester.update_all(current: false)
    program_semesters(:spring_2026).update!(current: true)

    create_self_rating(value: 3, updated_at: Time.zone.local(2025, 10, 1, 10, 0, 0), survey: surveys(:fall_2025))
    create_advisor_feedback(score: 4)
    create_course_record(level: 5.0, semester: program_semesters(:fall_2025), course_code: "PHPM-TREND-700")

    payload = StudentCompetencyDashboard.new(
      student: @student,
      params: { semester: "Spring 2026" }
    ).call

    labels = payload[:trend_chart][:datasets].map { |dataset| dataset[:label] }
    assert_includes labels, "Self average"
    assert_includes labels, "Advisor average"
    assert_includes labels, "Course average"
  end

  test "private helpers cover semester source rating and change fallbacks" do
    dashboard = StudentCompetencyDashboard.new(student: @student, params: { sources: "self,unknown,,course" })

    assert_equal [ "self", "course" ], dashboard.send(:selected_source_keys)
    assert_equal [ 2026, 1 ], dashboard.send(:semester_sort_key, "Spring 2026")
    assert_nil dashboard.send(:semester_sort_key, "Not A Term")
    assert_equal "Fall 2025", dashboard.send(:cohort_semester_names).first
    assert_equal "Fall 2025", dashboard.send(:fallback_first_enrollment_semester_name)
    assert_equal({}, dashboard.send(:source_details_for_semester, "unknown", "Fall 2025"))
    assert_nil dashboard.send(:program_target_level_for, "Not a competency")
    assert_equal 4.0, dashboard.send(:normalize_rating, "Level 4")
    assert_nil dashboard.send(:normalize_rating, nil)
    assert_equal "increased", dashboard.send(:change_direction, 1)
    assert_equal "decreased", dashboard.send(:change_direction, -1)
    assert_equal "stayed about the same", dashboard.send(:change_direction, 0)
    assert_includes dashboard.send(:change_sentence, "Self", 2, 4, 2), "increased from 2 to 4"
    assert_includes dashboard.send(:change_sentence, "Self", 4, 4, 0), "stayed about the same"

    blank_student = OpenStruct.new(student_id: 123, program_year: nil, track: nil, track_key: nil)
    blank_dashboard = StudentCompetencyDashboard.new(student: blank_student)
    assert_equal [], blank_dashboard.send(:cohort_semester_names)
    assert_nil blank_dashboard.send(:fallback_first_enrollment_semester_name)

    ProgramSemester.stub(:current, OpenStruct.new(name: "Outside 2099")) do
      dashboard.stub(:semester_options, [ "Spring 2025", "Fall 2025" ]) do
        assert_equal "Fall 2025", dashboard.send(:current_semester_name)
      end
    end
  end

  test "private helpers cover release target duplicate and csv source fallbacks" do
    dashboard = StudentCompetencyDashboard.new(student: @student, params: { semester: "Fall 2025" })

    dashboard.stub(:course_released?, false) do
      assert_includes dashboard.send(:release_label), "Not released"
    end

    dashboard.stub(:filters, { semester: "Missing Semester", all_semesters: false, sources: %w[self course target] }) do
      dashboard.stub(:selected_program_semester, nil) do
        assert_equal [], dashboard.send(:filter_course_rows_by_semester, GradeCompetencyEvidence.all).to_a
      end
    end

    blank_student = OpenStruct.new(student_id: 987_123, program_year: nil, track: nil, track_key: nil)
    blank_dashboard = StudentCompetencyDashboard.new(student: blank_student)
    assert_equal({}, blank_dashboard.send(:target_detail_lookup_for, program_semesters(:fall_2025)))

    first = OpenStruct.new(question_text: @competency_title, response_value: "2", updated_at: 2.days.ago)
    duplicate = OpenStruct.new(question_text: @competency_title, response_value: "5", updated_at: Time.current)
    lookup = dashboard.send(:latest_rating_detail_lookup, [ first, duplicate ], value_method: :response_value)
    assert_equal 2.0, lookup[@competency_title][:value]

    assert_nil dashboard.send(:format_change_score, nil)
    assert_equal "3.25", dashboard.send(:format_change_score, 3.2500)
  end

  test "student summary and csv handle narrow source selections" do
    create_self_rating(value: 4, updated_at: Time.zone.local(2026, 5, 1, 10, 0, 0))

    self_only = StudentCompetencyDashboard.new(student: @student, params: { semester: "Fall 2025", sources: [ "self" ] }).call
    csv = CSV.parse(self_only[:csv], headers: true)

    assert_equal [ "self" ], self_only[:visible_sources]
    assert_equal [ "Self" ], self_only[:radar_chart][:datasets].map { |dataset| dataset[:label] }
    refute_includes csv.headers, "Course Rating"
    refute_includes csv.headers, "End of Program Target"
    assert self_only[:summary][:strongest_domains].any?
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
    rating = batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: competency_title,
      aggregated_level: level,
      aggregation_rule: "max",
      evidence_count: 1
    )
    evidence = batch.grade_competency_evidences.create!(
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

    { rating: rating, evidence: evidence }
  end

  def create_self_rating(value:, updated_at:, survey: surveys(:fall_2025), competency_title: @competency_title)
    section = SurveySection.find_or_create_by!(
      survey: survey,
      title: SurveySection::MHA_COMPETENCY_SECTION_TITLE
    )
    category = survey.categories.create!(
      name: "Student Competency Ratings #{SecureRandom.hex(4)}",
      section: section
    )
    question = category.questions.create!(
      question_text: competency_title,
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
