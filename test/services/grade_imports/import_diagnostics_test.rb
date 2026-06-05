require "test_helper"
require "axlsx"
require "fileutils"
require "rack/test"
require "tempfile"

class GradeImports::ImportDiagnosticsTest < ActiveSupport::TestCase
  setup do
    @temp_paths = []
  end

  teardown do
    @temp_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "csv failure returns base error diagnostics without spreadsheet previews" do
    upload = uploaded_file("bad.csv", "text/csv", "Student,Result\n")
    error = RuntimeError.new("CSV failed")

    diagnostics = GradeImports::ImportDiagnostics.failure(uploaded_file: upload, error: error)

    assert_equal "failed_before_parse", diagnostics[:mode]
    assert_equal "RuntimeError", diagnostics[:error_class]
    assert_equal "CSV failed", diagnostics[:error_message]
    refute diagnostics.key?(:sheets)
    refute diagnostics.key?(:sheet_previews)
  end

  test "spreadsheet failure includes sheet names and analyzer previews" do
    upload = uploaded_workbook("bad.xlsx")
    error = ArgumentError.new("Workbook failed")

    diagnostics = GradeImports::ImportDiagnostics.failure(
      uploaded_file: upload,
      error: error,
      sheet_analyzer: ->(name, sheet) { { name: name, last_row: sheet.last_row } }
    )

    assert_equal "failed_before_parse", diagnostics[:mode]
    assert_equal "ArgumentError", diagnostics[:error_class]
    assert_equal "Workbook failed", diagnostics[:error_message]
    assert_equal [ "Competencies" ], diagnostics[:sheets]
    assert_equal [ { name: "Competencies", last_row: 2 } ], diagnostics[:sheet_previews]
  end

  test "diagnostic errors are captured instead of replacing original failure" do
    file = Tempfile.new([ "missing-diagnostics", ".xlsx" ])
    missing_path = file.path
    file.close
    upload = Rack::Test::UploadedFile.new(missing_path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", true, original_filename: "missing.xlsx")
    FileUtils.rm_f(missing_path)
    error = RuntimeError.new("Original parser failure")

    diagnostics = GradeImports::ImportDiagnostics.failure(uploaded_file: upload, error: error)

    assert_equal "Original parser failure", diagnostics[:error_message]
    assert_match(/No such file|does not exist|cannot|zero size/i, diagnostics[:diagnostic_error])
  end

  private

  def uploaded_file(filename, content_type, contents)
    file = Tempfile.new([ "diagnostics", File.extname(filename) ])
    file.write(contents)
    file.close
    @temp_paths << file.path

    Rack::Test::UploadedFile.new(file.path, content_type, true, original_filename: filename)
  end

  def uploaded_workbook(filename)
    file = Tempfile.new([ "diagnostics", ".xlsx" ])
    path = file.path
    file.close!
    @temp_paths << path

    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "Competencies") do |sheet|
      sheet.add_row [ "Student", "Result" ]
      sheet.add_row [ "Jane Example", 4 ]
    end
    package.serialize(path)

    Rack::Test::UploadedFile.new(path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", true, original_filename: filename)
  end
end
