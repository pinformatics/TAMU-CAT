# frozen_string_literal: true

require "roo"

module GradeImports
  class ImportDiagnostics
    def self.failure(uploaded_file:, error:, sheet_analyzer: nil)
      new(uploaded_file: uploaded_file, error: error, sheet_analyzer: sheet_analyzer).failure
    end

    def initialize(uploaded_file:, error:, sheet_analyzer: nil)
      @uploaded_file = uploaded_file
      @error = error
      @sheet_analyzer = sheet_analyzer
    end

    def failure
      diagnostics = {
        mode: "failed_before_parse",
        error_class: error.class.name,
        error_message: error.message
      }

      begin
        router = FileUploadRouter.new(uploaded_file)
        return diagnostics if router.csv?

        workbook = Roo::Spreadsheet.open(uploaded_file.path, extension: router.spreadsheet_extension)
        sheet_names = workbook.sheets.map(&:to_s)
        diagnostics[:sheets] = sheet_names
        diagnostics[:sheet_previews] = sheet_names.map do |name|
          sheet = workbook.sheet(name)
          sheet_analyzer ? sheet_analyzer.call(name, sheet) : { name: name }
        end
      rescue StandardError => diagnostics_error
        diagnostics[:diagnostic_error] = "#{diagnostics_error.class}: #{diagnostics_error.message}"
      end

      diagnostics
    end

    private

    attr_reader :uploaded_file, :error, :sheet_analyzer
  end
end
