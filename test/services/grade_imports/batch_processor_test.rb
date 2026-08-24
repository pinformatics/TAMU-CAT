require "test_helper"
require "tempfile"
require "fileutils"
require "axlsx"
require "rack/test"

class GradeImports::BatchProcessorTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @student = students(:student)
    @temp_paths = []
  end

  teardown do
    @temp_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "direct competency xlsx uses result as competency level and mastery points as course target" do
    path = build_direct_competency_workbook(
      sheet_name: "PHPM_790_001",
      rows: [
        [
          @student.user.name,
          @student.student_id,
          @student.uin,
          5,
          3
        ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "direct_competency.xlsx") ],
        dry_run: true
      ).call
    end

    evidence = batch.reload.grade_competency_evidences.first
    rating = batch.grade_competency_ratings.first

    assert_equal "completed", batch.status
    assert_equal "PHPM-790-001", evidence.course_code
    assert_equal "", evidence.assignment_name
    assert_equal "Legal & Ethical Bases for Health Services and Health Systems", evidence.competency_title
    assert_equal 5, evidence.mapped_level
    assert_equal 3, evidence.course_target_level
    assert_in_delta 5.0, evidence.raw_grade.to_f, 0.001
    assert_equal 5, rating.aggregated_level
  end

  test "direct competency mastery targets never replace result-derived competency ratings" do
    path = build_direct_competency_workbook(
      sheet_name: "PHPM_790_001",
      rows: [
        [
          @student.user.name,
          @student.student_id,
          @student.uin,
          2,
          5
        ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_excel_file(path, "direct_competency_mastery_target.xlsx") ],
      dry_run: true
    ).call

    evidence = batch.reload.grade_competency_evidences.first
    rating = batch.grade_competency_ratings.first

    assert_equal "completed", batch.status
    assert_equal 2, evidence.mapped_level
    assert_equal 5, evidence.course_target_level
    assert_equal 2, rating.aggregated_level
  end

  test "canvas direct competency workbook imports primary format and ignores hpmc columns" do
    path = build_primary_direct_competency_workbook(
      sheet_name: "PHPM_631_600",
      rows: [
        [ "Stanford, Kelsey Paige", 119270, @student.uin, 5, 3, 1, 3, 3, 3, 1, 3, 5, 3, nil, 3, nil, 3 ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 5 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_direct_competency.xlsx") ],
        dry_run: true
      ).call
    end

    evidences = batch.reload.grade_competency_evidences.order(:competency_title)

    assert_equal "completed", batch.status
    assert_equal 5, batch.grade_competency_ratings.count
    assert evidences.all? { |evidence| evidence.assignment_name == "" }
    assert_equal [ "PHPM-631-600" ], evidences.map(&:course_code).uniq
    assert_equal 0, evidences.count { |evidence| evidence.competency_title.include?("HPMC") }
    assert_equal 3, evidences.find { |evidence| evidence.competency_title == "Policy Analysis" }.mapped_level
    assert_equal 3, evidences.find { |evidence| evidence.competency_title == "Policy Analysis" }.course_target_level
  end

  test "canvas outcomes xlsx imports one evidence row per assessment and uses outcome score as the level" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Discussion blog # 8",
          assessment_id: 2822346,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 3,
          points_possible: 5,
          mastery_score: 3,
          rating: "Capable"
        )
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_outcomes.xlsx") ],
        dry_run: true
      ).call
    end

    evidence = batch.reload.grade_competency_evidences.first
    rating = batch.grade_competency_ratings.first

    assert_equal "completed", batch.status
    assert_equal "PHPM-653-700", evidence.course_code
    assert_equal "Discussion blog # 8", evidence.assignment_name
    assert_equal "Systems Thinking", evidence.competency_title
    assert_equal 3, evidence.mapped_level
    assert_equal 3, evidence.course_target_level
    assert_equal 3, rating.aggregated_level
    assert_equal "canvas_outcomes", batch.grade_import_files.first.parsed_content["mode"]
  end

  test "canvas outcomes xlsx pauses gracefully when the memory guard triggers" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Discussion blog # 8",
          assessment_id: 2822346,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 3
        ),
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Assignment # 4",
          assessment_id: 2822359,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 4
        )
      ]
    )

    batch = create_batch

    with_memory_guard_interval(1) do
      processor = GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_outcomes.xlsx") ],
        dry_run: true
      )
      processor.define_singleton_method(:process_memory_limit_exceeded?) { true }

      assert_no_difference -> { GradeCompetencyEvidence.count } do
        processor.call
      end
    end

    batch.reload
    file = batch.grade_import_files.first
    assert_equal "processing", batch.status
    assert batch.summary["needs_continuation"]
    assert_equal "paused", file.status
    assert_equal 1, file.total_rows
    assert_equal 1, file.parsed_content.dig("grade_sheet_debug", "rows_scanned")
  end

  test "canvas outcomes xlsx resumes automatically after a memory-guard pause and finishes cleanly" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Discussion blog # 8",
          assessment_id: 2822346,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 3
        ),
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Assignment # 4",
          assessment_id: 2822359,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 4
        )
      ]
    )

    batch = create_batch
    uploaded_file = uploaded_excel_file(path, "canvas_outcomes.xlsx")

    with_memory_guard_interval(1) do
      paused_processor = GradeImports::BatchProcessor.new(batch: batch, files: [ uploaded_file ], dry_run: true)
      paused_processor.define_singleton_method(:process_memory_limit_exceeded?) { true }
      paused_processor.call
    end

    assert_equal "processing", batch.reload.status
    assert_equal "paused", batch.grade_import_files.first.status

    assert_difference -> { GradeCompetencyEvidence.count }, 2 do
      GradeImports::BatchProcessor.new(batch: batch, files: [ uploaded_file ], dry_run: true).call
    end

    batch.reload
    assert_equal "completed", batch.status
    assert_not batch.summary["needs_continuation"]
    assert_equal "processed", batch.grade_import_files.first.status
    assert_equal 1, batch.grade_import_files.count, "resuming should reuse the paused file, not create a duplicate"
  end

  test "canvas outcomes csv detects raw export headers and imports" do
    path = build_canvas_outcomes_csv(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Final Policy and Political Strategy Analysis",
          assessment_id: 2824686,
          submission_score: 20,
          learning_outcome_name: "Policy Analysis",
          outcome_score: 5,
          points_possible: 5,
          mastery_score: 4,
          rating: "Mastery"
        )
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_csv_file(path, "canvas_outcomes.csv") ],
        dry_run: true
      ).call
    end

    evidence = batch.reload.grade_competency_evidences.first
    assert_equal "completed", batch.status
    assert_equal "Policy Analysis", evidence.competency_title
    assert_equal 5, evidence.mapped_level
    assert_equal 4, evidence.course_target_level
  end

  test "canvas outcomes rating uses the peak score across multiple assessments of the same competency" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Discussion blog # 8",
          assessment_id: 2822346,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 3
        ),
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Assignment # 4",
          assessment_id: 2822359,
          submission_score: 9,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 4
        )
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 2 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_outcomes_peak.xlsx") ],
        dry_run: true
      ).call
    end

    rating = batch.reload.grade_competency_ratings.first
    assert_equal 1, batch.grade_competency_ratings.count
    assert_equal 4, rating.aggregated_level
    assert_equal 2, rating.evidence_count
  end

  test "canvas outcomes rows with HPMC learning outcomes are ignored" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Exam",
          assessment_id: 111,
          submission_score: 0,
          learning_outcome_name: "HPMC 1",
          outcome_score: 3
        )
      ]
    )

    batch = create_batch

    assert_no_difference -> { GradeCompetencyEvidence.count } do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_outcomes_hpmc.xlsx") ],
        dry_run: true
      ).call
    end

    file = batch.reload.grade_import_files.first
    assert_equal "completed", batch.status
    assert_equal 0, file.error_rows
    assert_equal 1, file.parsed_content.dig("grade_sheet_debug", "rows_skipped_hpmc")
  end

  test "canvas outcomes rows that are ungraded are skipped without creating evidence or errors" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Exam",
          assessment_id: 222,
          submission_score: 0,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 0,
          rating: "Not able to assess"
        )
      ]
    )

    batch = create_batch

    assert_no_difference -> { GradeCompetencyEvidence.count } do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_outcomes_ungraded.xlsx") ],
        dry_run: true
      ).call
    end

    file = batch.reload.grade_import_files.first
    assert_equal "completed", batch.status
    assert_equal 0, file.error_rows
    assert_equal 1, file.parsed_content.dig("grade_sheet_debug", "rows_skipped_ungraded")
  end

  test "canvas outcomes rows with an unrecognized learning outcome name report a missing competency mapping" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Exam",
          assessment_id: 333,
          submission_score: 3,
          learning_outcome_name: "Polciy Analysis",
          outcome_score: 3
        )
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_excel_file(path, "canvas_outcomes_unknown.xlsx") ],
      dry_run: true
    ).call

    file = batch.reload.grade_import_files.first
    mapping_issue = file.parse_errors.find { |error| error["type"] == "missing_competency_mapping" }

    assert_equal "completed_with_errors", batch.status
    assert_equal "missing_competency_mapping", mapping_issue["type"]
    assert_equal "Policy Analysis", mapping_issue["suggested_canonical_competency_title"]
  end

  test "canvas outcomes rows for unmatched students create pending rows" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: "Nobody Here",
          student_id: nil,
          student_sis_id: nil,
          assessment_title: "Exam",
          assessment_id: 444,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 3
        )
      ]
    )

    batch = create_batch

    assert_difference -> { GradeImportPendingRow.pending_student_match.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_outcomes_pending.xlsx") ],
        dry_run: true
      ).call
    end

    pending_row = batch.reload.grade_import_pending_rows.first
    assert_equal "student_name", pending_row.student_identifier_type
    assert_equal "Nobody Here", pending_row.student_name
    assert_equal "Systems Thinking", pending_row.competency_title
  end

  test "re-uploading the same canvas outcomes file suppresses duplicates" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Discussion blog # 8",
          assessment_id: 555,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 3
        )
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_outcomes_dup.xlsx") ],
        dry_run: true
      ).call
    end

    assert_no_difference -> { GradeCompetencyEvidence.count } do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_outcomes_dup.xlsx") ],
        dry_run: true
      ).call
    end

    file = batch.reload.grade_import_files.order(:created_at).last
    assert_equal 1, file.parsed_content.dig("grade_sheet_debug", "duplicate_warning_count")
  end

  test "a fingerprint collision race on insert is suppressed as a duplicate instead of failing the whole file" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: "Nobody Here",
          student_id: nil,
          student_sis_id: nil,
          assessment_title: "Exam",
          assessment_id: 999,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 3
        )
      ]
    )

    batch = create_batch

    # Simulate a genuine DB-level race: two concurrent requests both pass the
    # in-app import_already_recorded? precheck (neither sees the other's row
    # yet), then one insert wins and the other hits the unique index on
    # import_fingerprint as a raw ActiveRecord::RecordNotUnique, bypassing
    # the model's own uniqueness validation (which only a true race can do).
    original_save = GradeImportPendingRow.instance_method(:save!)
    raised = false
    GradeImportPendingRow.define_method(:save!) do |*args, **kwargs|
      if raised
        original_save.bind(self).call(*args, **kwargs)
      else
        raised = true
        raise ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint "index_grade_import_pending_rows_on_import_fingerprint"'
      end
    end

    begin
      assert_no_difference -> { GradeImportPendingRow.count } do
        GradeImports::BatchProcessor.new(
          batch: batch,
          files: [ uploaded_excel_file(path, "canvas_outcomes_race.xlsx") ],
          dry_run: true
        ).call
      end
    ensure
      GradeImportPendingRow.define_method(:save!, original_save)
    end

    file = batch.reload.grade_import_files.first
    assert_equal "completed", batch.status
    assert_equal "processed", file.status
    assert_equal 0, file.error_rows
    assert_equal 1, file.parsed_content.dig("grade_sheet_debug", "duplicate_warning_count")
  end

  test "course offering and competency lookups are cached per batch run instead of re-queried every row" do
    domain = Domain.find_or_create_by!(name: "Cache Test Domain") { |d| d.position = 900 }
    Competency.find_or_create_by!(title: "Systems Thinking") do |c|
      c.domain = domain
      c.position = 900
    end

    rows = 5.times.map do |i|
      canvas_outcomes_row(
        student_name: @student.user.name,
        student_id: @student.student_id,
        student_sis_id: @student.uin,
        assessment_title: "Assessment #{i}",
        assessment_id: 1000 + i,
        submission_score: 3,
        learning_outcome_name: "Systems Thinking",
        outcome_score: 3,
        section_name: "PHPM-653-700",
        course_name: "26 SPRING PHPM 653 700: HEALTH ECON & INS"
      )
    end
    path = build_canvas_outcomes_workbook(rows: rows)

    batch = create_batch
    course_offering_lookups = 0
    competency_lookups = 0

    original_offering_method = CourseOffering.method(:find_or_create_from_code!)
    CourseOffering.define_singleton_method(:find_or_create_from_code!) do |*args, **kwargs|
      course_offering_lookups += 1
      original_offering_method.call(*args, **kwargs)
    end

    original_competency_method = Competency.method(:find_by_normalized_title)
    Competency.define_singleton_method(:find_by_normalized_title) do |*args, **kwargs|
      competency_lookups += 1
      original_competency_method.call(*args, **kwargs)
    end

    begin
      assert_difference -> { GradeCompetencyEvidence.count }, 5 do
        GradeImports::BatchProcessor.new(
          batch: batch,
          files: [ uploaded_excel_file(path, "canvas_outcomes_cache.xlsx") ],
          dry_run: true
        ).call
      end
    ensure
      CourseOffering.define_singleton_method(:find_or_create_from_code!, original_offering_method)
      Competency.define_singleton_method(:find_by_normalized_title, original_competency_method)
    end

    assert_equal 1, course_offering_lookups, "expected the 5 identical-course rows to resolve the course offering only once"
    assert_equal 1, competency_lookups, "expected the 5 identical-competency rows to resolve the competency only once"

    evidences = batch.reload.grade_competency_evidences
    assert_equal [ "PHPM-653-700" ], evidences.map(&:course_code).uniq
  end

  test "canvas outcomes course code is derived per row from section columns" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Exam",
          assessment_id: 666,
          submission_score: 3,
          learning_outcome_name: "Systems Thinking",
          outcome_score: 3,
          section_name: "PHPM-636-699",
          course_name: "26 SPRING PHPM 636 699: PROJ MGMT IN HLTH SYS"
        ),
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Final Policy and Political Strategy Analysis",
          assessment_id: 777,
          submission_score: 5,
          learning_outcome_name: "Policy Analysis",
          outcome_score: 5,
          section_name: "PHPM-640-700",
          course_name: "26 SPRING PHPM 640 700: HEALTH POLICY POLITICS"
        )
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_excel_file(path, "canvas_outcomes_multi_course.xlsx") ],
      dry_run: true
    ).call

    evidences = batch.reload.grade_competency_evidences.order(:competency_title)
    assert_equal [ "PHPM-640-700", "PHPM-636-699" ], evidences.map(&:course_code)
  end

  test "canvas outcomes resolves the singular Health Service Delivery alias" do
    path = build_canvas_outcomes_workbook(
      rows: [
        canvas_outcomes_row(
          student_name: @student.user.name,
          student_id: @student.student_id,
          student_sis_id: @student.uin,
          assessment_title: "Exam",
          assessment_id: 888,
          submission_score: 3,
          learning_outcome_name: "Quantitative Methods for Health Service Delivery",
          outcome_score: 3
        )
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_excel_file(path, "canvas_outcomes_alias.xlsx") ],
      dry_run: true
    ).call

    evidence = batch.reload.grade_competency_evidences.first
    assert_equal "completed", batch.status
    assert_equal "Quantitative Methods for Health Services Delivery", evidence.competency_title
  end

  test "direct competency preview counts pending students separately from pending competency rows" do
    path = build_primary_direct_competency_workbook(
      sheet_name: "PHPM_633_700",
      rows: [
        [ "Missing Student", nil, nil, 5, 3, 1, 3, 3, 3, 1, 3, 5, 3, nil, 3, nil, 3 ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeImportPendingRow.pending_student_match.count }, 5 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "direct_competency_pending_student.xlsx") ],
        dry_run: true
      ).call
    end

    file = batch.reload.grade_import_files.first
    debug = file.parsed_content.fetch("grade_sheet_debug")

    assert_equal 5, file.pending_rows
    assert_equal 1, debug["pending_student_count"]
    assert_equal 5, debug["pending_row_count"]
    assert_equal 0, debug["matched_student_count"]
  end

  test "faculty direct competency csv imports primary format and ignores hpmc columns" do
    path = build_primary_direct_competency_csv(
      rows: [
        [ @student.user.name, @student.student_id, @student.uin, 5, 3, nil, nil, 4, 3, nil, nil, nil, nil, nil, nil, nil, nil ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 2 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_csv_file(path, "Outcomes-26_SPRING_PHPM_633_700__HEALTH_LAW__ETHICS.csv") ],
        dry_run: true
      ).call
    end

    evidences = batch.reload.grade_competency_evidences.order(:competency_title)

    assert_equal "completed", batch.status
    assert_equal [ "PHPM-633-700" ], evidences.map(&:course_code).uniq
    assert_equal [ "Legal & Ethical Bases for Health Services and Health Systems", "Policy Analysis" ], evidences.map(&:competency_title)
    assert_equal 5, evidences.find { |evidence| evidence.competency_title == "Legal & Ethical Bases for Health Services and Health Systems" }.mapped_level
    assert_equal 3, evidences.find { |evidence| evidence.competency_title == "Legal & Ethical Bases for Health Services and Health Systems" }.course_target_level
    assert_equal 4, evidences.find { |evidence| evidence.competency_title == "Policy Analysis" }.mapped_level
    assert_equal 3, evidences.find { |evidence| evidence.competency_title == "Policy Analysis" }.course_target_level
    assert_equal 0, evidences.count { |evidence| evidence.competency_title.include?("HPMC") }
  end

  test "faculty phpm 633 csv imports all result mastery pairs and leaves unmatched students pending" do
    path = build_primary_direct_competency_csv(
      rows: [
        [ @student.user.name, @student.student_id, @student.uin, 5, 2, 5, 2, 3, 3, 3, 3, 2, 3, 100, 5, 100, 5 ],
        [ "Pending, Student", nil, "999888777", 5, 2, 5, 2, 3, 3, 3, 3, 2, 3, 100, 5, 100, 5 ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 5 do
      assert_difference -> { GradeImportPendingRow.count }, 5 do
        GradeImports::BatchProcessor.new(
          batch: batch,
          files: [ uploaded_csv_file(path, "Outcomes-26_SPRING_PHPM_633_700__HEALTH_LAW__ETHICS.csv") ],
          dry_run: true
        ).call
      end
    end

    evidences = batch.reload.grade_competency_evidences.order(:competency_title)
    pending_rows = batch.grade_import_pending_rows.order(:competency_title)
    debug = batch.grade_import_files.first.parsed_content.fetch("grade_sheet_debug")

    assert_equal "completed", batch.status
    assert_equal [ "PHPM-633-700" ], evidences.map(&:course_code).uniq
    assert_equal [ "PHPM-633-700" ], pending_rows.map(&:course_code).uniq
    assert_equal 1, debug["matched_student_count"]
    assert_equal 1, debug["pending_student_count"]
    assert_equal 5, debug["pending_row_count"]
    assert_equal 0, evidences.count { |evidence| evidence.competency_title.include?("HPMC") }
    assert_equal 0, pending_rows.count { |row| row.competency_title.include?("HPMC") }
    assert_equal 2, evidences.find { |evidence| evidence.competency_title == "Delivery, Organization, and Financing of Health Services and Health Systems" }.course_target_level
    assert_equal 2, evidences.find { |evidence| evidence.competency_title == "Problem Solving, Decision Making, and Critical Thinking" }.mapped_level
  end

  test "faculty direct competency csv imports shortened course target and assessed level columns" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student UIN",
        "Public and Population Health Assessment COURSE TARGET",
        "Public and Population Health Assessment ASSESSED LEVEL",
        "Policy Analysis COURSE TARGET",
        "Policy Analysis LEVEL"
      ],
      rows: [
        [ @student.user.name, @student.uin, 4, 3, 5, 4 ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 2 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_csv_file(path, "Outcomes-26S-PHPM-601.csv") ],
        dry_run: true
      ).call
    end

    evidences = batch.reload.grade_competency_evidences.order(:competency_title)
    public_health = evidences.find { |evidence| evidence.competency_title == "Public and Population Health Assessment" }
    policy = evidences.find { |evidence| evidence.competency_title == "Policy Analysis" }

    assert_equal "completed", batch.status
    assert_equal [ "PHPM-601" ], evidences.map(&:course_code).uniq
    assert_equal 3, public_health.mapped_level
    assert_equal 4, public_health.course_target_level
    assert_equal 4, policy.mapped_level
    assert_equal 5, policy.course_target_level
  end

  test "faculty phpm 601 600 csv imports section aware shortened columns" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student UIN",
        "Public and Population Health Assessment COURSE TARGET",
        "Public and Population Health Assessment ASSESSED LEVEL",
        "Delivery, Organization, and Financing of Health Services and Health Systems COURSE TARGET",
        "Delivery, Organization, and Financing of Health Services and Health Systems ASSESSED LEVEL",
        "Organizational Dynamics COURSE TARGET",
        "Organizational Dynamics ASSESSED LEVEL",
        "Systems Thinking COURSE TARGET",
        "Systems Thinking ASSESSED LEVEL"
      ],
      rows: [
        [ @student.user.name, @student.uin, 2, 3, 1, 2, 1, 2, 1, 2 ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 4 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_csv_file(path, "Outcomes-26S-PHPM-601-600.csv") ],
        dry_run: true
      ).call
    end

    file = batch.reload.grade_import_files.first
    evidences = batch.grade_competency_evidences.order(:competency_title)

    assert_equal "completed", batch.status
    assert_equal "PHPM-601-600", file.parsed_content["direct_course_code"]
    assert_empty file.parse_errors
    assert_equal [ "PHPM-601-600" ], evidences.map(&:course_code).uniq
    assert_equal 4, evidences.size
    assert_equal 3, evidences.find { |evidence| evidence.competency_title == "Public and Population Health Assessment" }.mapped_level
    assert_equal 2, evidences.find { |evidence| evidence.competency_title == "Public and Population Health Assessment" }.course_target_level
    assert_equal 2, evidences.find { |evidence| evidence.competency_title == "Systems Thinking" }.mapped_level
    assert_equal 1, evidences.find { |evidence| evidence.competency_title == "Systems Thinking" }.course_target_level
  end

  test "direct competency csv warns when course section is missing from file name" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student UIN",
        "Public and Population Health Assessment COURSE TARGET",
        "Public and Population Health Assessment ASSESSED LEVEL"
      ],
      rows: [
        [ @student.user.name, @student.uin, 4, 3 ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_csv_file(path, "Outcomes-26S-PHPM-601.csv") ],
      dry_run: true
    ).call

    debug = batch.reload.grade_import_files.first.parsed_content.fetch("grade_sheet_debug")
    warning = debug.fetch("mapping_warnings_preview").first

    assert_equal "processed", batch.grade_import_files.first.status
    assert_equal "course_code", warning["type"]
    assert_equal "warning", warning["severity"]
    assert_includes warning["message"], "4-letter department code"
    assert_includes warning["message"], "3-digit section number"
  end

  test "direct competency csv resolves faculty shorthand through competency alias lookup" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student UIN",
        "Public Health Assessment COURSE TARGET",
        "Public Health Assessment ASSESSED LEVEL"
      ],
      rows: [
        [ @student.user.name, @student.uin, 4, 3 ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_csv_file(path, "Outcomes-26S-PHPM-601.csv") ],
        dry_run: true
      ).call
    end

    evidence = batch.reload.grade_competency_evidences.first

    assert_equal "completed", batch.status
    assert_equal "Public and Population Health Assessment", evidence.competency_title
    assert_equal 3, evidence.mapped_level
    assert_equal 4, evidence.course_target_level
  end

  test "faculty direct competency csv invalid assessed levels name assessed level in errors" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student UIN",
        "Public and Population Health Assessment COURSE TARGET",
        "Public and Population Health Assessment ASSESSED LEVEL"
      ],
      rows: [
        [ @student.user.name, @student.uin, 4, -99 ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_csv_file(path, "Outcomes-26S-PHPM-601.csv") ],
      dry_run: true
    ).call

    issue = batch.reload.grade_import_files.first.parse_errors.first

    assert_equal "completed_with_errors", batch.status
    assert_equal "invalid_value", issue["type"]
    assert_equal "Public and Population Health Assessment ASSESSED LEVEL", issue["column"]
    assert_includes issue["message"], "Public and Population Health Assessment assessed level"
    assert_includes issue["message"], "received -99"
    refute_includes issue["message"], "mastery points"
  end

  test "faculty direct competency csv invalid blank assessed level says blank" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student UIN",
        "Public and Population Health Assessment COURSE TARGET",
        "Public and Population Health Assessment ASSESSED LEVEL"
      ],
      rows: [
        [ @student.user.name, @student.uin, 4, " " ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_csv_file(path, "Outcomes-26S-PHPM-601.csv") ],
      dry_run: true
    ).call

    issue = batch.reload.grade_import_files.first.parse_errors.first

    assert_equal "completed_with_errors", batch.status
    assert_equal "missing_value", issue["type"]
    assert_equal "blank", issue["received"]
    assert_includes issue["message"], "Public and Population Health Assessment assessed level"
    assert_includes issue["message"], "received blank"
    refute_includes issue["message"], "mastery points"
  end

  test "faculty direct competency csv rejects invalid student uin values" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student UIN",
        "Public and Population Health Assessment COURSE TARGET",
        "Public and Population Health Assessment ASSESSED LEVEL"
      ],
      rows: [
        [ @student.user.name, "12345", 4, 3 ]
      ]
    )

    batch = create_batch

    assert_no_difference -> { GradeCompetencyEvidence.count } do
      assert_no_difference -> { GradeImportPendingRow.count } do
        GradeImports::BatchProcessor.new(
          batch: batch,
          files: [ uploaded_csv_file(path, "Outcomes-26S-PHPM-601.csv") ],
          dry_run: true
        ).call
      end
    end

    file = batch.reload.grade_import_files.first
    issue = file.parse_errors.first

    assert_equal "completed_with_errors", batch.status
    assert_equal 1, file.error_rows
    assert_equal "invalid_uin", issue["type"]
    assert_equal "Student UIN", issue["column"]
    assert_equal "12345", issue["value"]
    assert_equal "9 digits", issue["expected"]
    assert_includes issue["message"], "Student UIN must be exactly 9 digits"
  end

  test "direct competency csv flags invalid mastery target values as typed review issues" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student ID",
        "Student SIS ID",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis result",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis mastery points"
      ],
      rows: [
        [ @student.user.name, @student.student_id, @student.uin, 4, "five" ],
        [ @student.user.name, @student.student_id, @student.uin, 3, 3 ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_csv_file(path, "invalid_mastery.csv") ],
      dry_run: true
    ).call

    file = batch.reload.grade_import_files.first
    invalid_issue = file.parse_errors.find { |error| error["message"].include?("course target") }

    assert_equal "completed_with_errors", batch.status
    assert_equal 1, file.imported_rows
    assert_equal 1, file.error_rows
    assert_equal "invalid_value", invalid_issue["type"]
    assert_includes invalid_issue["message"], "Policy Analysis course target"
    assert_equal "five", invalid_issue["value"]
    assert_equal "whole number 1-5", invalid_issue["expected"]
    assert_equal "five", invalid_issue["received"]
    assert_includes invalid_issue["correction_hint"], "whole number"
    assert batch.needs_admin_approval?
  end

  test "direct competency csv flags unknown competency columns as mapping issues" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student ID",
        "Student SIS ID",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis result",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis mastery points",
        "EMHA Competencies > Health Care Environment and Community > Polciy Analysis result",
        "EMHA Competencies > Health Care Environment and Community > Polciy Analysis mastery points"
      ],
      rows: [
        [ @student.user.name, @student.student_id, @student.uin, 4, 3, 5, 3 ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_csv_file(path, "unknown_competency.csv") ],
      dry_run: true
    ).call

    file = batch.reload.grade_import_files.first
    mapping_issue = file.parse_errors.find { |error| error["type"] == "missing_competency_mapping" }

    assert_equal "completed_with_errors", batch.status
    assert_equal 1, file.imported_rows
    assert_equal 1, file.error_rows
    assert_equal "missing_competency_mapping", mapping_issue["type"]
    assert_equal "Polciy Analysis", mapping_issue["value"]
    assert_equal "Policy Analysis", mapping_issue["suggested_canonical_competency_title"]
    assert_includes mapping_issue["message"], "Did you mean 'Policy Analysis'?"
    assert_includes mapping_issue["correction_hint"], "db/data/competency_aliases.csv"
    assert_equal 1, file.parsed_content["direct_mapping_issue_count"]
    assert batch.needs_admin_approval?
  end

  test "direct competency rows without numeric identifiers match unique student names" do
    path = build_direct_competency_workbook(
      sheet_name: "PHPM_790_001",
      rows: [
        [
          "User, Student M.",
          nil,
          nil,
          4,
          3
        ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "direct_competency_missing_ids.xlsx") ],
        dry_run: true
      ).call
    end

    evidence = batch.reload.grade_competency_evidences.first
    assert_equal @student.student_id, evidence.student_id
    assert_equal "User, Student M.", evidence.metadata["student_name"]
    assert_equal 4, evidence.mapped_level
    assert_equal 3, evidence.course_target_level
  end

  test "canvas workbook with mapping sheet creates evidence and ratings" do
    path = build_canvas_workbook(
      grade_sheet_name: "PHPM_791_002",
      course_code: "PHPM-791-002",
      rows: [
        [ @student.user.name, 8001, @student.uin, @student.uin, "PHPM-791-002", 94 ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_mapping.xlsx") ],
        dry_run: true
      ).call
    end

    evidence = batch.reload.grade_competency_evidences.first

    assert_equal "completed", batch.status
    assert_equal "PHPM-791-002", evidence.course_code
    assert_equal "Policy Analysis", evidence.competency_title
    assert_equal 5, evidence.mapped_level
    assert_equal 1, batch.grade_competency_ratings.count
  end

  test "canvas xlsx format used by 2026 comp imports mapped values without course targets" do
    path = build_canvas_workbook(
      grade_sheet_name: "PHPM_631_600",
      course_code: "PHPM-631-600",
      rows: [
        [ @student.user.name, 8001, @student.uin, @student.uin, "PHPM-631-600", 75 ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "2026_comp.xlsx") ],
        dry_run: true
      ).call
    end

    file = batch.reload.grade_import_files.first
    evidence = batch.grade_competency_evidences.first

    assert_equal "completed", batch.status
    assert_equal "canvas", file.parsed_content["mode"]
    assert_empty file.parse_errors
    assert_equal "PHPM-631-600", evidence.course_code
    assert_equal "Policy Analysis", evidence.competency_title
    assert_equal 3, evidence.mapped_level
    assert_nil evidence.course_target_level
  end

  test "canvas workbook falls back to unique student name when ids are blank" do
    path = build_canvas_workbook(
      grade_sheet_name: "PHPM_791_002",
      course_code: "PHPM-791-002",
      rows: [
        [ "User, Student M.", nil, nil, nil, "PHPM-791-002", 94 ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      assert_no_difference -> { GradeImportPendingRow.pending_student_match.count } do
        GradeImports::BatchProcessor.new(
          batch: batch,
          files: [ uploaded_excel_file(path, "canvas_mapping_name_fallback.xlsx") ],
          dry_run: true
        ).call
      end
    end

    evidence = batch.reload.grade_competency_evidences.first

    assert_equal "completed", batch.status
    assert_equal @student.student_id, evidence.student_id
    assert_equal "User, Student M.", evidence.metadata["student_name"]
    assert_equal "PHPM-791-002", evidence.course_code
  end

  test "canvas import normalizes inconsistent course codes before matching and storing evidence" do
    path = build_canvas_workbook(
      grade_sheet_name: "Canvas Grades",
      course_code: "PHPM 791 002",
      rows: [
        [ @student.user.name, 8001, @student.uin, @student.uin, "PHPM_791_002 Spring", 94 ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_excel_file(path, "canvas_course_code_cleanup.xlsx") ],
      dry_run: true
    ).call

    evidence = batch.reload.grade_competency_evidences.first

    assert_equal "completed", batch.status
    assert_equal "PHPM-791-002", evidence.course_code
    assert_equal "Policy Analysis", evidence.competency_title
  end

  test "canvas workbook matches scientific notation sis identifiers as uins" do
    @student.update!(uin: "934000152")
    path = build_canvas_workbook(
      grade_sheet_name: "PHPM_631_600",
      course_code: "PHPM-631-600",
      rows: [
        [ @student.user.name, 8001, "9.34000152E8", "9.34000152E8", "PHPM-631-600", 94 ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_excel_file(path, "canvas_scientific_sis.xlsx") ],
      dry_run: true
    ).call

    assert_equal "completed", batch.reload.status
    assert_equal 1, batch.grade_competency_evidences.count
    assert_equal 0, batch.grade_import_pending_rows.pending_student_match.count
    assert_equal @student.student_id, batch.grade_competency_evidences.first.student_id
  ensure
    @student.update!(uin: "123456789")
  end

  test "canvas contains mapping averages all matching assignment columns before mapping level" do
    path = build_canvas_contains_workbook(
      grade_sheet_name: "PHPM_791_002",
      course_code: "PHPM-791-002",
      scores: [ 100, 100, 90, 90, 80, 80, 70 ]
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_contains_mapping.xlsx") ],
        dry_run: true
      ).call
    end

    evidence = batch.reload.grade_competency_evidences.first
    rating = batch.grade_competency_ratings.first

    assert_equal "Data to Decision Lab (7 assignments)", evidence.assignment_name
    assert_in_delta 87.14, evidence.raw_grade.to_f, 0.01
    assert_equal 4, evidence.mapped_level
    assert_equal 7, evidence.metadata["assignment_count"]
    assert_equal 4, rating.aggregated_level
  end

  test "canvas contains percent mapping averages each assignment percent using its own points possible" do
    path = build_canvas_contains_percent_workbook(
      grade_sheet_name: "PHPM_631_600",
      course_code: "PHPM-631-600"
    )

    batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 2 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "canvas_contains_percent_mapping.xlsx") ],
        dry_run: true
      ).call
    end

    interoperability = batch.reload.grade_competency_evidences.find { |row| row.assignment_name.start_with?("Interoperability") }
    data_to_decision = batch.grade_competency_evidences.find { |row| row.assignment_name.start_with?("Data to Decision") }

    assert_equal "Interoperability (1 assignment)", interoperability.assignment_name
    assert_in_delta 83.33, interoperability.raw_grade.to_f, 0.01
    assert_in_delta 83.33, interoperability.metadata["score_for_mapping"].to_f, 0.01
    assert_equal 2, interoperability.mapped_level

    assert_equal "Data to Decision (3 assignments)", data_to_decision.assignment_name
    assert_in_delta 70.0, data_to_decision.raw_grade.to_f, 0.01
    assert_equal 1, data_to_decision.mapped_level
  end

  test "re-uploading the same direct competency file suppresses duplicates" do
    path = build_direct_competency_workbook(
      sheet_name: "PHPM_792_003",
      rows: [
        [
          @student.user.name,
          @student.student_id,
          @student.uin,
          5,
          4
        ]
      ]
    )

    first_batch = create_batch
    second_batch = create_batch
    upload = uploaded_excel_file(path, "duplicate_direct.xlsx")

    GradeImports::BatchProcessor.new(batch: first_batch, files: [ upload ], dry_run: true).call

    assert_no_difference -> { GradeCompetencyEvidence.count } do
      assert_no_difference -> { GradeCompetencyRating.count } do
        GradeImports::BatchProcessor.new(
          batch: second_batch,
          files: [ uploaded_excel_file(path, "duplicate_direct.xlsx") ],
          dry_run: true
        ).call
      end
    end

    duplicate_count = second_batch.grade_import_files.first.parsed_content.dig("grade_sheet_debug", "duplicate_warning_count")

    assert_equal 1, first_batch.reload.grade_competency_evidences.count
    assert_equal 0, second_batch.reload.grade_competency_evidences.count
    assert_equal 1, first_batch.grade_competency_ratings.count
    assert_equal 0, second_batch.grade_competency_ratings.count
    assert_equal 1, duplicate_count
  end

  test "same direct competency data imports for a different course section" do
    path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student UIN",
        "Public and Population Health Assessment COURSE TARGET",
        "Public and Population Health Assessment ASSESSED LEVEL"
      ],
      rows: [
        [ @student.user.name, @student.uin, 4, 3 ]
      ]
    )
    first_batch = create_batch
    second_batch = create_batch

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: first_batch,
        files: [ uploaded_csv_file(path, "Outcomes-26S-PHPM-602-601.csv") ],
        dry_run: true
      ).call
    end

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: second_batch,
        files: [ uploaded_csv_file(path, "Outcomes-26S-PHPM-603-601.csv") ],
        dry_run: true
      ).call
    end

    second_file = second_batch.reload.grade_import_files.first

    assert_equal "PHPM-602-601", first_batch.grade_competency_evidences.first.course_code
    assert_equal "PHPM-603-601", second_batch.grade_competency_evidences.first.course_code
    assert_equal 0, second_file.parsed_content.dig("grade_sheet_debug", "duplicate_warning_count")
  end

  test "duplicate upload warning records previous matching file checksum" do
    path = build_direct_competency_workbook(
      sheet_name: "PHPM_792_003",
      rows: [
        [
          @student.user.name,
          @student.student_id,
          @student.uin,
          5,
          4
        ]
      ]
    )

    first_batch = create_batch
    second_batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: first_batch,
      files: [ uploaded_excel_file(path, "duplicate_warning_first.xlsx") ],
      dry_run: true
    ).call
    GradeImports::BatchProcessor.new(
      batch: second_batch,
      files: [ uploaded_excel_file(path, "duplicate_warning_second.xlsx") ],
      dry_run: true
    ).call

    duplicate_uploads = second_batch.reload.grade_import_files.first.parsed_content["duplicate_file_uploads"]

    assert_equal 1, second_batch.grade_import_files.first.parsed_content["duplicate_file_upload_count"]
    assert_equal first_batch.id, duplicate_uploads.first["batch_id"]
  end

  test "direct competency import keeps valid rows when another row fails validation" do
    path = build_direct_competency_workbook(
      sheet_name: "PHPM_790_001",
      rows: [
        [
          @student.user.name,
          @student.student_id,
          @student.uin,
          9,
          3
        ],
        [
          @student.user.name,
          @student.student_id,
          @student.uin,
          4,
          3
        ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_excel_file(path, "partial_direct_competency.xlsx") ],
      dry_run: true
    ).call

    file = batch.reload.grade_import_files.first

    assert_equal "completed_with_errors", batch.status
    assert_equal 1, file.imported_rows
    assert_equal 1, file.error_rows
    assert_equal 1, batch.grade_competency_evidences.count
    assert_includes file.parse_errors.first["message"], "assessed level must be an integer between 1 and 5"
  end

  test "replace existing files reprocesses corrected upload without duplicating evidence" do
    original_path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student ID",
        "Student SIS ID",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis result",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis mastery points",
        "EMHA Competencies > Management Skills > Communication result",
        "EMHA Competencies > Management Skills > Communication mastery points"
      ],
      rows: [
        [ @student.user.name, @student.student_id, @student.uin, 4, 3, 9, 4 ]
      ]
    )
    corrected_path = build_direct_competency_csv(
      headers: [
        "Student name",
        "Student ID",
        "Student SIS ID",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis result",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis mastery points",
        "EMHA Competencies > Management Skills > Communication result",
        "EMHA Competencies > Management Skills > Communication mastery points"
      ],
      rows: [
        [ @student.user.name, @student.student_id, @student.uin, 4, 3, 5, 4 ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_csv_file(original_path, "corrected_outcomes.csv") ],
      dry_run: true
    ).call

    original_file = batch.reload.grade_import_files.first
    original_evidence_id = batch.grade_competency_evidences.first.id

    assert_equal "completed_with_errors", batch.status
    assert_equal 1, original_file.imported_rows
    assert_equal 1, original_file.error_rows
    assert_equal 1, batch.grade_competency_evidences.count

    assert_no_difference -> { GradeImportFile.count } do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_csv_file(corrected_path, "corrected_outcomes.csv") ],
        dry_run: true,
        replace_existing_files: true
      ).call
    end

    file = batch.reload.grade_import_files.first

    assert_equal "completed", batch.status
    assert_equal 1, batch.grade_import_files.count
    refute GradeImportFile.exists?(original_file.id)
    refute GradeCompetencyEvidence.exists?(original_evidence_id)
    assert_equal 2, batch.grade_competency_evidences.count
    assert_equal 2, batch.grade_competency_ratings.count
    assert_equal 0, file.error_rows
    assert_equal 2, file.imported_rows
  end

  test "narrow grade workbook partially imports valid rows and reports row level issues" do
    path = build_narrow_grade_workbook(
      course_code: "PHPM-633-700",
      rows: [
        [ nil, nil, nil, nil, nil ],
        [ @student.uin, @student.user.email, nil, 95, "PHPM-633-700" ],
        [ @student.uin, @student.user.email, "Case Brief", "not a score", "PHPM-633-700" ],
        [ @student.uin, @student.user.email, "Unmapped Assignment", 95, "PHPM-633-700" ],
        [ "12345", "invalid-uin@example.edu", "Case Brief", 95, "PHPM-633-700" ],
        [ "999888777", "pending@example.edu", "Case Brief", 95, "PHPM-633-700" ],
        [ @student.uin, @student.user.email, "Case Brief", 95, "PHPM-633-700" ],
        [ @student.uin, @student.user.email, "Case Brief", 94, "PHPM-633-700" ]
      ]
    )

    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_excel_file(path, "narrow_grade_import.xlsx") ],
      dry_run: true
    ).call

    file = batch.reload.grade_import_files.first
    debug = file.parsed_content.fetch("grade_sheet_debug")

    assert_equal "completed_with_errors", batch.status
    assert_equal "narrow", file.parsed_content["mode"]
    assert_equal 2, file.imported_rows
    assert_equal 1, file.pending_rows
    assert_equal 4, file.error_rows
    assert_equal 2, batch.grade_competency_evidences.count
    assert_equal 1, batch.grade_import_pending_rows.pending_student_match.count
    assert_equal 8, debug["rows_scanned"]
    assert_equal 1, debug["rows_skipped_blank"]
    assert_equal 1, debug["matched_student_count"]
    assert_equal 1, debug["pending_student_count"]
    assert_equal 1, debug["duplicate_warning_count"]
    assert_includes file.parse_errors.map { |error| error["message"] }, "assignment_name is required"
    assert_includes file.parse_errors.map { |error| error["message"] }, "grade is not numeric"
    assert file.parse_errors.any? { |error| error["type"] == "invalid_uin" }
  end

  test "batch processor helper branches normalize headers course codes and mapping decisions" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    direct_headers = [
      "Student SIS ID",
      "Public and Population Health Assessment ASSESSED LEVEL",
      "Public and Population Health Assessment COURSE TARGET",
      "HPMC competencies > Should Not Import result"
    ]

    mapping = processor.send(:direct_competency_column_mapping, direct_headers)

    assert_equal 1, mapping[:columns].size
    assert_empty mapping[:errors]
    assert_equal "Public and Population Health Assessment", mapping[:columns].first[:competency_title]
    assert_equal "Public and Population Health Assessment COURSE TARGET", mapping[:columns].first[:target_header]
    assert_equal "Public and Population Health Assessment", processor.send(:extract_direct_competency_title, "EMHA Competencies > Public and Population Health Assessment result")
    assert_equal "", processor.send(:extract_direct_competency_title, "Plain Header")
    assert_equal "PHPM-633-700", processor.send(:normalize_course_code, "Outcomes-26_SPRING_PHPM_633_700__HEALTH_LAW__ETHICS.csv")
    refute processor.send(:direct_competency_header?, "hpmc_competencies_ignore_me_result")
    assert processor.send(:direct_competency_header?, "public_and_population_health_assessment_assessed_level")
  end

  test "canvas identifier fallbacks handle shifted headers and student name only rows" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    shifted_headers = [ "Student", "Canvas Key", "Mystery", "Ignored", "Section" ]
    shifted_normalized = shifted_headers.map { |header| processor.send(:normalize_key, header) }
    explicit_headers = [ "Student", "ID", "SIS User ID", "SIS Login ID", "Section" ]
    explicit_normalized = explicit_headers.map { |header| processor.send(:normalize_key, header) }

    assert_equal 1, processor.send(:fallback_student_identifier_index, [ "student", "id" ])
    assert_equal 2, processor.send(:guess_canvas_identifier_position, shifted_headers, shifted_normalized)
    assert_equal 2, processor.send(:guess_canvas_identifier_position, explicit_headers, explicit_normalized)
    assert processor.send(:canvas_non_data_row?, [ "Manual Posting", nil, nil ], id_index: { student_identifier: 1, student_name: 0 })
    assert processor.send(:canvas_non_data_row?, [ "", "", "" ], id_index: { student_identifier: 1, student_name: 0 })
    refute processor.send(:canvas_non_data_row?, [ "User, Student M.", "", @student.uin ], id_index: { student_identifier: 2, student_name: 0 })
  end

  test "mapping helpers cover regex failures percent bounds booleans and invalid ranges" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    regex_mapping = {
      assignment_match_type: "regex",
      assignment_match_value: "(",
      competency_title: "Policy Analysis",
      score_basis: "points",
      min_grade: BigDecimal("0"),
      max_grade: BigDecimal("100"),
      competency_level: 3,
      course_code: "PHPM-633"
    }
    percent_mapping = regex_mapping.merge(
      assignment_match_type: "exact",
      assignment_match_value: "Case Brief",
      score_basis: "percent",
      min_grade: BigDecimal("80"),
      max_grade: BigDecimal("100")
    )

    refute processor.send(:assignment_matches?, mapping: regex_mapping, assignment_name: "Case Brief")
    assert_empty processor.send(:applied_mappings, assignment_name: "Case Brief", course_code: "PHPM-633", raw_points: BigDecimal("4"), points_possible: nil, mapping_rows: [ percent_mapping ])
    assert_equal 100, processor.send(:percent_score, raw_points: BigDecimal("120"), points_possible: BigDecimal("100")).to_i
    assert_nil processor.send(:percent_score, raw_points: BigDecimal("10"), points_possible: BigDecimal("0"))
    assert_equal false, processor.send(:parse_boolean, "no")
    assert_nil processor.send(:parse_boolean, "maybe")

    warnings = processor.send(:validate_mapping_ranges, [
      percent_mapping.merge(source_row_number: 2, min_grade: BigDecimal("0"), max_grade: BigDecimal("49.99"), competency_level: 1),
      percent_mapping.merge(source_row_number: 3, min_grade: BigDecimal("60"), max_grade: BigDecimal("100"), competency_level: 2)
    ])

    assert warnings.any? { |warning| warning[:message].include?("gap") }
  end

  test "unsupported upload records failed file and failed batch summary" do
    path = temp_text_path("unsupported_import", "not a spreadsheet")
    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [ uploaded_text_file(path, "unsupported.txt") ],
      dry_run: true
    ).call

    file = batch.reload.grade_import_files.first

    assert_equal "failed", batch.status
    assert_equal 1, batch.failed_files
    assert_equal "failed", file.status
    assert_equal "file", file.parse_errors.first["type"]
    assert_includes file.parse_errors.first["message"], "Unsupported file type"
    assert_equal false, batch.summary.dig("preview_validation", "commit_ready")
  end

  test "batch status is completed with errors when one file succeeds and one file fails" do
    valid_path = build_direct_competency_workbook(
      sheet_name: "PHPM_790_001",
      rows: [ [ @student.user.name, @student.student_id, @student.uin, 5, 3 ] ]
    )
    invalid_path = temp_text_path("bad_import", "bad")
    batch = create_batch

    GradeImports::BatchProcessor.new(
      batch: batch,
      files: [
        uploaded_excel_file(valid_path, "valid_direct.xlsx"),
        uploaded_text_file(invalid_path, "bad.txt")
      ],
      dry_run: true
    ).call

    assert_equal "completed_with_errors", batch.reload.status
    assert_equal 1, batch.processed_files
    assert_equal 1, batch.failed_files
    assert_equal 1, batch.grade_competency_evidences.count
  end

  test "header and student lookup helpers cover blank cache and failure paths" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    aliases = { name: %w[name full_name], score: %w[score] }
    blank_sheet = fake_sheet([ [] ])
    missing_sheet = fake_sheet([ [ "name" ] ])
    header_sheet = fake_sheet([ [ "ignored" ], [ "Full Name", "Score" ], [ "Student", "5" ] ])

    assert_raises(RuntimeError) { processor.send(:extract_header_index!, blank_sheet, aliases, required: %i[name]) }
    assert_raises(RuntimeError) { processor.send(:extract_header_index!, missing_sheet, aliases, required: %i[name score]) }
    assert_equal({ name: 0 }, processor.send(:extract_header_index!, missing_sheet, aliases, required: %i[name]))

    index, row_number = processor.send(:extract_header_index_from_rows!, header_sheet, aliases, required: %i[name score], max_probe: 3)
    assert_equal 2, row_number
    assert_equal({ name: 0, score: 1 }, index)
    assert_equal [ { name: 0 }, 1 ], processor.send(:resolve_header_index_and_row, nil, { name: 0 }, aliases: aliases, required: %i[name])
    assert_raises(RuntimeError) { processor.send(:extract_header_index_from_rows!, fake_sheet([ [ "nothing" ] ]), aliases, required: %i[name], max_probe: 1) }

    assert_nil processor.send(:find_student, { student_uin: nil, student_email: nil })
    assert_equal @student, processor.send(:find_student, { student_uin: nil, student_email: @student.user.email.upcase })
    assert_equal @student, processor.send(:find_student, { student_uin: nil, student_email: @student.user.email.upcase })
  end

  test "sheet detection helpers return false or diagnostics for malformed sheets" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    bad_sheet = fake_sheet([ [ nil, nil ], [ nil, nil ] ])
    raising_sheet = Object.new
    def raising_sheet.last_row = raise "broken"

    assert_equal [ 1, [] ], processor.send(:detect_any_header_row, bad_sheet)
    refute processor.send(:mapping_sheet_token_match?, raising_sheet)
    refute processor.send(:grade_sheet_token_match?, raising_sheet)
    refute processor.send(:grade_sheet?, bad_sheet)
    refute processor.send(:canvas_grade_sheet?, bad_sheet)
    refute processor.send(:canvas_identifier_present?, bad_sheet)
    assert_raises(RuntimeError) { processor.send(:detect_canvas_header_row, bad_sheet) }
    assert_nil processor.send(:detect_points_possible_row, fake_sheet([ [ "Student" ], [ "No totals" ] ]), start_row: 2)
  end

  test "canvas and identifier helpers cover nil fallback and numeric student id paths" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)

    assert_nil processor.send(:fallback_student_identifier_index, [])
    assert_equal 1, processor.send(:fallback_student_identifier_index, [ "course", "id" ])
    assert_nil processor.send(:guess_canvas_identifier_position, [ "Name", "Score" ], [ "name", "score" ])
    assert_nil processor.send(:find_student_by_canvas_identifier, "not numeric")
    assert_equal @student, processor.send(:find_student_by_canvas_identifier, @student.student_id.to_s)
    assert_equal "abc.1", processor.send(:normalize_numeric_identifier, "abc.1")
    assert_equal "42", processor.send(:normalize_numeric_identifier, "42.0")
    assert_nil processor.send(:parse_integer, Object.new)
    assert_nil processor.send(:parse_level_value, "3.5")
  end

  test "processor helper fallbacks cover blank headers names course offerings and identifiers" do
    batch = create_batch
    processor = GradeImports::BatchProcessor.new(batch: batch, files: [], dry_run: true)
    aliases = { name: %w[name], score: %w[score] }
    sheet = fake_sheet([ [ "ignored" ], [ "Name", "Score" ], [ "Student", "5" ] ])

    assert_equal [ { name: 0, score: 1 }, 2 ], processor.send(:resolve_header_index_and_row, sheet, { index: { name: 0, score: 1 }, row: "2" }, aliases: aliases, required: %i[name score])
    assert_nil processor.send(:parse_decimal, "")
    assert_nil processor.send(:parse_decimal, nil)
    assert_nil processor.send(:parse_integer, "")
    assert_nil processor.send(:parse_level_value, "")

    mappings = [
      { course_code: "PHPM-601", assignment_match_value: "A" },
      { course_code: "PHPM-633", assignment_match_value: "B" }
    ]
    assert_equal mappings, processor.send(:filter_by_course_code, mappings, "")
    assert_equal [ mappings.first ], processor.send(:filter_by_course_code, mappings, "PHPM 601")
    assert_equal mappings, processor.send(:filter_by_course_code, mappings, "PHPM 999")

    grade_file = batch.grade_import_files.create!(file_name: "blank-course.csv", file_checksum: "blank-course-#{SecureRandom.hex(4)}", status: "pending")
    assert_nil processor.send(:course_offering_for, course_code: "", grade_file: grade_file)
    CourseOffering.stub(:table_exists?, false) do
      assert_nil processor.send(:course_offering_for, course_code: "PHPM-601", grade_file: grade_file)
    end

    assert_nil processor.send(:find_student_by_uin, "")
    assert_nil processor.send(:find_student_by_canvas_identifier, "")
    assert_nil processor.send(:find_student_by_canvas_identifier, "not numeric")
    assert_equal @student, processor.send(:find_student_by_canvas_identifier, @student.uin)
    assert_equal @student, processor.send(:find_student_by_name, @student.user.name)
    assert_equal @student, processor.send(:find_student_by_name, @student.user.name)
    assert_nil processor.send(:find_student_by_name, "")
    assert_equal "onename:onename", processor.send(:person_name_signature, "OneName")
    assert_equal "student:user", processor.send(:person_name_signature, "User, Student M.")
    assert_equal [ "student", "user" ], processor.send(:normalized_name_words, "Student-User").first(2)
    assert processor.send(:invalid_uin?, "123")
    refute processor.send(:invalid_uin?, @student.uin)
    refute processor.send(:canvas_identifier_requires_uin?, [ "sis_user_id" ], nil)
    assert processor.send(:canvas_identifier_requires_uin?, [ "sis_user_id" ], 0)
  end

  test "mapping range validation reports overlaps and clean contiguous ranges" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    base = {
      assignment_match_type: "exact",
      assignment_match_value: "Case Brief",
      course_code: "PHPM-633",
      competency_title: "Policy Analysis",
      score_basis: "points"
    }
    overlap_rows = [
      base.merge(source_row_number: 2, min_grade: BigDecimal("0"), max_grade: BigDecimal("75"), competency_level: 1),
      base.merge(source_row_number: 3, min_grade: BigDecimal("70"), max_grade: BigDecimal("100"), competency_level: 2)
    ]
    clean_rows = [
      base.merge(source_row_number: 2, min_grade: BigDecimal("0"), max_grade: BigDecimal("79.99"), competency_level: 1),
      base.merge(source_row_number: 3, min_grade: BigDecimal("80"), max_grade: BigDecimal("100"), competency_level: 2)
    ]

    assert processor.send(:validate_mapping_ranges, overlap_rows).any? { |warning| warning[:message].include?("overlaps") }
    assert_empty processor.send(:validate_mapping_ranges, clean_rows)
  end

  test "direct competency row processor handles blank identifier pending duplicate and missing value branches" do
    batch = create_batch
    grade_file = batch.grade_import_files.create!(
      file_name: "direct-row-branches.csv",
      file_checksum: "direct-row-branches-#{SecureRandom.hex(4)}",
      status: "pending"
    )
    processor = GradeImports::BatchProcessor.new(batch: batch, files: [], dry_run: true)
    headers = [
      "Student name",
      "Student ID",
      "Student SIS ID",
      "Policy Analysis COURSE TARGET",
      "Policy Analysis ASSESSED LEVEL"
    ]
    blank_row = headers.index_with { nil }
    rows = {
      2 => blank_row,
      3 => {
        "Student name" => "",
        "Student ID" => "",
        "Student SIS ID" => "",
        "Policy Analysis COURSE TARGET" => 4,
        "Policy Analysis ASSESSED LEVEL" => 3
      },
      4 => {
        "Student name" => @student.user.name,
        "Student ID" => "",
        "Student SIS ID" => "",
        "Policy Analysis COURSE TARGET" => 4,
        "Policy Analysis ASSESSED LEVEL" => 4
      },
      5 => {
        "Student name" => @student.user.name,
        "Student ID" => "",
        "Student SIS ID" => "",
        "Policy Analysis COURSE TARGET" => 4,
        "Policy Analysis ASSESSED LEVEL" => 5
      },
      6 => {
        "Student name" => @student.user.name,
        "Student ID" => "",
        "Student SIS ID" => "",
        "Policy Analysis COURSE TARGET" => 4,
        "Policy Analysis ASSESSED LEVEL" => ""
      },
      7 => {
        "Student name" => @student.user.name,
        "Student ID" => "",
        "Student SIS ID" => @student.uin,
        "Policy Analysis COURSE TARGET" => "",
        "Policy Analysis ASSESSED LEVEL" => ""
      },
      8 => {
        "Student name" => @student.user.name,
        "Student ID" => "",
        "Student SIS ID" => "12345",
        "Policy Analysis COURSE TARGET" => 4,
        "Policy Analysis ASSESSED LEVEL" => 3
      },
      9 => {
        "Student name" => "Unmatched Import Student",
        "Student ID" => "",
        "Student SIS ID" => "",
        "Policy Analysis COURSE TARGET" => 3,
        "Policy Analysis ASSESSED LEVEL" => 2
      }
    }

    result = processor.send(
      :process_direct_competency_rows!,
      grade_file: grade_file,
      rows: rows,
      headers: headers,
      source_name: "PHPM_601",
      fallback_source_name: "fallback.csv"
    )
    messages = result[:parse_errors].map { |error| error[:message] || error["message"] }

    assert_equal "processed", result[:status]
    assert_equal 2, result[:imported_rows]
    assert_equal 1, result[:pending_rows]
    assert_equal 4, result[:error_rows]
    assert_equal 1, result.dig(:parsed_content, :grade_sheet_debug, :rows_skipped_blank)
    assert_equal 1, result.dig(:parsed_content, :grade_sheet_debug, :pending_student_count)
    assert_equal 1, result.dig(:parsed_content, :grade_sheet_debug, :duplicate_warning_count)
    assert messages.any? { |message| message.include?("Student SIS ID, Student ID, or Student name is required") }
    assert messages.any? { |message| message.include?("Student UIN must be exactly 9 digits") }
    assert messages.any? { |message| message.include?("No direct competency result values") }
    assert_equal "student_name", batch.grade_import_pending_rows.first.student_identifier_type
  end

  test "mapping parser reports malformed rows and keeps valid active mappings" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    sheet = fake_sheet([
      [ "assignment_match_type", "assignment_match_value", "course_code", "competency_title", "score_basis", "min_grade", "max_grade", "competency_level", "active" ],
      [ nil, nil, nil, nil, nil, nil, nil, nil, nil ],
      [ "exact", "Case", "PHPM-601", "Not A Competency", "points", 0, 100, 3, true ],
      [ "exact", "Case", "PHPM-601", "Policy Analysis", "points", "low", 100, 3, true ],
      [ "exact", "Case", "PHPM-601", "Policy Analysis", "points", 0, 100, 9, true ],
      [ "exact", "Case", "PHPM-601", "Policy Analysis", "points", 90, 80, 3, true ],
      [ "exact", "", "PHPM-601", "Policy Analysis", "points", 0, 100, 3, true ],
      [ "exact", "Inactive", "PHPM-601", "Policy Analysis", "points", 0, 100, 3, false ],
      [ "exact", "Bad Basis", "PHPM-601", "Policy Analysis", "raw", 0, 100, 3, true ],
      [ "wildcard", "Bad Match", "PHPM-601", "Policy Analysis", "points", 0, 100, 3, true ],
      [ "", "Default Match", "PHPM-601", "Policy Analysis", "", 0, 100, 3, true ],
      [ "exact", "Valid Full Course", "PHPM-601-700", "Policy Analysis", "points", 0, 100, 3, true ]
    ])
    header_index = {
      index: {
        assignment_match_type: 0,
        assignment_match_value: 1,
        course_code: 2,
        competency_title: 3,
        score_basis: 4,
        min_grade: 5,
        max_grade: 6,
        competency_level: 7,
        active: 8
      },
      row: 1
    }

    mappings, errors, warnings = processor.send(:parse_mapping_rows, sheet, header_index)
    error_messages = errors.map { |error| error[:message] || error["message"] }
    error_types = errors.map { |error| error[:type] || error["type"] }

    assert_equal 2, mappings.size
    assert_equal "exact", mappings.first[:assignment_match_type]
    assert_equal "points", mappings.first[:score_basis]
    assert_equal "PHPM-601", mappings.first[:course_code]
    assert_equal "PHPM-601-700", mappings.second[:course_code]
    assert warnings.any? { |warning| warning[:type] == "course_code" && warning[:message].include?("3-digit section number") }
    assert error_messages.any? { |message| message.include?("min_grade and max_grade") }
    assert error_messages.any? { |message| message.include?("competency_level") }
    assert error_messages.any? { |message| message.include?("max_grade") }
    assert error_messages.any? { |message| message.include?("assignment_match_value") }
    assert error_messages.any? { |message| message.include?("score_basis") }
    assert error_messages.any? { |message| message.include?("assignment_match_type") }

    missing_sheet = fake_sheet([
      [ "assignment_match_type", "assignment_match_value", "course_code", "competency_title", "score_basis", "min_grade", "max_grade", "competency_level", "active" ],
      [ "exact", "Case", "PHPM-601", "Typo Competency", "points", 0, 100, 3, true ]
    ])
    processor.stub(:normalized_competency_title, "Bogus Competency") do
      _missing_mappings, missing_errors, _missing_warnings = processor.send(:parse_mapping_rows, missing_sheet, header_index)
      assert_includes missing_errors.map { |error| error[:type] || error["type"] }, "missing_competency_mapping"
    end
  end

  test "sheet role resolver handles fallback and diagnostic branches" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    grade_sheet = fake_sheet([
      [ "Student", "ID", "SIS User ID", "Section", "Final Project" ],
      [ "Points Possible", nil, nil, nil, 100 ]
    ])
    mapping_sheet = fake_sheet([
      [ "assignment_name", "competency_title", "min_grade", "max_grade", "competency_level" ]
    ])
    unknown_sheet = fake_sheet([
      [ "Random", "Other" ],
      [ "value", "value" ]
    ])

    workbook = fake_workbook("Grades" => grade_sheet, "Mapping" => mapping_sheet)
    assert_equal [ "Grades", "Mapping" ], processor.send(:resolve_grade_and_mapping_sheets!, workbook)

    workbook_with_missed_mapping = fake_workbook("Grades" => grade_sheet, "AlmostMapping" => unknown_sheet)
    assert_equal [ "Grades", "AlmostMapping" ], processor.send(:resolve_grade_and_mapping_sheets!, workbook_with_missed_mapping)

    swapped_grade, swapped_mapping = processor.send(:enforce_sheet_roles!, grade_sheet: mapping_sheet, mapping_sheet: grade_sheet)
    assert_equal grade_sheet, swapped_grade
    assert_equal mapping_sheet, swapped_mapping

    bad_workbook = fake_workbook("Unknown" => unknown_sheet)
    error = assert_raises(RuntimeError) { processor.send(:resolve_grade_and_mapping_sheets!, bad_workbook) }
    assert_includes error.message, "Could not identify grade/mapping sheets"
    assert_includes error.message, "Diagnostics"
  end

  test "canvas identifier fallback helpers cover inferred positions" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)

    assert_nil processor.send(:fallback_student_identifier_index, [ "name", "email" ])
    assert_equal 1, processor.send(:fallback_student_identifier_index, [ "student", "id" ])
    assert_equal 2, processor.send(:guess_canvas_identifier_position, [ "Student", "ID", "SIS User ID" ], [ "student", "id", "sis_user_id" ])
    assert_nil processor.send(:guess_canvas_identifier_position, [ "Name", "Email" ], [ "name", "email" ])
  end

  test "direct competency helpers report missing targets unknown titles and labels" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    headers = [
      "Student name",
      "Student UIN",
      "Mystery Competency result",
      "Communication result",
      "Communication mastery points"
    ]

    mapping = processor.send(:direct_competency_column_mapping, headers)
    messages = mapping[:errors].map { |error| error[:message] }

    assert_equal [ "Communication" ], mapping[:columns].map { |column| column[:competency_title] }
    assert messages.any? { |message| message.include?("Mystery Competency") }
    assert_equal "Communication mastery points", processor.send(:direct_target_header_for, headers, "Communication result")
    assert_nil processor.send(:direct_target_header_for, headers, "Plain Header")
    assert_equal "Student name", processor.send(:direct_student_header_for, headers, :student_name)
    assert_equal "Communication course target", processor.send(:direct_target_label, mapping[:columns].first)
    assert_equal "Communication assessed level", processor.send(:direct_assessed_level_label, mapping[:columns].first)

    missing_target = processor.send(:direct_competency_column_mapping, [ "Policy Analysis result" ])
    assert missing_target[:errors].any? { |error| error[:message].include?("Missing mastery points") }
  end

  test "direct competency helpers report duplicate result and orphan target columns" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    headers = [
      "Student name",
      "Student UIN",
      "Communication result",
      "Communication assessed level",
      "Communication mastery points",
      "Policy Analysis course target"
    ]

    mapping = processor.send(:direct_competency_column_mapping, headers)
    messages = mapping[:errors].map { |error| error[:message] }

    assert_equal [ "Communication" ], mapping[:columns].map { |column| column[:competency_title] }
    assert messages.any? { |message| message.include?("Duplicate result/assessed level columns") }
    assert messages.any? { |message| message.include?("Policy Analysis") && message.include?("no matching result") }
  end

  test "course code filtering and mapping helpers cover blank exact fallback and match types" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    base = {
      assignment_match_value: "Case",
      competency_title: "Policy Analysis",
      score_basis: "points",
      min_grade: BigDecimal("0"),
      max_grade: BigDecimal("100"),
      competency_level: 3
    }
    exact_mapping = base.merge(assignment_match_type: "exact", course_code: "PHPM-601")
    other_mapping = base.merge(assignment_match_type: "contains", assignment_match_value: "Lab", course_code: "PHPM-602")
    regex_mapping = base.merge(assignment_match_type: "regex", assignment_match_value: "Case\\s+\\d+", course_code: nil)

    assert_equal [ exact_mapping, other_mapping ], processor.send(:filter_by_course_code, [ exact_mapping, other_mapping ], nil)
    assert_equal [ exact_mapping ], processor.send(:filter_by_course_code, [ exact_mapping, other_mapping ], "PHPM 601")
    assert_equal [ exact_mapping, other_mapping ], processor.send(:filter_by_course_code, [ exact_mapping, other_mapping ], "PHPM-999")

    assert processor.send(:assignment_matches?, mapping: exact_mapping, assignment_name: "Case")
    refute processor.send(:assignment_matches?, mapping: exact_mapping, assignment_name: "")
    assert processor.send(:assignment_matches?, mapping: other_mapping, assignment_name: "Final Lab Report")
    assert processor.send(:assignment_matches?, mapping: regex_mapping, assignment_name: "Case 12")
  end

  test "contains mapping groups handle empty inputs percent math and grouped labels" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    percent_rows = [
      {
        assignment_match_type: "contains",
        assignment_match_value: "Lab",
        competency_title: "Policy Analysis",
        score_basis: "percent",
        min_grade: BigDecimal("80"),
        max_grade: BigDecimal("100"),
        competency_level: 4,
        course_code: "PHPM-601"
      },
      {
        assignment_match_type: "contains",
        assignment_match_value: "Lab",
        competency_title: "Policy Analysis",
        score_basis: "percent",
        min_grade: BigDecimal("0"),
        max_grade: BigDecimal("79.99"),
        competency_level: 2,
        course_code: "PHPM-601"
      }
    ]
    assignments = [
      { name: "Lab Part 1", raw_points: BigDecimal("8"), points_possible: BigDecimal("10") },
      { name: "Lab Part 2", raw_points: BigDecimal("9"), points_possible: BigDecimal("10") },
      { name: "Other", raw_points: BigDecimal("1"), points_possible: BigDecimal("10") }
    ]

    assert_equal [], processor.send(:applied_contains_mapping_groups, assignments: [], course_code: "PHPM-601", mapping_rows: percent_rows)
    assert_equal [], processor.send(:applied_contains_mapping_groups, assignments: assignments, course_code: "PHPM-601", mapping_rows: [])

    result = processor.send(:applied_contains_mapping_groups, assignments: assignments, course_code: "PHPM-601", mapping_rows: percent_rows)
    assert_equal 1, result.size
    assert_equal "Lab (2 assignments)", result.first[:assignment_name]
    assert_equal 4, result.first[:mapping][:competency_level]
    assert_equal [ "Lab Part 1", "Lab Part 2" ], result.first[:assignment_names]
    assert_nil processor.send(:average_decimal, [])
    assert_equal BigDecimal("2"), processor.send(:average_decimal, [ BigDecimal("1"), nil, BigDecimal("3") ])
    assert_equal "Quiz (1 assignment)", processor.send(:grouped_assignment_name, "Quiz", 1)
  end

  test "identifier validation error payloads source keys and preview summaries cover optional fields" do
    batch = create_batch
    processor = GradeImports::BatchProcessor.new(batch: batch, files: [], dry_run: true)
    grade_file = batch.grade_import_files.create!(
      file_name: "summary.csv",
      file_checksum: "summary-#{SecureRandom.hex(4)}",
      status: "processed",
      imported_rows: 2,
      pending_rows: 1,
      error_rows: 1,
      parse_errors: [ { type: "mapping" }, { "type" => "invalid_uin" }, { message: "fallback" } ],
      parsed_content: {
        "duplicate_file_upload_count" => 2,
        "grade_sheet_debug" => { "duplicate_warning_count" => 3 }
      }
    )

    blank_level = processor.send(:invalid_direct_level_error, 7, label: "Policy target", column: "Policy target", value: "")
    decimal_level = processor.send(:invalid_direct_level_error, 8, label: "Policy score", column: "Policy score", value: "6")
    assert_equal "missing_value", blank_level[:type]
    assert_equal "invalid_value", decimal_level[:type]
    assert_includes decimal_level[:correction_hint], "proficiency scale"

    assert_equal "blank", processor.send(:display_cell_value, nil)
    assert_equal "abc", processor.send(:display_cell_value, " abc ")
    assert_equal "abc:phpm_601:case:policy_analysis:9", processor.send(:build_source_key, identifier: "ABC", course_code: "PHPM 601", assignment_name: "Case", competency_title: "Policy Analysis", row_number: 9)
    assert_equal "#{grade_file.file_checksum}:phpm_601:9:case:policy_analysis", processor.send(:build_import_fingerprint, grade_file: grade_file, row_number: 9, assignment_name: "Case", competency_title: "Policy Analysis", course_code: "PHPM 601")
    assert_equal "#{grade_file.file_checksum}:9:case:policy_analysis", processor.send(:build_legacy_import_fingerprint, grade_file: grade_file, row_number: 9, assignment_name: "Case", competency_title: "Policy Analysis")

    summary = processor.send(:preview_validation_summary, batch.reload)
    assert_equal true, summary[:commit_ready]
    assert_equal 2, summary[:duplicate_file_uploads]
    assert_equal 3, summary[:duplicate_rows]
    assert_equal({ "mapping" => 1, "invalid_uin" => 1, "error" => 1 }, summary[:issue_type_counts])
  end

  test "canvas header and identifier helpers cover false true and scientific notation branches" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)

    refute processor.send(:canvas_header_row?, [ "student", "section", "assignment" ], {})
    refute processor.send(:canvas_header_row?, [ "student", "sis_user_id" ], { student_identifier: 1 })
    assert processor.send(:canvas_header_row?, [ "student", "sis_user_id", "section", "assignment" ], { student_identifier: 1 })
    assert_equal 2, processor.send(:preferred_student_identifier_index, [ "student", "id", "sis_user_id" ])
    assert_equal 1, processor.send(:preferred_student_identifier_index, [ "student", "sis login id read only" ])
    assert_nil processor.send(:preferred_student_identifier_index, [ "student", "email" ])
    assert_equal "123456789", processor.send(:normalize_numeric_identifier, "1.23456789e8")
    assert processor.send(:invalid_uin?, "123")
    refute processor.send(:invalid_uin?, "123456789")
    assert processor.send(:canvas_identifier_requires_uin?, [ "student", "sis_login_id" ], 1)
    refute processor.send(:canvas_identifier_requires_uin?, [ "student", "id" ], 1)
    refute processor.send(:canvas_identifier_requires_uin?, [ "student", "sis_login_id" ], nil)
  end

  test "canvas sheet processor covers skipped rows invalid identifiers pending matches and evidence creation" do
    batch = create_batch
    processor = GradeImports::BatchProcessor.new(batch: batch, files: [], dry_run: true)
    grade_file = batch.grade_import_files.create!(
      file_name: "PHPM-601 canvas.xlsx",
      file_checksum: "canvas-#{SecureRandom.hex(4)}",
      status: "pending"
    )
    sheet = named_fake_sheet(
      "Canvas Grades",
      [
        [ "Student", "ID", "SIS User ID", "SIS Login ID", "Section", "Case Brief" ],
        [ "Points Possible", nil, nil, nil, nil, 100 ],
        [ nil, nil, nil, nil, nil, nil ],
        [ "", "", "", "", "", 90 ],
        [ "Manual Posting", nil, nil, nil, "manual_posting", 90 ],
        [ @student.user.name, "100", "123", "123", "PHPM-601", 90 ],
        [ "Missing, Student", nil, nil, nil, "PHPM-601", 90 ],
        [ @student.user.name, "100", @student.uin, @student.uin, "PHPM-601", nil ],
        [ @student.user.name, "100", @student.uin, @student.uin, "PHPM-601", 92 ]
      ]
    )
    mapping_rows = [
      {
        assignment_match_type: "exact",
        assignment_match_value: "Case Brief",
        competency_title: "Policy Analysis",
        score_basis: "points",
        min_grade: BigDecimal("80"),
        max_grade: BigDecimal("100"),
        competency_level: 4,
        course_code: "PHPM-601"
      }
    ]

    imported_rows, pending_rows, error_rows, errors, debug = processor.send(
      :process_canvas_grade_sheet!,
      grade_file: grade_file,
      grade_sheet: sheet,
      mapping_rows: mapping_rows,
      mapping_errors: [ { type: "mapping_warning_seed", message: "seed" } ],
      mapping_warnings: [ { type: "range", message: "range warning" } ]
    )

    assert_equal 1, imported_rows
    assert_equal 1, pending_rows
    assert_equal 1, error_rows
    assert_equal "canvas", debug[:mode]
    assert_equal 6, debug[:rows_scanned]
    assert_equal 2, debug[:rows_skipped_non_data]
    assert_equal 1, debug[:unmatched_row_count]
    assert_equal 1, debug[:pending_row_count]
    assert_equal 1, debug[:matched_student_count]
    assert errors.any? { |error| error[:type] == "invalid_uin" }
    assert_equal @student.student_id, batch.grade_competency_evidences.first.student_id
    assert_equal "Missing, Student", batch.grade_import_pending_rows.first.student_name
  end

  test "sheet role and row helper branches cover fallbacks and diagnostics" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    mapping_sheet = fake_sheet([
      [ "assignment_name", "competency_title", "min_grade", "max_grade", "competency_level" ],
      [ "Case", "Policy Analysis", 0, 100, 4 ]
    ])
    grade_sheet = fake_sheet([
      [ "Student", "ID", "SIS User ID", "SIS Login ID", "Section", "Case" ],
      [ @student.user.name, 1, @student.uin, @student.uin, "PHPM-601", 95 ]
    ])
    workbook = fake_workbook({ "Mapping" => mapping_sheet, "Grades" => grade_sheet })

    assert_equal [ "Grades", "Mapping" ], processor.send(:resolve_grade_and_mapping_sheets!, workbook)
    assert processor.send(:mapping_sheet_token_match?, mapping_sheet)
    refute processor.send(:mapping_sheet_token_match?, fake_sheet([ [] ]))
    assert processor.send(:grade_sheet_token_match?, grade_sheet)
    refute processor.send(:grade_sheet_token_match?, fake_sheet([ [] ]))
    assert processor.send(:canvas_identifier_present?, grade_sheet)
    refute processor.send(:canvas_identifier_present?, fake_sheet([ [ "Name", "Email" ] ]))

    assert_equal 2, processor.send(
      :guess_canvas_identifier_position,
      [ "Student", "ID", "SIS User ID", "SIS Login ID", "Section" ],
      [ "student", "unexpected_id", "unknown", "unknown_login", "section" ]
    )
    assert_nil processor.send(:fallback_student_identifier_index, [])
    assert_nil processor.send(:fallback_student_identifier_index, [ "name", "email" ])
    assert_equal 1, processor.send(:fallback_student_identifier_index, [ "student", "id" ])

    assert processor.send(:canvas_non_data_row?, [ "Points Possible", nil, nil ], id_index: { student_identifier: 1, student_name: 0 })
    assert processor.send(:canvas_non_data_row?, [ "", nil, nil ], id_index: { student_identifier: 1, student_name: 0 })
    assert processor.send(:canvas_non_data_row?, [ "Student", nil, "read_only" ], id_index: { student_identifier: 1, student_name: 0 })
    refute processor.send(:canvas_non_data_row?, [ @student.user.name, @student.uin, "PHPM-601" ], id_index: { student_identifier: 1, student_name: 0 })
  end

  test "miscellaneous import helper branches cover replacement duplicates names and row details" do
    batch = create_batch
    existing_file = batch.grade_import_files.create!(
      file_name: "replace.csv",
      file_checksum: "replace-#{SecureRandom.hex(4)}",
      status: "processed"
    )
    empty_processor = GradeImports::BatchProcessor.new(batch: batch, files: [], dry_run: true, replace_existing_files: true)
    assert_no_difference "GradeImportFile.count" do
      empty_processor.send(:replace_existing_batch_files!)
    end

    upload = Struct.new(:original_filename).new("replace.csv")
    replacing_processor = GradeImports::BatchProcessor.new(batch: batch, files: [ upload ], dry_run: true, replace_existing_files: true)
    assert_difference "GradeImportFile.count", -1 do
      replacing_processor.send(:replace_existing_batch_files!)
    end
    assert_not GradeImportFile.exists?(existing_file.id)

    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    assert_equal "", processor.send(:person_name_signature, "")
    assert_equal "onlyfirst:onlyfirst", processor.send(:person_name_signature, "Onlyfirst")
    assert_equal "student:user", processor.send(:person_name_signature, "User, Student M.")
    assert_equal "student:user", processor.send(:person_name_signature, "Student User")
    assert_equal "1.5", processor.send(:normalize_numeric_identifier, "1.5")
    assert_equal "123", processor.send(:normalize_numeric_identifier, "1.23E2")
    assert_nil processor.send(:parse_boolean, "")
    assert_equal true, processor.send(:parse_boolean, "YES")
    assert_equal false, processor.send(:parse_boolean, "0")
    assert_nil processor.send(:parse_boolean, "maybe")

    duplicate_batch = create_batch
    duplicate_file = duplicate_batch.grade_import_files.create!(
      file_name: "prior.csv",
      file_checksum: "dupe-checksum",
      status: "processed"
    )
    duplicate_rows = processor.send(:duplicate_uploads_for, "dupe-checksum")
    assert_equal duplicate_file.id, duplicate_rows.first[:file_id]
    assert_equal duplicate_batch.id, duplicate_rows.first[:batch_id]
    assert duplicate_rows.first[:uploaded_at].present?
    assert_equal duplicate_batch.status, duplicate_rows.first[:batch_status]

    error = processor.send(
      :row_error,
      9,
      "Detailed warning",
      type: "mapping_range",
      severity: "warning",
      column: "Score",
      value: "101",
      correction_hint: "Check the score"
    )
    assert_equal "warning", error[:severity]
    assert_equal "Score", error[:column]
    assert_equal "101", error[:value]
    assert_equal "Check the score", error[:correction_hint]
  end

  test "narrow grade sheet processor covers validation pending duplicate and suppression branches" do
    batch = create_batch
    processor = GradeImports::BatchProcessor.new(batch: batch, files: [], dry_run: true)
    grade_file = batch.grade_import_files.create!(
      file_name: "narrow.csv",
      file_checksum: "narrow-#{SecureRandom.hex(4)}",
      status: "pending"
    )
    mapping_rows = [
      {
        assignment_match_type: "exact",
        assignment_match_value: "Case Brief",
        competency_title: "Policy Analysis",
        score_basis: "points",
        min_grade: BigDecimal("80"),
        max_grade: BigDecimal("100"),
        competency_level: 4,
        course_code: "PHPM-601"
      }
    ]
    suppressed_fingerprint = processor.send(
      :build_import_fingerprint,
      grade_file: grade_file,
      row_number: 10,
      assignment_name: "Case Brief",
      competency_title: "Policy Analysis"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: grade_file,
      student: @student,
      course_code: "PHPM-601",
      assignment_name: "Case Brief",
      competency_title: "Policy Analysis",
      raw_grade: 90,
      mapped_level: 4,
      row_number: 99,
      source_key: "preexisting-narrow-source",
      import_fingerprint: suppressed_fingerprint
    )
    sheet = fake_sheet([
      [ "student_uin", "student_email", "assignment_name", "grade", "course_code" ],
      [ nil, nil, nil, nil, nil ],
      [ @student.uin, @student.user.email, "", 90, "PHPM-601" ],
      [ @student.uin, @student.user.email, "Case Brief", "abc", "PHPM-601" ],
      [ @student.uin, @student.user.email, "No Map", 90, "PHPM-601" ],
      [ "123", nil, "Case Brief", 90, "PHPM-601" ],
      [ nil, "missing@example.edu", "Case Brief", 90, "PHPM-601" ],
      [ @student.uin, @student.user.email, "Case Brief", 90, "PHPM-601" ],
      [ @student.uin, @student.user.email, "Case Brief", 95, "PHPM-601" ],
      [ @student.uin, @student.user.email, "Case Brief", 88, "PHPM-601" ]
    ])

    imported_rows, pending_rows, error_rows, errors, debug = processor.send(
      :process_narrow_grade_sheet!,
      grade_file: grade_file,
      grade_sheet: sheet,
      mapping_rows: mapping_rows,
      mapping_errors: [],
      mapping_warnings: [ { type: "range" } ]
    )

    assert_equal 2, imported_rows
    assert_equal 1, pending_rows
    assert_equal 4, error_rows
    assert_equal 9, debug[:rows_scanned]
    assert_equal 1, debug[:rows_skipped_blank]
    assert_equal 1, debug[:pending_student_count]
    assert_equal 2, debug[:duplicate_warning_count]
    assert errors.any? { |error| error[:message].include?("assignment_name is required") }
    assert errors.any? { |error| error[:message].include?("grade is not numeric") }
    assert errors.any? { |error| error[:message].include?("No mapping match") }
    assert errors.any? { |error| error[:type] == "invalid_uin" }
    pending = batch.grade_import_pending_rows.find_by!(student_email: "missing@example.edu")
    assert_equal "email", pending.student_identifier_type
    assert_equal 2, batch.grade_competency_evidences.where.not(import_fingerprint: suppressed_fingerprint).count
  end

  test "direct competency header helpers cover shorthand prefixes and blank extraction" do
    processor = GradeImports::BatchProcessor.new(batch: create_batch, files: [], dry_run: true)
    headers = [
      nil,
      "",
      "HPMC Competencies > Ignore result",
      "Policy Analysis level",
      "Policy Analysis course target",
      "EMHA Competencies > Leadership Skills > Communication result"
    ]

    result_headers = processor.send(:direct_competency_result_headers, headers)

    assert_equal [ "Policy Analysis level", "EMHA Competencies > Leadership Skills > Communication result" ], result_headers
    assert_equal "Policy Analysis", processor.send(:extract_direct_competency_title, "Policy Analysis level")
    assert_equal "Communication", processor.send(:extract_direct_competency_title, "EMHA Competencies > Leadership Skills > Communication result")
    assert_equal "", processor.send(:extract_direct_competency_title, "Plain Header")
    assert_nil processor.send(:direct_competency_header_prefix, "Plain Header", [ "result" ])
    assert_equal "policy_analysis", processor.send(:direct_competency_header_prefix, "Policy Analysis result", [ "result" ])
  end

  private

  def with_memory_guard_interval(interval)
    original_interval = GradeImports::BatchProcessor::MEMORY_GUARD_CHECK_INTERVAL_ROWS
    GradeImports::BatchProcessor.send(:remove_const, :MEMORY_GUARD_CHECK_INTERVAL_ROWS)
    GradeImports::BatchProcessor.const_set(:MEMORY_GUARD_CHECK_INTERVAL_ROWS, interval)
    yield
  ensure
    GradeImports::BatchProcessor.send(:remove_const, :MEMORY_GUARD_CHECK_INTERVAL_ROWS)
    GradeImports::BatchProcessor.const_set(:MEMORY_GUARD_CHECK_INTERVAL_ROWS, original_interval)
  end

  def create_batch
    GradeImportBatch.create!(uploaded_by: @admin, status: "pending", summary: { "dry_run" => true })
  end

  def uploaded_excel_file(path, filename)
    Rack::Test::UploadedFile.new(
      path,
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      true,
      original_filename: filename
    )
  end

  def uploaded_csv_file(path, filename)
    Rack::Test::UploadedFile.new(
      path,
      "text/csv",
      true,
      original_filename: filename
    )
  end

  def uploaded_text_file(path, filename)
    Rack::Test::UploadedFile.new(
      path,
      "text/plain",
      true,
      original_filename: filename
    )
  end

  def temp_text_path(prefix, content)
    file = Tempfile.new([ prefix, ".txt" ])
    path = file.path
    file.close!
    @temp_paths << path
    File.write(path, content)
    path
  end

  def fake_sheet(rows)
    Struct.new(:rows) do
      def last_row = rows.size
      def row(number) = rows[number.to_i - 1] || []
    end.new(rows)
  end

  def named_fake_sheet(name, rows)
    Struct.new(:name, :rows) do
      def last_row = rows.size
      def row(number) = rows[number.to_i - 1] || []
    end.new(name, rows)
  end

  def fake_workbook(sheets_by_name)
    Struct.new(:sheets_by_name) do
      def sheets = sheets_by_name.keys
      def sheet(name) = sheets_by_name.fetch(name)
    end.new(sheets_by_name)
  end

  def build_direct_competency_csv(headers:, rows:)
    file = Tempfile.new([ "direct_competency", ".csv" ])
    path = file.path
    file.close!
    @temp_paths << path

    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |row| csv << row }
    end

    path
  end

  def build_direct_competency_workbook(sheet_name:, rows:)
    path = temp_xlsx_path("direct_competency")
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: sheet_name) do |sheet|
      sheet.add_row [
        "Student name",
        "Student ID",
        "Student SIS ID",
        "EMHA competencies > Legal & Ethical Bases for Health Services and Health Systems result",
        "EMHA competencies > Legal & Ethical Bases for Health Services and Health Systems mastery points",
        "HPMC competencies > Ignore Me result",
        "HPMC competencies > Ignore Me mastery points"
      ]

      rows.each do |row|
        sheet.add_row row + [ 100, 5 ]
      end
    end
    package.serialize(path)
    path
  end

  def build_primary_direct_competency_workbook(sheet_name:, rows:)
    path = temp_xlsx_path("primary_direct_competency")
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: sheet_name) do |sheet|
      sheet.add_row [
        "Student name",
        "Student ID",
        "Student SIS ID",
        "EMHA Competencies > Health Care Environment and Community > Legal and Ethical Bases for Health Services and Health Systems result",
        "EMHA Competencies > Health Care Environment and Community > Legal and Ethical Bases for Health Services and Health Systems mastery points",
        "EMHA Competencies > Health Care Environment and Community > Delivery, Organization, and Financing of Health Services and Health Systems result",
        "EMHA Competencies > Health Care Environment and Community > Delivery, Organization, and Financing of Health Services and Health Systems mastery points",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis result",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis mastery points",
        "EMHA Competencies > Leadership skills > Ethics, Accountability, and Self-Assessment result",
        "EMHA Competencies > Leadership skills > Ethics, Accountability, and Self-Assessment mastery points",
        "EMHA Competencies > Leadership skills > Problem Solving, Decision Making, and Critical Thinking result",
        "EMHA Competencies > Leadership skills > Problem Solving, Decision Making, and Critical Thinking mastery points",
        "HPMC > HPMC 1 result",
        "HPMC > HPMC 1 mastery points",
        "HPMC > HPMC 5 result",
        "HPMC > HPMC 5 mastery points"
      ]

      rows.each { |row| sheet.add_row row }
    end
    package.serialize(path)
    path
  end

  def build_primary_direct_competency_csv(rows:)
    build_direct_competency_csv(
      headers: [
        "Student name",
        "Student ID",
        "Student SIS ID",
        "EMHA Competencies > Health Care Environment and Community > Legal and Ethical Bases for Health Services and Health Systems result",
        "EMHA Competencies > Health Care Environment and Community > Legal and Ethical Bases for Health Services and Health Systems mastery points",
        "EMHA Competencies > Health Care Environment and Community > Delivery, Organization, and Financing of Health Services and Health Systems result",
        "EMHA Competencies > Health Care Environment and Community > Delivery, Organization, and Financing of Health Services and Health Systems mastery points",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis result",
        "EMHA Competencies > Health Care Environment and Community > Policy Analysis mastery points",
        "EMHA Competencies > Leadership skills > Ethics, Accountability, and Self-Assessment result",
        "EMHA Competencies > Leadership skills > Ethics, Accountability, and Self-Assessment mastery points",
        "EMHA Competencies > Leadership skills > Problem Solving, Decision Making, and Critical Thinking result",
        "EMHA Competencies > Leadership skills > Problem Solving, Decision Making, and Critical Thinking mastery points",
        "HPMC > HPMC 1 result",
        "HPMC > HPMC 1 mastery points",
        "HPMC > HPMC 5 result",
        "HPMC > HPMC 5 mastery points"
      ],
      rows: rows
    )
  end

  def canvas_outcomes_headers
    [
      "student name",
      "student id",
      "student sis id",
      "assessment title",
      "assessment id",
      "submission score",
      "learning outcome name",
      "attempt",
      "outcome score",
      "course name",
      "course sis id",
      "section name",
      "section sis id",
      "learning outcome points possible",
      "learning outcome mastery score",
      "learning outcome rating"
    ]
  end

  def build_canvas_outcomes_csv(rows:)
    build_direct_competency_csv(headers: canvas_outcomes_headers, rows: rows)
  end

  def build_canvas_outcomes_workbook(rows:)
    path = temp_xlsx_path("canvas_outcomes")
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "Raw Outcomes") do |sheet|
      sheet.add_row canvas_outcomes_headers
      rows.each { |row| sheet.add_row row }
    end
    package.serialize(path)
    path
  end

  def canvas_outcomes_row(
    student_name:,
    student_id:,
    student_sis_id:,
    assessment_title:,
    assessment_id:,
    submission_score:,
    learning_outcome_name:,
    attempt: 1,
    outcome_score:,
    course_name: "26 SPRING PHPM 653 700: HEALTH ECON & INS",
    course_sis_id: "PHPM.653.202611.700",
    section_name: "PHPM-653-700",
    section_sis_id: "58810.20261",
    points_possible: 5,
    mastery_score: 3,
    rating: "Capable"
  )
    [
      student_name,
      student_id,
      student_sis_id,
      assessment_title,
      assessment_id,
      submission_score,
      learning_outcome_name,
      attempt,
      outcome_score,
      course_name,
      course_sis_id,
      section_name,
      section_sis_id,
      points_possible,
      mastery_score,
      rating
    ]
  end

  def build_canvas_workbook(grade_sheet_name:, course_code:, rows:)
    path = temp_xlsx_path("canvas_mapping")
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: grade_sheet_name) do |sheet|
      sheet.add_row [ "Student", "ID", "SIS User ID", "SIS Login ID", "Section", "Discussion Post 1" ]
      sheet.add_row [ "Points Possible", nil, nil, nil, nil, 100 ]
      rows.each { |row| sheet.add_row row }
    end

    package.workbook.add_worksheet(name: "mapping") do |sheet|
      sheet.add_row [ "assignment_name", "competency_title", "score_basis", "min_grade", "max_grade", "competency_level", "course_code" ]
      sheet.add_row [ "Discussion Post 1", "Policy Analysis", "points", 90, 100, 5, course_code ]
      sheet.add_row [ "Discussion Post 1", "Policy Analysis", "points", 80, 89.99, 4, course_code ]
      sheet.add_row [ "Discussion Post 1", "Policy Analysis", "points", 70, 79.99, 3, course_code ]
      sheet.add_row [ "Discussion Post 1", "Policy Analysis", "points", 60, 69.99, 2, course_code ]
      sheet.add_row [ "Discussion Post 1", "Policy Analysis", "points", 0, 59.99, 1, course_code ]
    end

    package.serialize(path)
    path
  end

  def build_canvas_contains_workbook(grade_sheet_name:, course_code:, scores:)
    path = temp_xlsx_path("canvas_contains_mapping")
    assignment_headers = scores.each_index.map { |index| "Data to Decision Lab #{index + 1}" }

    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: grade_sheet_name) do |sheet|
      sheet.add_row [ "Student", "ID", "SIS User ID", "SIS Login ID", "Section", *assignment_headers ]
      sheet.add_row [ "Points Possible", nil, nil, nil, nil, *Array.new(scores.size, 100) ]
      sheet.add_row [ @student.user.name, 8001, @student.uin, @student.uin, course_code, *scores ]
    end

    package.workbook.add_worksheet(name: "mapping") do |sheet|
      sheet.add_row [ "assignment_match_type", "assignment_match_value", "competency_title", "score_basis", "min_grade", "max_grade", "competency_level", "course_code" ]
      sheet.add_row [ "contains", "Data to Decision Lab", "Policy Analysis", "points", 90, 100, 5, course_code ]
      sheet.add_row [ "contains", "Data to Decision Lab", "Policy Analysis", "points", 80, 89.99, 4, course_code ]
      sheet.add_row [ "contains", "Data to Decision Lab", "Policy Analysis", "points", 70, 79.99, 3, course_code ]
      sheet.add_row [ "contains", "Data to Decision Lab", "Policy Analysis", "points", 60, 69.99, 2, course_code ]
      sheet.add_row [ "contains", "Data to Decision Lab", "Policy Analysis", "points", 0, 59.99, 1, course_code ]
    end

    package.serialize(path)
    path
  end

  def build_canvas_contains_percent_workbook(grade_sheet_name:, course_code:)
    path = temp_xlsx_path("canvas_contains_percent_mapping")
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: grade_sheet_name) do |sheet|
      sheet.add_row [
        "Student",
        "ID",
        "SIS User ID",
        "SIS Login ID",
        "Section",
        "Interoperability Exercise",
        "Data to Decision Part 1",
        "Data to Decision Part 2",
        "Data to Decision Part 3"
      ]
      sheet.add_row [ "Points Possible", nil, nil, nil, nil, 6, 10, 20, 30 ]
      sheet.add_row [ @student.user.name, 8001, @student.uin, @student.uin, course_code, 5, 7, 10, 27 ]
    end

    package.workbook.add_worksheet(name: "mapping") do |sheet|
      sheet.add_row [ "assignment_match_type", "assignment_match_value", "course_code", "competency_title", "score_basis", "min_score", "max_score", "competency_level", "active" ]
      sheet.add_row [ "contains", "Data to Decision", course_code, "Policy Analysis", "percent", 90, 100, 3, true ]
      sheet.add_row [ "contains", "Data to Decision", course_code, "Policy Analysis", "percent", 80, 89.99, 2, true ]
      sheet.add_row [ "contains", "Data to Decision", course_code, "Policy Analysis", "percent", 0, 79.99, 1, true ]
      sheet.add_row [ "contains", "Interoperability", course_code, "Performance Improvement", "percent", 90, 100, 3, true ]
      sheet.add_row [ "contains", "Interoperability", course_code, "Performance Improvement", "percent", 80, 89.99, 2, true ]
      sheet.add_row [ "contains", "Interoperability", course_code, "Performance Improvement", "percent", 0, 79.99, 1, true ]
    end

    package.serialize(path)
    path
  end

  def build_narrow_grade_workbook(course_code:, rows:)
    path = temp_xlsx_path("narrow_grade_import")
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "Grades") do |sheet|
      sheet.add_row [ "student_uin", "student_email", "assignment_name", "grade", "course_code" ]
      rows.each { |row| sheet.add_row row }
    end

    package.workbook.add_worksheet(name: "Mapping") do |sheet|
      sheet.add_row [ "assignment_name", "competency_title", "score_basis", "min_grade", "max_grade", "competency_level", "course_code" ]
      sheet.add_row [ "Case Brief", "Policy Analysis", "points", 90, 100, 5, course_code ]
      sheet.add_row [ "Case Brief", "Policy Analysis", "points", 80, 89.99, 4, course_code ]
      sheet.add_row [ "Case Brief", "Policy Analysis", "points", 70, 79.99, 3, course_code ]
      sheet.add_row [ "Case Brief", "Policy Analysis", "points", 60, 69.99, 2, course_code ]
      sheet.add_row [ "Case Brief", "Policy Analysis", "points", 0, 59.99, 1, course_code ]
    end

    package.serialize(path)
    path
  end

  def temp_xlsx_path(prefix)
    file = Tempfile.new([ prefix, ".xlsx" ])
    path = file.path
    file.close!
    @temp_paths << path
    path
  end
end
