# frozen_string_literal: true

module GradeImports
  class FileUploadRouter
    SUPPORTED_EXTENSIONS = %w[.xlsx .xlsm .csv].freeze

    def initialize(uploaded_file)
      @uploaded_file = uploaded_file
    end

    def extension
      File.extname(uploaded_file.original_filename.to_s).downcase
    end

    def supported?
      SUPPORTED_EXTENSIONS.include?(extension)
    end

    def csv?
      extension == ".csv"
    end

    def spreadsheet_extension
      extension.delete_prefix(".")
    end

    def validate!
      return if supported?

      raise "Unsupported file type: #{extension.presence || 'unknown'}. Upload Excel or CSV files."
    end

    private

    attr_reader :uploaded_file
  end
end
