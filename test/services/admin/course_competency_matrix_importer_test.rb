require "test_helper"
require "tempfile"
require "fileutils"
require "axlsx"
require "rack/test"

class Admin::CourseCompetencyMatrixImporterTest < ActiveSupport::TestCase
  setup do
    @semester = program_semesters(:fall_2025)
    @public_health = create_competency!("Public and Population Health Assessment")
    @legal_ethical = create_competency!("Legal & Ethical Bases for Health Services and Health Systems")
    @temp_paths = []
  end

  teardown do
    @temp_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "imports course targets per track from a coverage matrix workbook" do
    path = build_matrix_workbook

    result = Admin::CourseCompetencyMatrixImporter.call(
      file: uploaded_excel_file(path, "coverage_matrix.xlsx"),
      program_semester: @semester
    )

    assert_equal 2, result.sheets_processed
    assert_equal 4, result.created
    assert_empty result.errors

    residential_offering = CourseOffering.find_or_create_from_code!("PHPM 601", program_semester: @semester)
    executive_offering = CourseOffering.find_or_create_from_code!("PHPM 601", program_semester: @semester)

    residential_target = CourseCompetencyTarget.find_by(course_offering: residential_offering, competency: @public_health, track: "Residential")
    executive_target = CourseCompetencyTarget.find_by(course_offering: executive_offering, competency: @public_health, track: "Executive")

    assert_equal 2, residential_target.target_level
    assert_equal 3, executive_target.target_level
  end

  test "leaves blank cells without creating a target" do
    path = build_matrix_workbook
    Admin::CourseCompetencyMatrixImporter.call(file: uploaded_excel_file(path, "matrix.xlsx"), program_semester: @semester)

    offering = CourseOffering.find_or_create_from_code!("PHPM 601", program_semester: @semester)
    assert_nil CourseCompetencyTarget.find_by(course_offering: offering, competency: @legal_ethical, track: "Residential")
  end

  test "skips the Competency Count row and the proficiency level legend block" do
    path = build_matrix_workbook

    assert_no_difference -> { Competency.count } do
      Admin::CourseCompetencyMatrixImporter.call(file: uploaded_excel_file(path, "matrix.xlsx"), program_semester: @semester)
    end
  end

  test "re-running the same import is idempotent" do
    path = build_matrix_workbook

    Admin::CourseCompetencyMatrixImporter.call(file: uploaded_excel_file(path, "matrix.xlsx"), program_semester: @semester)

    assert_no_difference -> { CourseCompetencyTarget.count } do
      result = Admin::CourseCompetencyMatrixImporter.call(file: uploaded_excel_file(path, "matrix.xlsx"), program_semester: @semester)
      assert_equal 4, result.unchanged
      assert_equal 0, result.created
    end
  end

  test "an unrecognized competency title is reported as an error with a suggestion, without aborting the sheet" do
    path = build_matrix_workbook(with_unknown_competency: true)

    result = Admin::CourseCompetencyMatrixImporter.call(file: uploaded_excel_file(path, "matrix.xlsx"), program_semester: @semester)

    # The Residential sheet's Public Health row fails to resolve, so only its
    # target is skipped; the Legal Ethics row (Residential) and both rows on
    # the Executive sheet still import normally.
    assert_equal 3, result.created
    error = result.errors.find { |e| e[:message].include?("Publc and Population Health") }
    assert error, "expected an unresolved-competency error"
  end

  test "a target value outside 1-5 is reported as an error and not saved" do
    path = build_matrix_workbook(with_invalid_level: true)

    result = Admin::CourseCompetencyMatrixImporter.call(file: uploaded_excel_file(path, "matrix.xlsx"), program_semester: @semester)

    assert result.errors.any? { |e| e[:message].include?("whole number 1-5") }
    offering = CourseOffering.find_or_create_from_code!("PHPM 602", program_semester: @semester)
    assert_nil CourseCompetencyTarget.find_by(course_offering: offering, competency: @legal_ethical, track: "Residential")
  end

  test "ignores sheets that are not track sheets" do
    path = build_matrix_workbook

    result = Admin::CourseCompetencyMatrixImporter.call(file: uploaded_excel_file(path, "matrix.xlsx"), program_semester: @semester)

    assert_equal 2, result.sheets_processed
  end

  private

  def create_competency!(title)
    domain = Domain.find_or_create_by!(name: "Matrix Importer Test Domain") do |record|
      record.position = 300
    end

    Competency.find_or_create_by!(title: title) do |record|
      record.domain = domain
      record.position = 300
    end
  end

  def matrix_sheet_rows(target_for_601:, target_for_602:, with_unknown_competency: false, with_invalid_level: false)
    public_health_title = with_unknown_competency ? "Publc and Population Health Assessment" : "Public and Population Health Assessment"
    legal_602_value = with_invalid_level ? 9 : target_for_602

    [
      [ nil, nil, "PHPM 601", "PHPM 602", "COMPETENCY SELF ASSESS", nil, nil, nil ],
      [ "Domain", "Competency Title", "Fund of Public Health", "Managerial Statistics", "PORTFOLIO REVIEW", "Competency Count", "Lowest level", "Highest level" ],
      [ "I. Health Care Environment and Community", nil, nil, nil, nil, nil, nil, nil ],
      [ nil, public_health_title, target_for_601, nil, nil, 1, target_for_601, target_for_601 ],
      [ nil, "Legal and Ethical Bases for Health Services and Health Systems", nil, legal_602_value, nil, 1, target_for_602, target_for_602 ],
      [ nil, "Competency Count", 4, 4, nil, 8, nil, nil ],
      [ nil, nil, nil, nil, nil, nil, nil, nil ],
      [ nil, "Proficiency Level Titles*: ", nil, nil, nil, nil, nil, nil ],
      [ nil, "Mastery (5)", nil, nil, nil, nil, nil, nil ],
      [ nil, "Experienced (4)", nil, nil, nil, nil, nil, nil ]
    ]
  end

  def build_matrix_workbook(with_unknown_competency: false, with_invalid_level: false)
    path = temp_xlsx_path("coverage_matrix")
    package = Axlsx::Package.new

    package.workbook.add_worksheet(name: "MHA Program - Resident track") do |sheet|
      matrix_sheet_rows(
        target_for_601: 2,
        target_for_602: 3,
        with_unknown_competency: with_unknown_competency,
        with_invalid_level: with_invalid_level
      ).each { |row| sheet.add_row row }
    end

    package.workbook.add_worksheet(name: "MHA Program - Executive track") do |sheet|
      matrix_sheet_rows(target_for_601: 3, target_for_602: 4).each { |row| sheet.add_row row }
    end

    package.workbook.add_worksheet(name: "MHA Competency Model") do |sheet|
      sheet.add_row [ "Domain", "Competency", "Description" ]
      sheet.add_row [ "I. Health Care Environment and Community", "Public and Population Health Assessment", "..." ]
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

  def uploaded_excel_file(path, filename)
    Rack::Test::UploadedFile.new(
      path,
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      true,
      original_filename: filename
    )
  end
end
