require "test_helper"
require "tempfile"
require "fileutils"
require "axlsx"

class Admin::CourseCompetencyTargetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    sign_in @admin
    @semester = program_semesters(:fall_2025)
    @temp_paths = []
  end

  teardown do
    @temp_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "import_matrix creates course targets from an uploaded workbook and redirects with a summary" do
    create_competency!("Public and Population Health Assessment")
    create_competency!("Legal & Ethical Bases for Health Services and Health Systems")
    path = build_matrix_workbook

    assert_difference -> { CourseCompetencyTarget.count }, 4 do
      post admin_import_course_competency_target_matrix_path, params: {
        program_semester_id: @semester.id,
        file: Rack::Test::UploadedFile.new(path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", true, original_filename: "matrix.xlsx")
      }
    end

    assert_redirected_to admin_program_setup_path(tab: "course_targets", course_target_program_semester_id: @semester.id)
    follow_redirect!
    assert_match(/4 created/, flash[:notice].to_s)
  end

  test "import_matrix without a file redirects with an alert" do
    post admin_import_course_competency_target_matrix_path, params: { program_semester_id: @semester.id }

    assert_redirected_to admin_program_setup_path(tab: "course_targets", course_target_program_semester_id: @semester.id)
    assert_equal "Choose a semester and a workbook to import.", flash[:alert]
  end

  private

  def create_competency!(title)
    domain = Domain.find_or_create_by!(name: "Course Target Controller Test Domain") do |record|
      record.position = 400
    end

    Competency.find_or_create_by!(title: title) do |record|
      record.domain = domain
      record.position = 400
    end
  end

  def build_matrix_workbook
    path = temp_xlsx_path("controller_matrix")
    package = Axlsx::Package.new

    rows = [
      [ nil, nil, "PHPM 601", "PHPM 602", nil, nil, nil ],
      [ "Domain", "Competency Title", "Fund of Public Health", "Managerial Statistics", "Competency Count", "Lowest level", "Highest level" ],
      [ "I. Health Care Environment and Community", nil, nil, nil, nil, nil, nil ],
      [ nil, "Public and Population Health Assessment", 2, nil, 1, 2, 2 ],
      [ nil, "Legal and Ethical Bases for Health Services and Health Systems", nil, 3, 1, 3, 3 ]
    ]

    package.workbook.add_worksheet(name: "MHA Program - Resident track") { |sheet| rows.each { |row| sheet.add_row row } }
    package.workbook.add_worksheet(name: "MHA Program - Executive track") { |sheet| rows.each { |row| sheet.add_row row } }

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
