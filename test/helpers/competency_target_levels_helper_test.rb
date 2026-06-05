require "test_helper"

class CompetencyTargetLevelsHelperTest < ActionView::TestCase
  include CompetencyTargetLevelsHelper

  setup do
    @student = students(:student)
    @survey = surveys(:fall_2025)
    @semester = program_semesters(:fall_2025)
    @survey.update!(program_semester: @semester)
    @title = "Communication"
    CompetencyTargetLevel.where(program_semester: @semester, track: @student.track, competency_title: @title).delete_all
  end

  test "effective_competency_target_level falls back and resolves class specific values" do
    question = Question.new(question_text: @title, program_target_level: 2)

    assert_equal 2, effective_competency_target_level(question: nil, survey: @survey, student: @student, fallback: 2)
    assert_equal 2, effective_competency_target_level(question: question, survey: nil, student: @student)
    assert_equal 2, effective_competency_target_level(question: question, survey: @survey, student: nil)
    assert_equal 2, effective_competency_target_level(question: Question.new(question_text: " "), survey: @survey, student: @student, fallback: 2)

    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @student.track,
      class_of: nil,
      competency_title: @title,
      target_level: 3
    )
    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @student.track,
      class_of: @student.program_year,
      competency_title: @title,
      target_level: 5
    )

    assert_equal 5, effective_competency_target_level(question: question, survey: @survey, student: @student)
  end

  test "render_course_competency_context handles blank locked and released entries" do
    assert_nil render_course_competency_context(nil)
    assert_nil render_course_competency_context({ released: true, entries: [] })

    locked_html = render_course_competency_context({ released: false, release_label: nil }).to_s
    assert_includes locked_html, "Course competency evidence"
    assert_includes locked_html, "Not released"

    released_html = render_course_competency_context({
      released: true,
      entries: [
        {
          mastery_level: "4",
          course_code: "PHPM 633-700",
          semester_name: "Fall 2025",
          course_target_levels: [ "3", "4" ],
          source_count: 2
        }
      ]
    }).to_s

    assert_includes released_html, "Mastery level: 4"
    assert_includes released_html, "Course target: 3, 4"
    assert_includes released_html, "2 sources"

    single_html = render_course_competency_context({
      released: true,
      entries: [
        {
          mastery_level: "3",
          course_code: "PHPM 601",
          semester_name: "Spring 2026",
          course_target_levels: [],
          source_count: 1
        }
      ]
    }).to_s

    assert_includes single_html, "Mastery level: 3"
    refute_includes single_html, "Course target:"
    refute_includes single_html, "source"
  end

  test "course competency context hides embargoed rows from students and caches staff rows" do
    question = Question.create!(
      category: categories(:clinical_skills),
      question_text: @title,
      question_order: 99,
      question_type: "dropdown",
      is_required: false
    )
    competency = Competency.find_or_create_by!(title: @title) do |record|
      domain = Domain.find_or_create_by!(name: "Management Skills")
      record.domain = domain
      record.position = 1
    end
    CourseGradeReleaseDate.find_or_create_by!(program_semester: @semester).update!(release_date: 2.days.from_now)
    batch = GradeImportBatch.create!(
      uploaded_by: users(:admin),
      program_semester: @semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "context.csv",
      file_checksum: "context-#{SecureRandom.hex(4)}",
      content_type: "text/csv",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student_id: @student.student_id,
      competency: competency,
      competency_title: @title,
      course_code: "phpm-633-700",
      assignment_name: "Case Brief",
      raw_grade: 95,
      mapped_level: 4,
      course_target_level: 3,
      row_number: 2,
      source_key: "context-source",
      import_fingerprint: "context-fingerprint"
    )

    student_context = course_competency_context_for(question: question, survey: @survey, student: @student, viewer: users(:student))
    staff_context = course_competency_context_for(question: question, survey: @survey, student: @student, viewer: users(:admin))
    cached_staff_context = course_competency_context_for(question: question, survey: @survey, student: @student, viewer: users(:admin))

    assert_equal false, student_context[:released]
    assert_includes student_context[:release_label], "Available"
    assert_equal true, staff_context[:released]
    assert_same staff_context, cached_staff_context
    assert_equal "PHPM 633-700", staff_context[:entries].first[:course_code]
    assert_equal "Fall 2025", staff_context[:entries].first[:semester_name]
  end

  test "private formatting helpers cover blank custom and release values" do
    assert_equal "Visible now", send(:course_release_label, nil)
    assert_includes send(:course_release_label, 1.day.from_now), "Available"
    assert_equal "3.5", send(:format_competency_context_value, 3.50)
    assert_equal "", send(:format_competency_context_value, "")
    assert_equal "Unspecified course", send(:format_course_code_for_context, " ")
    assert_equal "PHPM 633", send(:format_course_code_for_context, "phpm-633")
    assert_equal "Custom Course", send(:format_course_code_for_context, "Custom Course")
    assert_nil send(:canonical_course_competency_title, " ")
    assert_equal @title, send(:canonical_course_competency_title, @title)
  end

  test "target lookup falls back from missing cohort to any configured class year" do
    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @student.track,
      class_of: 2027,
      competency_title: @title,
      target_level: 4
    )
    no_year_student = Struct.new(:student_id, :track, :program_year) do
      def [](key) = key == :track ? track : nil
      def track_before_type_cast = track
    end.new(@student.student_id, @student.track, nil)
    question = Question.new(question_text: @title, program_target_level: 2)

    assert_equal 4, effective_competency_target_level(question: question, survey: @survey, student: no_year_student)
    assert_equal({ @title => 4 }, send(:competency_target_level_lookup, program_semester_id: @semester.id, track: @student.track, class_of: nil))
  end

  test "effective target supports hash-style student track and blank fallback" do
    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @student.track,
      class_of: @student.program_year,
      competency_title: @title,
      target_level: 3
    )
    hash_style_student = Struct.new(:student_id, :program_year, :track_value) do
      def [](key) = key == :track ? track_value : nil
    end.new(@student.student_id, @student.program_year, @student.track)

    assert_nil effective_competency_target_level(question: nil, survey: @survey, student: hash_style_student)
    assert_equal 3, effective_competency_target_level(
      question: Question.new(question_text: @title),
      survey: @survey,
      student: hash_style_student
    )
  end

  test "course competency context returns nil for non competency missing survey or student" do
    question = Question.new(question_text: "Not a competency")

    assert_nil course_competency_context_for(question: question, survey: @survey, student: @student, viewer: users(:admin))
    assert_nil course_competency_context_for(question: Question.new(question_text: @title), survey: nil, student: @student, viewer: users(:admin))
    assert_nil course_competency_context_for(question: Question.new(question_text: @title), survey: @survey, student: nil, viewer: users(:admin))
  end

  test "course evidence release and entries cover released no semester and blank course branches" do
    question = Question.create!(
      category: categories(:clinical_skills),
      question_text: @title,
      question_order: 101,
      question_type: "dropdown",
      is_required: false
    )
    competency = Competency.find_or_create_by!(title: @title) do |record|
      record.domain = Domain.find_or_create_by!(name: "Management Skills")
      record.position = 1
    end
    release = CourseGradeReleaseDate.find_or_create_by!(program_semester: @semester)
    release.update!(release_date: 1.day.ago)
    batch = GradeImportBatch.create!(
      uploaded_by: users(:admin),
      program_semester: @semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "released-context.csv",
      file_checksum: "released-context-#{SecureRandom.hex(4)}",
      status: "processed"
    )
    evidence = batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student_id: @student.student_id,
      competency: competency,
      competency_title: @title,
      course_code: "",
      assignment_name: "Released",
      raw_grade: 5,
      mapped_level: 5,
      course_target_level: nil,
      source_key: "released-context",
      import_fingerprint: "released-context"
    )

    assert_equal true, send(:course_evidence_released?, evidence)
    assert_equal "Not released", send(:embargoed_release_label, [])

    context = course_competency_context_for(question: question, survey: @survey, student: @student, viewer: users(:student))
    assert_equal true, context[:released]
    assert_equal "Unspecified course", context[:entries].first[:course_code]
    assert_empty context[:entries].first[:course_target_levels]
  end

  test "course evidence entry helper skips rows with no aggregate mastery level" do
    batch = OpenStruct.new(program_semester_id: nil, program_semester: nil)
    row = OpenStruct.new(
      grade_import_batch: batch,
      course_code: "",
      mapped_level: nil,
      course_target_level: nil
    )

    assert_equal [], send(:course_competency_evidence_entries, [ row ])
  end

  test "target and competency helpers cover fallback object shapes" do
    no_program_year_student = Struct.new(:student_id, :track_value) do
      def track_before_type_cast = track_value
    end.new(@student.student_id, @student.track)
    survey_without_semester_reader = Object.new
    question_without_text = Struct.new(:program_target_level).new(2)

    assert_equal 2, effective_competency_target_level(
      question: question_without_text,
      survey: @survey,
      student: no_program_year_student,
      fallback: 2
    )
    assert_equal 2, effective_competency_target_level(
      question: Question.new(question_text: @title, program_target_level: 2),
      survey: survey_without_semester_reader,
      student: @student
    )

    Competency.stub(:find_by_normalized_title, nil) do
      assert_equal(
        "Legal & Ethical Bases for Health Services and Health Systems",
        send(:canonical_course_competency_title, "Legal and Ethical Bases for Health Services and Health Systems")
      )
    end
  end

  test "course evidence helpers tolerate rows without batch or semester context" do
    row_without_batch = OpenStruct.new(grade_import_batch: nil)

    assert_equal true, send(:course_evidence_released?, row_without_batch)
    assert_equal "Not released", send(:embargoed_release_label, [ row_without_batch ])

    row = OpenStruct.new(
      grade_import_batch: OpenStruct.new(program_semester_id: nil, program_semester: nil),
      course_code: "PHPM-700",
      mapped_level: 3,
      course_target_level: 2
    )

    entries = send(:course_competency_evidence_entries, [ row ])

    assert_equal 1, entries.size
    assert_equal "PHPM 700", entries.first[:course_code]
    assert_equal "No semester assigned", entries.first[:semester_name]
    assert_equal [ "2" ], entries.first[:course_target_levels]
  end
end
