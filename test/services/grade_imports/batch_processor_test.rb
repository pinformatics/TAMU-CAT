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

  test "direct competency mastery points never replace result-derived competency ratings" do
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

  test "faculty direct competency csv imports primary format and ignores hpmc columns" do
    path = build_primary_direct_competency_csv(
      rows: [
        [ @student.user.name, @student.student_id, @student.uin, 5, 3, nil, 3, 4, 3, nil, 3, nil, 3, nil, 3, nil, 3 ]
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
    assert_equal 0, evidences.count { |evidence| evidence.competency_title.include?("HPMC") }
  end

  test "direct competency csv flags invalid mastery values as typed review issues" do
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
    invalid_issue = file.parse_errors.find { |error| error["message"].include?("mastery points") }

    assert_equal "completed_with_errors", batch.status
    assert_equal 1, file.imported_rows
    assert_equal 1, file.error_rows
    assert_equal "invalid_value", invalid_issue["type"]
    assert_equal "five", invalid_issue["value"]
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
    mapping_issue = file.parse_errors.find { |error| error["message"].include?("Unknown direct competency column") }

    assert_equal "completed_with_errors", batch.status
    assert_equal 1, file.imported_rows
    assert_equal 1, file.error_rows
    assert_equal "mapping", mapping_issue["type"]
    assert_equal "Polciy Analysis", mapping_issue["value"]
    assert_equal 1, file.parsed_content["direct_mapping_issue_count"]
    assert batch.needs_admin_approval?
  end

  test "direct competency rows without numeric identifiers are staged for name-based reconciliation" do
    path = build_direct_competency_workbook(
      sheet_name: "PHPM_790_001",
      rows: [
        [
          @student.user.name,
          nil,
          nil,
          4,
          3
        ]
      ]
    )

    batch = create_batch

    assert_difference -> { GradeImportPendingRow.pending_student_match.count }, 1 do
      GradeImports::BatchProcessor.new(
        batch: batch,
        files: [ uploaded_excel_file(path, "direct_competency_missing_ids.xlsx") ],
        dry_run: true
      ).call
    end

    pending = batch.reload.grade_import_pending_rows.first
    assert_equal "student_name", pending.student_identifier_type
    assert_equal @student.user.name, pending.student_name
    assert_equal 4, pending.mapped_level
    assert_equal 3, pending.course_target_level

    assert_difference -> { GradeCompetencyEvidence.count }, 1 do
      assert_equal 1, GradeImports::PendingRowReconciler.call(student: @student)
    end

    assert_equal "reconciled", pending.reload.status
    assert_equal @student.student_id, pending.matched_student_id
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
    assert_includes file.parse_errors.first["message"], "result must be an integer between 1 and 5"
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

  private

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

  def temp_xlsx_path(prefix)
    file = Tempfile.new([ prefix, ".xlsx" ])
    path = file.path
    file.close!
    @temp_paths << path
    path
  end
end
