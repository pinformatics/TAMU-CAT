require "roo"
require "bigdecimal"

# Parses a "Program Competency-Course Matrix" workbook (one sheet per track,
# a competency x course grid of 1-5 course-level targets) and upserts
# CourseCompetencyTarget rows from it.
class Admin::CourseCompetencyMatrixImporter
  Result = Struct.new(:sheets_processed, :created, :updated, :unchanged, :errors, keyword_init: true)

  # The first two columns are always "Domain" and "Competency Title" (never
  # course columns). One real matrix file puts a footnote marker
  # ("*Direct Measure of Student Competency") in the competency-title column
  # of the course-number row, which would otherwise be misread as a course
  # code, so these two columns are excluded by position, not just by
  # blank-check.
  NON_COURSE_COLUMN_COUNT = 2

  def self.call(file:, program_semester:)
    new(file: file, program_semester: program_semester).call
  end

  def initialize(file:, program_semester:)
    @file = file
    @program_semester = program_semester
    @sheets_processed = 0
    @created = 0
    @updated = 0
    @unchanged = 0
    @errors = []
  end

  def call
    workbook = Roo::Spreadsheet.open(file.path, extension: extension)

    workbook.sheets.each do |sheet_name|
      track = track_for_sheet(sheet_name)
      next if track.blank?

      process_sheet!(sheet_name, workbook.sheet(sheet_name), track)
      @sheets_processed += 1
    end

    Result.new(sheets_processed: @sheets_processed, created: @created, updated: @updated, unchanged: @unchanged, errors: @errors)
  end

  private

  attr_reader :file, :program_semester

  def extension
    File.extname(file.original_filename.to_s).delete_prefix(".")
  end

  def track_for_sheet(sheet_name)
    normalized = sheet_name.to_s.downcase
    key = if normalized.include?("resident") || normalized.include?("rmha")
      "residential"
    elsif normalized.include?("executive") || normalized.include?("emha")
      "executive"
    end
    return if key.blank?

    ProgramTrack.name_for_key(key)
  end

  def process_sheet!(sheet_name, sheet, track)
    header_row_number, header_values = find_header_row(sheet)
    if header_row_number.nil?
      @errors << { sheet: sheet_name, row: nil, message: "Could not find a header row containing 'Domain' and 'Competency Title'." }
      return
    end

    course_number_row = header_row_number > 1 ? sheet.row(header_row_number - 1) : []
    course_columns = build_course_columns(header_values, course_number_row)

    ((header_row_number + 1)..sheet.last_row.to_i).each do |row_number|
      process_row!(sheet_name, row_number, sheet.row(row_number), course_columns, track)
    end
  end

  def find_header_row(sheet)
    max_probe = [ sheet.last_row.to_i, 8 ].min
    (1..max_probe).each do |row_number|
      values = sheet.row(row_number)
      normalized = values.map { |value| normalize_key(value) }
      next unless normalized.include?("domain") && normalized.include?("competency_title")

      return [ row_number, values ]
    end

    nil
  end

  def build_course_columns(header_values, course_number_row)
    columns = {}

    header_values.each_with_index do |header, index|
      next if index < NON_COURSE_COLUMN_COUNT
      next if normalize_key(header).blank?

      course_code = course_number_row[index].to_s.strip
      next if course_code.blank?
      next if normalize_key(course_code).include?("self_assess")

      columns[index] = course_code
    end

    columns
  end

  def process_row!(sheet_name, row_number, values, course_columns, track)
    title = values[1].to_s.strip
    return if title.blank?
    return if normalize_key(title) == "competency_count"
    return if course_columns.keys.none? { |index| values[index].present? }

    competency = resolve_competency(title)
    if competency.nil?
      @errors << missing_competency_error(sheet_name, row_number, title)
      return
    end

    course_columns.each do |index, course_code|
      raw_value = values[index]
      next if raw_value.blank?

      apply_target!(sheet_name, row_number, course_code, competency, track, raw_value)
    end
  end

  def resolve_competency(title)
    Competency.find_by_normalized_title(title) ||
      Competency.find_by_normalized_title(CompetencyAliasLookup.resolve(title))
  end

  def missing_competency_error(sheet_name, row_number, title)
    suggestion = CompetencyAliasLookup.suggestions(title).first
    suggestion_text = suggestion ? " Did you mean '#{suggestion[:canonical_competency_title]}'?" : ""

    {
      sheet: sheet_name,
      row: row_number,
      message: "Unrecognized competency title '#{title}'.#{suggestion_text}"
    }
  end

  def apply_target!(sheet_name, row_number, course_code, competency, track, raw_value)
    level = parse_level_value(raw_value)
    if level.nil? || !(1..5).cover?(level)
      @errors << { sheet: sheet_name, row: row_number, message: "#{course_code} / #{competency.title}: target must be a whole number 1-5, received #{raw_value.inspect}." }
      return
    end

    offering = CourseOffering.find_or_create_from_code!(course_code, program_semester: program_semester)
    if offering.blank?
      @errors << { sheet: sheet_name, row: row_number, message: "Could not resolve course code '#{course_code}'." }
      return
    end

    target = CourseCompetencyTarget.find_or_initialize_by(course_offering: offering, competency: competency, track: track)
    was_new = target.new_record?

    if !was_new && target.target_level == level
      @unchanged += 1
      return
    end

    target.target_level = level
    target.save!
    was_new ? @created += 1 : @updated += 1
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    @errors << { sheet: sheet_name, row: row_number, message: "#{course_code} / #{competency.title}: #{e.message}" }
  end

  def parse_level_value(value)
    decimal = BigDecimal(value.to_s)
    return nil unless decimal.frac.zero?

    decimal.to_i
  rescue ArgumentError
    nil
  end

  def normalize_key(value)
    value.to_s
         .encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
         .tr(" ", " ")
         .strip
         .downcase
         .gsub(/[^\p{Alnum}]+/, "_")
         .gsub(/\A_+|_+\z/, "")
  end
end
