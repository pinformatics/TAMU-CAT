# Processes one admin upload batch of faculty workbooks.
#
require "roo"
require "set"
require "digest"
require "csv"
#
#
# Workbook contract for v1:
# - Sheet 1: grade rows
# - Sheet 2: mapping rows
#
# Grade sheet required headers (case-insensitive):
# - student_uin (or uin)
# - student_email (or email) optional if student_uin is present
# - assignment_name (or assignment)
# - grade (or raw_grade)
# - course_code (optional)
#
# Mapping sheet required headers (case-insensitive):
# - assignment_name (or assignment)
# - competency_title (or competency)
# - min_grade
# - max_grade
# - competency_level (or mapped_level, level)
# - course_code (optional)
module GradeImports
  class BatchProcessor
    COMPETENCY_TITLES = Reports::DataAggregator::COMPETENCY_TITLES.freeze

    GRADE_HEADER_ALIASES = {
      student_uin: %w[student_uin uin],
      student_email: %w[student_email email],
      assignment_name: %w[assignment_name assignment],
      grade: %w[grade raw_grade],
      course_code: %w[course_code course]
    }.freeze

    MAPPING_HEADER_ALIASES = {
      assignment_match_type: %w[assignment_match_type match_type],
      assignment_match_value: %w[assignment_match_value match_value],
      assignment_name: %w[assignment_name assignment],
      competency_title: %w[competency_title competency],
      score_basis: %w[score_basis],
      min_grade: %w[min_grade minimum_grade min_score minimum_score],
      max_grade: %w[max_grade maximum_grade max_score maximum_score],
      competency_level: %w[competency_level mapped_level level],
      course_code: %w[course_code course],
      active: %w[active enabled],
      notes: %w[notes]
    }.freeze

    CANVAS_ID_HEADER_ALIASES = {
      student_identifier: %w[sis_user_id sis_login_id sis_login login_id student_id],
      student_name: %w[student],
      student_uin: %w[sis_login_id sis_login login_id sis_user_id id],
      sis_user_id: %w[sis_user_id],
      canvas_id: %w[id],
      section: %w[section course_section]
    }.freeze

    CANVAS_EXCLUDED_COLUMNS = %w[
      student
      id
      sis_user_id
      sis_login_id
      section
      imported_assignments_current_score
      imported_assignments_unposted_current_score
      imported_assignments_final_score
      imported_assignments_unposted_final_score
      current_score
      unposted_current_score
      final_score
      unposted_final_score
      current_grade
      unposted_current_grade
      final_grade
      unposted_final_grade
    ].freeze

    DIRECT_COMPETENCY_PREFIXES = %w[emha rmha].freeze
    DIRECT_STUDENT_HEADER_ALIASES = {
      student_name: %w[student_name],
      student_id: %w[student_id],
      student_sis_id: %w[student_sis_id student_uin uin]
    }.freeze
    DIRECT_RESULT_SUFFIXES = %w[result assessed_level level].freeze
    DIRECT_TARGET_SUFFIXES = %w[mastery_points course_target].freeze
    COURSE_CODE_PATTERN = /([A-Z]{2,5})[\s_-]*(\d{3})(?:[\s_-]*(\d{3}))?/i.freeze
    FULL_COURSE_CODE_EXPECTATION = "4-letter department code, 3-digit course number, and 3-digit section number, such as PHPM-601-700".freeze

    CANVAS_OUTCOME_STUDENT_HEADER_ALIASES = {
      student_name: %w[student_name],
      student_id: %w[student_id],
      student_sis_id: %w[student_sis_id]
    }.freeze
    CANVAS_OUTCOME_HEADER_ALIASES = {
      learning_outcome_name: %w[learning_outcome_name],
      learning_outcome_friendly_name: %w[learning_outcome_friendly_name],
      outcome_score: %w[outcome_score],
      learning_outcome_mastery_score: %w[learning_outcome_mastery_score],
      learning_outcome_points_possible: %w[learning_outcome_points_possible],
      learning_outcome_rating: %w[learning_outcome_rating],
      assessment_title: %w[assessment_title],
      assessment_id: %w[assessment_id],
      attempt: %w[attempt],
      course_name: %w[course_name],
      course_sis_id: %w[course_sis_id],
      section_name: %w[section_name],
      section_sis_id: %w[section_sis_id]
    }.freeze
    CANVAS_OUTCOME_NOT_ASSESSABLE_RATINGS = %w[not_able_to_assess].freeze

    def initialize(batch:, files:, dry_run: false, replace_existing_files: false)
      @batch = batch
      @files = Array(files)
      @dry_run = dry_run
      @replace_existing_files = replace_existing_files
      @student_cache_by_uin = {}
      @student_cache_by_email = {}
      @student_cache_by_name = {}
    end

    def call
      replace_existing_batch_files! if replace_existing_files?

      batch.update!(
        status: "processing",
        started_at: Time.current,
        total_files: batch.grade_import_files.count + files.size,
        summary: batch.summary.merge("dry_run" => dry_run?)
      )

      files.each do |uploaded_file|
        file_checksum = Digest::SHA256.file(uploaded_file.path).hexdigest
        duplicate_uploads = duplicate_uploads_for(file_checksum)
        grade_file = batch.grade_import_files.create!(
          file_name: uploaded_file.original_filename.to_s,
          file_checksum: file_checksum,
          content_type: uploaded_file.content_type.to_s,
          status: "pending",
          parsed_content: {
            duplicate_file_uploads: duplicate_uploads,
            duplicate_file_upload_count: duplicate_uploads.size
          }
        )

        begin
          process_file!(grade_file, uploaded_file)
        rescue StandardError => e
          grade_file.update!(
            status: "failed",
            parse_errors: [ { type: "file", message: e.message } ],
            error_rows: 1,
            parsed_content: grade_file.parsed_content.merge(failure_diagnostics(uploaded_file:, error: e))
          )
          Rails.logger.error("[GradeImports::BatchProcessor] Failed file=#{grade_file.file_name}: #{e.class}: #{e.message}")
        end
      end

      rebuild_ratings!

      file_scope = batch.grade_import_files
      failed_files = file_scope.where(status: "failed").count
      successful_files = file_scope.where(status: "processed").count
      files_with_errors = file_scope.where("error_rows > 0").count
      pending_count = batch.grade_import_pending_rows.pending_student_match.count

      evidence_count = batch.grade_competency_evidences.count
      rating_count = batch.grade_competency_ratings.count

      final_status = if successful_files.zero? && failed_files.positive?
        "failed"
      elsif failed_files.positive? || files_with_errors.positive?
        "completed_with_errors"
      else
        "completed"
      end

      batch.update!(
        status: final_status,
        completed_at: Time.current,
        total_files: file_scope.count,
        processed_files: successful_files,
        failed_files: failed_files,
        evidence_count: evidence_count,
        rating_count: rating_count,
        pending_count: pending_count,
        summary: batch.summary.merge(
          "files_uploaded" => files.size,
          "files_processed" => successful_files,
          "files_failed" => failed_files,
          "pending_rows" => pending_count,
          "evidences_created" => evidence_count,
          "ratings_created" => rating_count,
          "preview_validation" => preview_validation_summary(batch)
        )
      )

      batch
    end

    private

    attr_reader :batch, :files, :student_cache_by_uin, :student_cache_by_email, :student_cache_by_name

    def dry_run?
      @dry_run == true
    end

    def replace_existing_files?
      @replace_existing_files == true
    end

    def replace_existing_batch_files!
      file_names = files.map { |uploaded_file| uploaded_file.original_filename.to_s }.compact_blank
      return if file_names.empty?

      batch.grade_import_files.where(file_name: file_names).find_each(&:destroy!)
    end

    def process_file!(grade_file, uploaded_file)
      router = FileUploadRouter.new(uploaded_file)
      router.validate!

      if router.csv?
        csv_headers = CSV.read(uploaded_file.path, headers: true, encoding: "bom|utf-8").headers.to_a.map { |header| header.to_s.strip }
        result = if canvas_outcomes_headers?(csv_headers)
          process_canvas_outcomes_csv_file!(grade_file:, uploaded_file:)
        else
          process_direct_competency_csv_file!(grade_file:, uploaded_file:)
        end
        update_grade_file_with_result!(grade_file:, result:)
        return
      end

      workbook = Roo::Spreadsheet.open(uploaded_file.path, extension: router.spreadsheet_extension)
      if (outcomes_info = detect_canvas_outcomes_sheet(workbook))
        sheet = workbook.sheet(outcomes_info[:sheet_name])
        result = process_canvas_outcomes_sheet_file!(
          grade_file: grade_file,
          grade_sheet: sheet,
          header_row_number: outcomes_info[:header_row_number],
          headers: outcomes_info[:headers],
          source_name: outcomes_info[:sheet_name],
          fallback_source_name: uploaded_file.original_filename.to_s
        )
        update_grade_file_with_result!(grade_file:, result:)
        return
      end

      if (direct_info = detect_direct_competency_sheet(workbook))
        sheet = workbook.sheet(direct_info[:sheet_name])
        result = process_direct_competency_sheet_file!(
          grade_file: grade_file,
          grade_sheet: sheet,
          header_row_number: direct_info[:header_row_number],
          headers: direct_info[:headers],
          source_name: direct_info[:sheet_name],
          fallback_source_name: uploaded_file.original_filename.to_s
        )
        update_grade_file_with_result!(grade_file:, result:)
        return
      end

      grade_sheet_name, mapping_sheet_name = resolve_grade_and_mapping_sheets!(workbook)

      # Hard runtime override based on token signatures to avoid any object/
      # resolver edge cases. This is especially important for 2-sheet workbooks.
      sheet_names = workbook.sheets.map(&:to_s)
      if sheet_names.size == 2
        first = workbook.sheet(sheet_names.first)
        second = workbook.sheet(sheet_names.second)
        first_mapping = mapping_sheet_token_match?(first)
        second_mapping = mapping_sheet_token_match?(second)
        first_grade = grade_sheet_token_match?(first) || canvas_identifier_present?(first)
        second_grade = grade_sheet_token_match?(second) || canvas_identifier_present?(second)

        if first_mapping && !second_mapping
          mapping_sheet_name = sheet_names.first
          grade_sheet_name = sheet_names.second
        elsif second_mapping && !first_mapping
          mapping_sheet_name = sheet_names.second
          grade_sheet_name = sheet_names.first
        elsif first_grade && !second_grade
          grade_sheet_name = sheet_names.first
          mapping_sheet_name = sheet_names.second
        elsif second_grade && !first_grade
          grade_sheet_name = sheet_names.second
          mapping_sheet_name = sheet_names.first
        end
      end

      grade_sheet = Roo::Spreadsheet.open(uploaded_file.path, extension: router.spreadsheet_extension).sheet(grade_sheet_name)
      mapping_sheet = Roo::Spreadsheet.open(uploaded_file.path, extension: router.spreadsheet_extension).sheet(mapping_sheet_name)

      mapping_header_index, mapping_header_row = extract_header_index_from_rows!(
        mapping_sheet,
        MAPPING_HEADER_ALIASES,
        required: %i[competency_title min_grade max_grade competency_level],
        max_probe: 12
      )

      mapping_rows, mapping_errors, mapping_warnings = parse_mapping_rows(
        mapping_sheet,
        { index: mapping_header_index, row: mapping_header_row }
      )
      imported_rows, pending_rows, error_rows, errors, parse_debug = if narrow_grade_sheet?(grade_sheet)
        process_narrow_grade_sheet!(grade_file:, grade_sheet:, mapping_rows:, mapping_errors:, mapping_warnings:)
      else
        begin
          process_canvas_grade_sheet!(grade_file:, grade_sheet:, mapping_rows:, mapping_errors:, mapping_warnings:)
        rescue RuntimeError => e
          raise unless e.message.include?("Missing required Canvas headers: student_identifier")

          raise "Missing required Canvas headers: student_identifier"
        end
      end

      status = "processed"
      parsed_content = {
        mode: parse_debug[:mode],
        selected_grade_sheet: grade_sheet_name,
        selected_mapping_sheet: mapping_sheet_name,
        mapping_header_row: mapping_header_row,
        mapping_row_count: mapping_rows.size,
        mapping_rows_preview: mapping_rows.first(200),
        mapping_error_count: mapping_errors.size,
        mapping_warning_count: mapping_warnings.size,
        mapping_warnings_preview: mapping_warnings.first(100),
        grade_sheet_debug: parse_debug,
        imported_rows: imported_rows,
        pending_rows: pending_rows,
        row_error_count: error_rows,
        parse_error_preview: errors.first(100)
      }

      update_grade_file_with_result!(
        grade_file: grade_file,
        result: {
          status: status,
          total_rows: [ grade_sheet.last_row.to_i - 1, 0 ].max,
          imported_rows: imported_rows,
          pending_rows: pending_rows,
          error_rows: error_rows + mapping_errors.size,
          parse_errors: errors.first(500),
          parsed_content: parsed_content
        }
      )
    end

    def update_grade_file_with_result!(grade_file:, result:)
      parsed_content = grade_file.parsed_content.merge(result.fetch(:parsed_content, {}))

      grade_file.update!(
        status: result.fetch(:status, "processed"),
        total_rows: result.fetch(:total_rows, 0),
        imported_rows: result.fetch(:imported_rows, 0),
        pending_rows: result.fetch(:pending_rows, 0),
        error_rows: result.fetch(:error_rows, 0),
        parse_errors: Array(result[:parse_errors]).first(500),
        parsed_content: parsed_content
      )
    end

    def process_direct_competency_csv_file!(grade_file:, uploaded_file:)
      csv = CSV.read(uploaded_file.path, headers: true, encoding: "bom|utf-8")
      headers = csv.headers.map { |header| header.to_s.strip }
      detect_direct_competency_headers!(headers)

      process_direct_competency_rows!(
        grade_file: grade_file,
        rows: csv.each_with_index.map { |row, index| [ index + 2, row.to_h ] },
        headers: headers,
        source_name: uploaded_file.original_filename.to_s,
        fallback_source_name: uploaded_file.original_filename.to_s
      )
    end

    def process_direct_competency_sheet_file!(grade_file:, grade_sheet:, header_row_number:, headers:, source_name:, fallback_source_name:)
      rows = ((header_row_number + 1)..grade_sheet.last_row).map do |row_number|
        values = grade_sheet.row(row_number)
        row_hash = headers.each_with_index.each_with_object({}) do |(header, index), out|
          out[header] = values[index]
        end
        [ row_number, row_hash ]
      end

      process_direct_competency_rows!(
        grade_file: grade_file,
        rows: rows,
        headers: headers,
        source_name: source_name,
        fallback_source_name: fallback_source_name
      )
    end

    def process_direct_competency_rows!(grade_file:, rows:, headers:, source_name:, fallback_source_name:)
      student_name_header = direct_student_header_for(headers, :student_name)
      student_id_header = direct_student_header_for(headers, :student_id)
      student_sis_id_header = direct_student_header_for(headers, :student_sis_id)
      direct_mapping = direct_competency_column_mapping(headers)
      competency_columns = direct_mapping[:columns]
      course_code = normalized_direct_course_code(source_name.presence || fallback_source_name)
      assignment_name = ""
      course_warnings = []
      if (course_warning = course_code_warning_for(course_code, row_number: 1, column: "file or sheet name", context: "Direct competency import"))
        course_warnings << course_warning
      end

      imported_rows = 0
      pending_rows = 0
      errors = direct_mapping[:errors].dup
      error_rows = errors.size
      duplicate_warnings = []
      matched_students = Set.new
      pending_students = Set.new
      seen_rows = Hash.new(0)
      rows_scanned = 0
      rows_skipped_blank = 0

      rows.each do |row_number, row|
        rows_scanned += 1
        if row.values.all?(&:blank?)
          rows_skipped_blank += 1
          next
        end

        student_name = row[student_name_header].to_s.strip.presence
        student_id_token = normalize_numeric_identifier(row[student_id_header])
        student_sis_id = normalize_numeric_identifier(row[student_sis_id_header])
        identifier = student_sis_id.presence || student_id_token.presence || student_name.presence
        identifier_type = if student_sis_id.present?
          "uin"
        elsif student_id_token.present?
          "student_id"
        elsif student_name.present?
          "student_name"
        end

        if identifier.blank?
          error_rows += 1
          errors << row_error(row_number, "Student SIS ID, Student ID, or Student name is required", type: "student_identifier")
          next
        end

        if row[student_sis_id_header].present? && invalid_uin?(student_sis_id)
          error_rows += 1
          errors << invalid_uin_error(row_number, column: student_sis_id_header, value: row[student_sis_id_header])
          next
        end

        student = find_student_by_uin(student_sis_id)
        student ||= find_student_by_canvas_identifier(student_id_token)
        student ||= find_student_by_name(student_name)
        matched_students << student.student_id if student

        row_had_value = false

        competency_columns.each do |column|
          result_value = row[column[:result_header]]
          result_level = parse_level_value(result_value)
          target_value = column[:target_header].present? ? row[column[:target_header]] : nil
          course_target_level = parse_level_value(target_value)
          raw_points = parse_decimal(result_value)

          if result_value.blank?
            if target_value.present?
              row_had_value = true
              error_rows += 1
              errors << invalid_direct_level_error(
                row_number,
                label: direct_assessed_level_label(column),
                column: column[:result_header],
                value: result_value
              )
            end
            next
          end

          row_had_value = true
          if result_level.nil? || !(1..5).cover?(result_level)
            error_rows += 1
            errors << invalid_direct_level_error(
              row_number,
              label: direct_assessed_level_label(column),
              column: column[:result_header],
              value: result_value
            )
            next
          end

          if course_target_level.nil? || !(1..5).cover?(course_target_level)
            error_rows += 1
            errors << invalid_direct_level_error(
              row_number,
              label: direct_target_label(column),
              column: column[:target_header],
              value: target_value
            )
            next
          end

          import_fingerprint = build_import_fingerprint(
            grade_file: grade_file,
            row_number: row_number,
            competency_title: column[:competency_title],
            course_code: course_code
          )

          if import_already_recorded?(
            import_fingerprint,
            legacy_import_fingerprint: build_legacy_import_fingerprint(
              grade_file: grade_file,
              row_number: row_number,
              competency_title: column[:competency_title]
            ),
            course_code: course_code
          )
            duplicate_warnings << row_error(row_number, "Duplicate import suppressed for #{assignment_name} / #{column[:competency_title]}")
            next
          end

          source_key = build_source_key(
            identifier: identifier,
            course_code: course_code,
            assignment_name: assignment_name,
            competency_title: column[:competency_title],
            row_number: row_number
          )

          if student.nil?
            create_pending_row!(
              grade_file: grade_file,
              identifier: identifier,
              identifier_type: identifier_type,
              student_uin: student_sis_id,
              student_email: nil,
              student_name: student_name,
              assignment_name: assignment_name,
              course_code: course_code,
              raw_points: raw_points || result_level,
              mapped_level: result_level,
              course_target_level: course_target_level,
              competency_title: column[:competency_title],
              row_number: row_number,
              score_for_mapping: raw_points || result_level,
              score_basis: "direct_result",
              points_possible: nil,
              source_key: source_key,
              import_fingerprint: import_fingerprint
            )
            pending_rows += 1
            pending_students << [ identifier_type, identifier.to_s.downcase.strip ]
            next
          end

          duplicate_key = [ student.student_id, course_code, assignment_name, column[:competency_title] ]
          seen_rows[duplicate_key] += 1
          if seen_rows[duplicate_key] > 1
            duplicate_warnings << row_error(row_number, "Duplicate evidence row for #{assignment_name} / #{column[:competency_title]}")
          end

          create_evidence!(
            grade_file: grade_file,
            student: student,
            source_key: source_key,
            import_fingerprint: import_fingerprint,
            assignment_name: assignment_name,
            course_code: course_code,
            raw_points: raw_points || result_level,
            mapped_level: result_level,
            course_target_level: course_target_level,
            competency_title: column[:competency_title],
            row_number: row_number,
            score_for_mapping: raw_points || result_level,
            score_basis: "direct_result",
            points_possible: nil,
            student_identifiers: {
              student_uin: student_sis_id.presence,
              student_id: student_id_token.presence,
              student_name: student_name
            }
          )
          imported_rows += 1
        rescue ActiveRecord::RecordNotUnique
          duplicate_warnings << row_error(row_number, "Duplicate import suppressed for row #{row_number} (detected on insert)")
        rescue ActiveRecord::RecordInvalid => e
          error_rows += 1
          errors << row_error(row_number, e.record.errors.full_messages.to_sentence.presence || e.message)
        end

        next if row_had_value

        error_rows += 1
        errors << row_error(row_number, "No direct competency result values were found in this row", type: "missing_value")
      end

      {
        status: "processed",
        total_rows: rows.size,
        imported_rows: imported_rows,
        pending_rows: pending_rows,
        error_rows: error_rows,
        parse_errors: errors,
        parsed_content: {
          mode: "direct_competency",
          selected_grade_sheet: source_name,
          selected_mapping_sheet: nil,
          direct_course_code: course_code,
          direct_assignment_name: assignment_name,
          direct_competency_count: competency_columns.size,
          direct_mapping_issue_count: direct_mapping[:errors].size,
          direct_mapping_issues_preview: direct_mapping[:errors].first(50),
          direct_competencies_preview: competency_columns.first(50),
          grade_sheet_debug: {
            mode: "direct_competency",
            rows_scanned: rows_scanned,
            rows_skipped_blank: rows_skipped_blank,
            matched_student_count: matched_students.size,
            pending_student_count: pending_students.size,
            pending_row_count: pending_rows,
            duplicate_warning_count: duplicate_warnings.size,
            duplicate_warnings_preview: duplicate_warnings.first(100),
            mapping_warning_count: course_warnings.size,
            mapping_warnings_preview: course_warnings.first(100),
            ignored_prefixes: [ "HPMC" ]
          }
        }
      }
    end

    def process_canvas_outcomes_csv_file!(grade_file:, uploaded_file:)
      csv = CSV.read(uploaded_file.path, headers: true, encoding: "bom|utf-8")
      headers = csv.headers.map { |header| header.to_s.strip }
      detect_canvas_outcomes_headers!(headers)

      process_canvas_outcomes_rows!(
        grade_file: grade_file,
        rows: csv.each_with_index.map { |row, index| [ index + 2, row.to_h ] },
        headers: headers,
        fallback_source_name: uploaded_file.original_filename.to_s
      )
    end

    def process_canvas_outcomes_sheet_file!(grade_file:, grade_sheet:, header_row_number:, headers:, source_name:, fallback_source_name:)
      rows = ((header_row_number + 1)..grade_sheet.last_row).map do |row_number|
        values = grade_sheet.row(row_number)
        row_hash = headers.each_with_index.each_with_object({}) do |(header, index), out|
          out[header] = values[index]
        end
        [ row_number, row_hash ]
      end

      process_canvas_outcomes_rows!(
        grade_file: grade_file,
        rows: rows,
        headers: headers,
        fallback_source_name: source_name.presence || fallback_source_name
      )
    end

    def process_canvas_outcomes_rows!(grade_file:, rows:, headers:, fallback_source_name:)
      student_name_header = canvas_outcome_student_header_for(headers, :student_name)
      student_id_header = canvas_outcome_student_header_for(headers, :student_id)
      student_sis_id_header = canvas_outcome_student_header_for(headers, :student_sis_id)
      outcome_name_header = canvas_outcome_header_for(headers, :learning_outcome_name)
      outcome_friendly_name_header = canvas_outcome_header_for(headers, :learning_outcome_friendly_name)
      outcome_score_header = canvas_outcome_header_for(headers, :outcome_score)
      mastery_score_header = canvas_outcome_header_for(headers, :learning_outcome_mastery_score)
      points_possible_header = canvas_outcome_header_for(headers, :learning_outcome_points_possible)
      rating_header = canvas_outcome_header_for(headers, :learning_outcome_rating)
      assessment_title_header = canvas_outcome_header_for(headers, :assessment_title)
      course_name_header = canvas_outcome_header_for(headers, :course_name)
      course_sis_id_header = canvas_outcome_header_for(headers, :course_sis_id)
      section_name_header = canvas_outcome_header_for(headers, :section_name)
      section_sis_id_header = canvas_outcome_header_for(headers, :section_sis_id)

      imported_rows = 0
      pending_rows = 0
      errors = []
      error_rows = 0
      duplicate_warnings = []
      matched_students = Set.new
      pending_students = Set.new
      seen_rows = Hash.new(0)
      rows_scanned = 0
      rows_skipped_blank = 0
      rows_skipped_hpmc = 0
      rows_skipped_ungraded = 0

      rows.each do |row_number, row|
        rows_scanned += 1
        if row.values.all?(&:blank?)
          rows_skipped_blank += 1
          next
        end

        raw_competency_name = row[outcome_name_header].to_s.strip.presence || row[outcome_friendly_name_header].to_s.strip.presence
        if raw_competency_name.to_s.strip.match?(/\Ahpmc\b/i)
          rows_skipped_hpmc += 1
          next
        end

        student_name = row[student_name_header].to_s.strip.presence
        student_id_token = normalize_numeric_identifier(row[student_id_header])
        student_sis_id = normalize_numeric_identifier(row[student_sis_id_header])
        identifier = student_sis_id.presence || student_id_token.presence || student_name.presence
        identifier_type = if student_sis_id.present?
          "uin"
        elsif student_id_token.present?
          "student_id"
        elsif student_name.present?
          "student_name"
        end

        if identifier.blank?
          error_rows += 1
          errors << row_error(row_number, "Student SIS ID, Student ID, or Student name is required", type: "student_identifier")
          next
        end

        if row[student_sis_id_header].present? && invalid_uin?(student_sis_id)
          error_rows += 1
          errors << invalid_uin_error(row_number, column: student_sis_id_header, value: row[student_sis_id_header])
          next
        end

        if raw_competency_name.blank?
          error_rows += 1
          errors << row_error(row_number, "Learning outcome name is required", type: "missing_value")
          next
        end

        competency_title = normalized_competency_title(raw_competency_name)
        if competency_title.blank? || !COMPETENCY_TITLES.include?(competency_title)
          error_rows += 1
          errors << missing_competency_mapping_error(row_number, raw_competency_name, column: outcome_name_header, context: "uploaded learning outcome name")
          next
        end

        outcome_score_value = row[outcome_score_header]
        rating_text = row[rating_header]
        if canvas_outcome_ungraded?(outcome_score_value, rating_text)
          rows_skipped_ungraded += 1
          next
        end

        mapped_level = parse_level_value(outcome_score_value)
        if mapped_level.nil? || !(1..5).cover?(mapped_level)
          error_rows += 1
          errors << invalid_direct_level_error(row_number, label: "#{competency_title} outcome score", column: outcome_score_header, value: outcome_score_value)
          next
        end

        target_value = row[mastery_score_header]
        course_target_level = nil
        if target_value.present?
          course_target_level = parse_level_value(target_value)
          if course_target_level.nil? || !(1..5).cover?(course_target_level)
            error_rows += 1
            errors << invalid_direct_level_error(row_number, label: "#{competency_title} mastery score", column: mastery_score_header, value: target_value)
            next
          end
        end

        student = find_student_by_uin(student_sis_id)
        student ||= find_student_by_canvas_identifier(student_id_token)
        student ||= find_student_by_name(student_name)
        matched_students << student.student_id if student

        course_code = canvas_outcomes_course_code_for(
          row,
          section_sis_id_header: section_sis_id_header,
          section_name_header: section_name_header,
          course_sis_id_header: course_sis_id_header,
          course_name_header: course_name_header,
          fallback_source_name: fallback_source_name
        )
        assignment_name = row[assessment_title_header].to_s.strip

        raw_points = parse_decimal(outcome_score_value) || mapped_level
        points_possible = parse_decimal(row[points_possible_header])

        import_fingerprint = build_import_fingerprint(
          grade_file: grade_file,
          row_number: row_number,
          competency_title: competency_title,
          assignment_name: assignment_name,
          course_code: course_code
        )

        if import_already_recorded?(
          import_fingerprint,
          legacy_import_fingerprint: build_legacy_import_fingerprint(
            grade_file: grade_file,
            row_number: row_number,
            competency_title: competency_title,
            assignment_name: assignment_name
          ),
          course_code: course_code
        )
          duplicate_warnings << row_error(row_number, "Duplicate import suppressed for #{assignment_name} / #{competency_title}")
          next
        end

        source_key = build_source_key(
          identifier: identifier,
          course_code: course_code,
          assignment_name: assignment_name,
          competency_title: competency_title,
          row_number: row_number
        )

        if student.nil?
          create_pending_row!(
            grade_file: grade_file,
            identifier: identifier,
            identifier_type: identifier_type,
            student_uin: student_sis_id,
            student_email: nil,
            student_name: student_name,
            assignment_name: assignment_name,
            course_code: course_code,
            raw_points: raw_points,
            mapped_level: mapped_level,
            course_target_level: course_target_level,
            competency_title: competency_title,
            row_number: row_number,
            score_for_mapping: raw_points,
            score_basis: "canvas_outcome_result",
            points_possible: points_possible,
            source_key: source_key,
            import_fingerprint: import_fingerprint
          )
          pending_rows += 1
          pending_students << [ identifier_type, identifier.to_s.downcase.strip ]
          next
        end

        duplicate_key = [ student.student_id, course_code, assignment_name, competency_title ]
        seen_rows[duplicate_key] += 1
        if seen_rows[duplicate_key] > 1
          duplicate_warnings << row_error(row_number, "Duplicate evidence row for #{assignment_name} / #{competency_title}")
        end

        create_evidence!(
          grade_file: grade_file,
          student: student,
          source_key: source_key,
          import_fingerprint: import_fingerprint,
          assignment_name: assignment_name,
          course_code: course_code,
          raw_points: raw_points,
          mapped_level: mapped_level,
          course_target_level: course_target_level,
          competency_title: competency_title,
          row_number: row_number,
          score_for_mapping: raw_points,
          score_basis: "canvas_outcome_result",
          points_possible: points_possible,
          student_identifiers: {
            student_uin: student_sis_id.presence,
            student_id: student_id_token.presence,
            student_name: student_name
          }
        )
        imported_rows += 1
      rescue ActiveRecord::RecordNotUnique
        duplicate_warnings << row_error(row_number, "Duplicate import suppressed for row #{row_number} (detected on insert)")
      rescue ActiveRecord::RecordInvalid => e
        error_rows += 1
        errors << row_error(row_number, e.record.errors.full_messages.to_sentence.presence || e.message)
      end

      {
        status: "processed",
        total_rows: rows.size,
        imported_rows: imported_rows,
        pending_rows: pending_rows,
        error_rows: error_rows,
        parse_errors: errors,
        parsed_content: {
          mode: "canvas_outcomes",
          selected_grade_sheet: fallback_source_name,
          selected_mapping_sheet: nil,
          grade_sheet_debug: {
            mode: "canvas_outcomes",
            rows_scanned: rows_scanned,
            rows_skipped_blank: rows_skipped_blank,
            rows_skipped_hpmc: rows_skipped_hpmc,
            rows_skipped_ungraded: rows_skipped_ungraded,
            matched_student_count: matched_students.size,
            pending_student_count: pending_students.size,
            pending_row_count: pending_rows,
            duplicate_warning_count: duplicate_warnings.size,
            duplicate_warnings_preview: duplicate_warnings.first(100),
            ignored_prefixes: [ "HPMC" ]
          }
        }
      }
    end

    def canvas_outcome_ungraded?(outcome_score_value, rating_text)
      return true if outcome_score_value.blank?

      score = parse_decimal(outcome_score_value)
      return true if score && score.zero?

      normalized_rating = normalize_key(rating_text)
      CANVAS_OUTCOME_NOT_ASSESSABLE_RATINGS.include?(normalized_rating)
    end

    def canvas_outcomes_course_code_for(row, section_sis_id_header:, section_name_header:, course_sis_id_header:, course_name_header:, fallback_source_name:)
      [ section_sis_id_header, section_name_header, course_sis_id_header, course_name_header ].each do |header|
        next if header.blank?

        code = normalize_course_code(row[header])
        return code if code.present?
      end

      normalize_course_code(fallback_source_name)
    end

    def detect_canvas_outcomes_sheet(workbook)
      workbook.sheets.each do |sheet_name|
        sheet = workbook.sheet(sheet_name)
        max_probe = [ sheet.last_row.to_i, 12 ].min
        (1..max_probe).each do |row_number|
          headers = sheet.row(row_number).map { |value| value.to_s.strip }
          begin
            detect_canvas_outcomes_headers!(headers)
            return { sheet_name: sheet_name.to_s, header_row_number: row_number, headers: headers }
          rescue RuntimeError
            next
          end
        end
      end

      nil
    end

    def detect_canvas_outcomes_headers!(headers)
      raise "Not a Canvas outcomes export" unless canvas_outcomes_headers?(headers)

      true
    end

    def canvas_outcomes_headers?(headers)
      has_student_identifier = canvas_outcome_student_header_for(headers, :student_sis_id).present? ||
                                canvas_outcome_student_header_for(headers, :student_id).present?
      has_outcome_name = canvas_outcome_header_for(headers, :learning_outcome_name).present?
      has_outcome_score = canvas_outcome_header_for(headers, :outcome_score).present?

      has_student_identifier && has_outcome_name && has_outcome_score
    end

    def canvas_outcome_student_header_for(headers, canonical)
      aliases = CANVAS_OUTCOME_STUDENT_HEADER_ALIASES.fetch(canonical)
      headers.find { |header| aliases.include?(normalize_key(header)) }
    end

    def canvas_outcome_header_for(headers, canonical)
      aliases = CANVAS_OUTCOME_HEADER_ALIASES.fetch(canonical)
      headers.find { |header| aliases.include?(normalize_key(header)) }
    end

    def detect_direct_competency_sheet(workbook)
      workbook.sheets.each do |sheet_name|
        sheet = workbook.sheet(sheet_name)
        max_probe = [ sheet.last_row.to_i, 12 ].min
        (1..max_probe).each do |row_number|
          headers = sheet.row(row_number).map { |value| value.to_s.strip }
          begin
            detect_direct_competency_headers!(headers)
            return { sheet_name: sheet_name.to_s, header_row_number: row_number, headers: headers }
          rescue RuntimeError
            next
          end
        end
      end

      nil
    end

    def detect_direct_competency_headers!(headers)
      has_student_id = direct_student_header_for(headers, :student_id).present?
      has_student_sis_id = direct_student_header_for(headers, :student_sis_id).present?
      direct_columns_present = direct_competency_result_headers(headers).any?

      unless (has_student_id || has_student_sis_id) && direct_columns_present
        raise "Not a direct competency export"
      end

      true
    end

    def direct_competency_columns(headers)
      direct_competency_column_mapping(headers)[:columns]
    end

    def direct_competency_column_mapping(headers)
      columns = []
      errors = []
      seen_competencies = {}
      result_prefixes = Set.new

      direct_competency_result_headers(headers).each do |header|
        header_text = header.to_s.strip
        result_prefixes << direct_competency_header_prefix(header_text, DIRECT_RESULT_SUFFIXES)
        competency_token = extract_direct_competency_title(header_text)
        competency_title = normalized_competency_title(competency_token)

        if competency_title.blank? || !COMPETENCY_TITLES.include?(competency_title)
          errors << missing_competency_mapping_error(1, competency_token, column: header_text, context: "uploaded header")
          next
        end

        if seen_competencies.key?(competency_title)
          errors << row_error(
            1,
            "Duplicate result/assessed level columns were found for '#{competency_title}'. Keep one result column per competency.",
            type: "mapping",
            column: [ seen_competencies[competency_title], header_text ].compact.join(", "),
            value: competency_title,
            correction_hint: "Remove the duplicate result or assessed level column before importing."
          )
          next
        end
        seen_competencies[competency_title] = header_text

        target_header = direct_target_header_for(headers, header_text)
        if target_header.blank?
          errors << row_error(
            1,
            "Missing mastery points/course target column for '#{competency_title}'. Direct competency imports use result or assessed level as the student competency score and mastery points or course target as the course target.",
            type: "mapping",
            column: header_text,
            value: competency_title
          )
        end

        columns << {
          result_header: header_text,
          target_header: target_header,
          mastery_points_header: target_header,
          competency_title: competency_title
        }
      end

      direct_competency_target_headers(headers).each do |target_header|
        target_prefix = direct_competency_header_prefix(target_header, DIRECT_TARGET_SUFFIXES)
        next if result_prefixes.include?(target_prefix)

        competency_token = extract_direct_competency_title(target_header)
        competency_title = normalized_competency_title(competency_token).presence || competency_token.presence || "unknown competency"
        errors << row_error(
          1,
          "Course target/mastery points column for '#{competency_title}' has no matching result or assessed level column.",
          type: "mapping",
          column: target_header,
          value: competency_title,
          correction_hint: "Add the matching result/assessed level column, or remove this target-only column."
        )
      end

      { columns: columns, errors: errors }
    end

    def direct_competency_result_headers(headers)
      headers.filter_map do |header|
        next if header.blank?

        header_text = header.to_s.strip
        normalized = normalize_key(header_text)
        next unless direct_competency_header?(normalized)
        next unless DIRECT_RESULT_SUFFIXES.any? { |suffix| normalized.end_with?("_#{suffix}") }

        header_text
      end
    end

    def direct_target_header_for(headers, result_header)
      target_prefix = direct_competency_header_prefix(result_header, DIRECT_RESULT_SUFFIXES)
      return if target_prefix.blank?

      headers.find do |header|
        normalized = normalize_key(header)
        DIRECT_TARGET_SUFFIXES.any? { |suffix| normalized == "#{target_prefix}_#{suffix}" }
      end
    end

    def direct_competency_target_headers(headers)
      headers.filter_map do |header|
        next if header.blank?

        header_text = header.to_s.strip
        normalized = normalize_key(header_text)
        next unless DIRECT_TARGET_SUFFIXES.any? { |suffix| normalized.end_with?("_#{suffix}") }
        next if normalized.start_with?("hpmc_")

        header_text
      end
    end

    def extract_direct_competency_title(header_text)
      normalized = normalize_key(header_text)
      if (suffix = (DIRECT_RESULT_SUFFIXES + DIRECT_TARGET_SUFFIXES).find { |candidate| normalized.end_with?("_#{candidate}") })
        return header_text.to_s.sub(/\s+#{suffix.tr("_", " ")}\z/i, "").split(">").map(&:strip).last.to_s
      end

      segments = header_text.to_s.split(">").map(&:strip)
      return "" if segments.size < 2

      segments.last.sub(/\s+(result|mastery points|course target|assessed level|level)\z/i, "").strip
    end

    def direct_student_header_for(headers, canonical)
      aliases = DIRECT_STUDENT_HEADER_ALIASES.fetch(canonical)
      headers.find { |header| aliases.include?(normalize_key(header)) }
    end

    def direct_competency_header?(normalized_header)
      return true if DIRECT_COMPETENCY_PREFIXES.any? { |prefix| normalized_header.start_with?("#{prefix}_competencies_") }
      return false if normalized_header.start_with?("hpmc_")

      DIRECT_RESULT_SUFFIXES.any? { |suffix| normalized_header.end_with?("_#{suffix}") }
    end

    def direct_competency_header_prefix(header_text, suffixes)
      normalized = normalize_key(header_text)
      suffix = suffixes.find { |candidate| normalized.end_with?("_#{candidate}") }
      return if suffix.blank?

      normalized.sub(/_#{Regexp.escape(suffix)}\z/, "")
    end

    def direct_target_label(column)
      "#{column[:competency_title]} course target"
    end

    def direct_assessed_level_label(column)
      "#{column[:competency_title]} assessed level"
    end

    def normalized_direct_course_code(source_name)
      normalize_course_code(source_name)
    end

    def normalize_course_code(value)
      match = value.to_s.upcase.match(COURSE_CODE_PATTERN)
      return nil unless match

      parts = [ match[1], match[2], match[3] ].compact
      parts.join("-")
    end

    def resolve_grade_and_mapping_sheets!(workbook)
      sheet_names = workbook.sheets.map(&:to_s)
      sheet_infos = sheet_names.map.with_index do |name, index|
        sheet = workbook.sheet(name)
        {
          index: index,
          name: name,
          mapping_token: mapping_sheet_token_match?(sheet),
          mapping_strict: mapping_sheet?(sheet),
          grade_token: grade_sheet_token_match?(sheet),
          grade_strict: grade_sheet?(sheet)
        }
      end

      # Hard rule for 2-sheet faculty workbooks:
      # if one sheet looks like mapping, treat the other as grade.
      if sheet_infos.size == 2
        forced_mapping = sheet_infos.find { |info| info[:mapping_token] || info[:mapping_strict] }
        if forced_mapping
          forced_grade = sheet_infos.find { |info| info[:index] != forced_mapping[:index] }
          if forced_grade
            return [ forced_grade[:name], forced_mapping[:name] ]
          end
        end
      end

      mapping_info = sheet_infos.find { |info| info[:mapping_token] } ||
                     sheet_infos.find { |info| info[:mapping_strict] }

      mapping_index = mapping_info&.dig(:index)
      grade_candidates = sheet_infos.reject { |info| info[:index] == mapping_index }

      grade_info = grade_candidates.find { |info| info[:grade_token] } ||
                   grade_candidates.find { |info| info[:grade_strict] } ||
                   grade_candidates.first

      # Fallback for common 2-sheet workbooks where one detector misses due to
      # small header variations. We still validate required headers later.
      if sheet_infos.size == 2
        if mapping_info.nil? && grade_info
          mapping_info = sheet_infos.find { |info| info[:index] != grade_info[:index] }
        elsif grade_info.nil? && mapping_info
          grade_info = sheet_infos.find { |info| info[:index] != mapping_info[:index] }
        end
      end

      mapping_sheet_name = mapping_info&.dig(:name)
      grade_sheet_name = grade_info&.dig(:name)

      if mapping_sheet_name.nil? || grade_sheet_name.nil?
        labels = sheet_names.join(", ")
        diagnostics = sheet_names.map.with_index do |name, idx|
          header_row_num, normalized = detect_any_header_row(workbook.sheet(name), max_probe: 12)
          "#{idx}:#{name}@row#{header_row_num}=#{normalized.first(18).reject(&:blank?).join('|')}"
        end.join("; ")
        raise "Could not identify grade/mapping sheets. Found sheets: #{labels}. Ensure one sheet has mapping headers and another has Canvas or narrow grade headers. Diagnostics: #{diagnostics}"
      end

      [ grade_sheet_name, mapping_sheet_name ]
    end

    def enforce_sheet_roles!(grade_sheet:, mapping_sheet:)
      candidates = [
        [ grade_sheet, mapping_sheet ],
        [ mapping_sheet, grade_sheet ]
      ]

      candidates.each do |candidate_grade, candidate_mapping|
        grade_ok = narrow_grade_sheet?(candidate_grade) || canvas_grade_sheet?(candidate_grade)
        mapping_ok = mapping_sheet_token_match?(candidate_mapping) || mapping_sheet?(candidate_mapping)
        return [ candidate_grade, candidate_mapping ] if grade_ok && mapping_ok
      end

      # Fall back to original order and let downstream errors report specifics.
      [ grade_sheet, mapping_sheet ]
    end

    def mapping_sheet_token_match?(sheet)
      _row_num, headers = detect_any_header_row(sheet, max_probe: 12)
      return false if headers.empty?

      has_competency = headers.any? { |h| h.include?("competency_title") || h.include?("competency") }
      has_min = headers.any? { |h| h.include?("min_grade") || h.include?("min_score") || h.include?("minimum_grade") || h.include?("minimum_score") }
      has_max = headers.any? { |h| h.include?("max_grade") || h.include?("max_score") || h.include?("maximum_grade") || h.include?("maximum_score") }
      has_assignment = headers.any? { |h| h.include?("assignment_match_value") || h.include?("assignment_name") || h == "assignment" }

      has_competency && has_min && has_max && has_assignment
    rescue StandardError
      false
    end

    def failure_diagnostics(uploaded_file:, error:)
      ImportDiagnostics.failure(
        uploaded_file: uploaded_file,
        error: error,
        sheet_analyzer: lambda do |name, sheet|
          header_row_num, normalized = detect_any_header_row(sheet, max_probe: 12)
          {
            name: name,
            header_row: header_row_num,
            normalized_headers: normalized.first(30),
            mapping_token_match: mapping_sheet_token_match?(sheet),
            grade_token_match: grade_sheet_token_match?(sheet),
            canvas_identifier_present: canvas_identifier_present?(sheet)
          }
        end
      )
    end

    def grade_sheet_token_match?(sheet)
      _row_num, headers = detect_any_header_row(sheet, max_probe: 12)
      return false if headers.empty?

      has_student = headers.any? { |h| h == "student" || h.include?("student") }
      has_identifier = headers.any? { |h| h.include?("sis_login_id") || h.include?("sis_user_id") || h == "id" || h.include?("login_id") }

      has_student && has_identifier
    rescue StandardError
      false
    end

    def detect_any_header_row(sheet, max_probe: 12)
      max_row = [ sheet.last_row.to_i, max_probe.to_i ].min
      (1..max_row).each do |row_number|
        normalized = sheet.row(row_number).map { |value| normalize_key(value) }
        next if normalized.reject(&:blank?).empty?

        return [ row_number, normalized ]
      end

      [ 1, [] ]
    end

    def mapping_sheet?(sheet)
      _header_index, _header_row = extract_header_index_from_rows!(
        sheet,
        MAPPING_HEADER_ALIASES,
        required: %i[competency_title min_grade max_grade competency_level],
        max_probe: 12
      )
      true
    rescue StandardError
      false
    end

    def grade_sheet?(sheet)
      narrow_grade_sheet?(sheet) || canvas_identifier_present?(sheet)
    rescue StandardError
      false
    end

    def rebuild_ratings!
      GradeImports::BatchRatingRebuilder.call(batch: batch)
    end

    def parse_mapping_rows(sheet, header_index)
      header_index, header_row_number = resolve_header_index_and_row(
        sheet,
        header_index,
        aliases: MAPPING_HEADER_ALIASES,
        required: %i[competency_title min_grade max_grade competency_level]
      )

      rows = []
      errors = []
      warnings = []

      ((header_row_number + 1)..sheet.last_row).each do |row_number|
        row = row_from_sheet(sheet, header_index, row_number)
        next if row.values.all?(&:blank?)

        # Ignore trailing formatting-only rows with no meaningful mapping data.
        has_mapping_signal = row[:assignment_match_value].present? ||
                             row[:assignment_name].present? ||
                             row[:competency_title].present? ||
                             row[:min_grade].present? ||
                             row[:max_grade].present? ||
                             row[:competency_level].present?
        next unless has_mapping_signal

        competency = normalized_competency_title(row[:competency_title])
        unless competency.present?
          next
        end

        unless COMPETENCY_TITLES.include?(competency)
          errors << missing_competency_mapping_error(row_number, row[:competency_title], column: "competency_title", context: "mapping sheet")
          next
        end

        min_grade = parse_decimal(row[:min_grade])
        max_grade = parse_decimal(row[:max_grade])
        level = parse_integer(row[:competency_level])

        if min_grade.nil? || max_grade.nil?
          errors << row_error(
            row_number,
            "min_grade and max_grade must be numeric",
            type: "mapping_value",
            expected: "numeric min_grade and max_grade",
            received: [ row[:min_grade], row[:max_grade] ].compact_blank.join(" / "),
            correction_hint: "Enter numeric grade range endpoints, such as 0 and 79.99."
          )
          next
        end

        if level.nil? || !(1..5).include?(level)
          errors << row_error(
            row_number,
            "competency_level must be an integer between 1 and 5",
            type: "mapping_value",
            column: "competency_level",
            value: row[:competency_level],
            expected: "whole number 1-5",
            received: row[:competency_level],
            correction_hint: "Enter one of: 1, 2, 3, 4, or 5."
          )
          next
        end

        if max_grade < min_grade
          errors << row_error(row_number, "max_grade must be greater than or equal to min_grade", type: "mapping_value")
          next
        end

        assignment_match_value = row[:assignment_match_value].to_s.strip.presence || row[:assignment_name].to_s.strip.presence
        if assignment_match_value.blank?
          errors << row_error(row_number, "assignment_match_value (or assignment_name) is required", type: "mapping")
          next
        end

        active = parse_boolean(row[:active])
        next if active == false

        score_basis = normalize_key(row[:score_basis])
        score_basis = "points" if score_basis.blank?
        unless %w[points percent].include?(score_basis)
          errors << row_error(row_number, "score_basis must be 'points' or 'percent'", type: "mapping", column: "score_basis", value: row[:score_basis])
          next
        end

        match_type = normalize_key(row[:assignment_match_type])
        match_type = "exact" if match_type.blank?
        unless %w[exact contains regex].include?(match_type)
          errors << row_error(row_number, "assignment_match_type must be exact, contains, or regex", type: "mapping", column: "assignment_match_type", value: row[:assignment_match_type])
          next
        end

        course_code = normalize_course_code(row[:course_code]) || row[:course_code].to_s.strip.presence
        if row[:course_code].present? && (course_warning = course_code_warning_for(course_code, row_number:, column: "course_code", context: "Mapping row"))
          warnings << course_warning
        end

        rows << {
          source_row_number: row_number,
          assignment_match_type: match_type,
          assignment_match_value: assignment_match_value,
          competency_title: competency,
          score_basis: score_basis,
          min_grade: min_grade,
          max_grade: max_grade,
          competency_level: level,
          course_code: course_code,
          notes: row[:notes].to_s.strip.presence
        }
      end

      warnings.concat(validate_mapping_ranges(rows))

      [ rows, errors + warnings.select { |warning| warning[:severity] == "error" }, warnings ]
    end

    def find_student(row)
      uin = normalize_numeric_identifier(row[:student_uin])
      email = row[:student_email].to_s.strip.downcase

      if uin.present?
        return student_cache_by_uin[uin] if student_cache_by_uin.key?(uin)

        student_cache_by_uin[uin] = Student.find_by(uin: uin)
        return student_cache_by_uin[uin]
      end

      return nil if email.blank?
      return student_cache_by_email[email] if student_cache_by_email.key?(email)

      student_cache_by_email[email] = Student.joins(:user).find_by("LOWER(users.email) = ?", email)
    end

    def extract_header_index!(sheet, aliases, required:)
      first_row = sheet.row(1)
      raise "Header row is missing." if first_row.blank?

      normalized_headers = first_row.map { |value| normalize_key(value) }
      index = {}

      aliases.each do |canonical, candidates|
        pos = normalized_headers.index { |header| candidates.include?(header) }
        index[canonical] = pos unless pos.nil?
      end

      missing = required.reject { |name| index.key?(name) }
      raise "Missing required headers: #{missing.join(', ')}" if missing.any?

      index
    end

    def extract_header_index_from_rows!(sheet, aliases, required:, max_probe: 12)
      max_row = [ sheet.last_row.to_i, max_probe.to_i ].min
      (1..max_row).each do |row_number|
        row_values = sheet.row(row_number)
        next if row_values.blank? || row_values.all?(&:blank?)

        normalized_headers = row_values.map { |value| normalize_key(value) }
        index = {}

        aliases.each do |canonical, candidates|
          pos = find_header_position(normalized_headers, candidates)
          index[canonical] = pos unless pos.nil?
        end

        missing = required.reject { |name| index.key?(name) }
        return [ index, row_number ] if missing.empty?
      end

      raise "Header row not found with required headers: #{required.join(', ')}"
    end

    def resolve_header_index_and_row(sheet, header_index, aliases:, required:)
      if header_index.is_a?(Hash) && header_index.key?(:index) && header_index.key?(:row)
        return [ header_index[:index], header_index[:row].to_i ]
      end

      return [ header_index, 1 ] if header_index.is_a?(Hash)

      extract_header_index_from_rows!(sheet, aliases, required:, max_probe: 12)
    end

    def row_from_sheet(sheet, header_index, row_number)
      row_values = sheet.row(row_number)
      header_index.each_with_object({}) do |(key, position), out|
        out[key] = row_values[position]
      end
    end

    def parse_decimal(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_integer(value)
      return nil if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_level_value(value)
      decimal = parse_decimal(value)
      return nil if decimal.nil?
      return nil unless decimal.frac.zero?

      decimal.to_i
    end

    def filter_by_course_code(mappings, course_code)
      normalized = normalize_key(normalize_course_code(course_code) || course_code)
      return mappings if normalized.blank?

      exact = mappings.select do |entry|
        normalize_key(normalize_course_code(entry[:course_code]) || entry[:course_code]) == normalized
      end
      exact.presence || mappings
    end

    def process_narrow_grade_sheet!(grade_file:, grade_sheet:, mapping_rows:, mapping_errors:, mapping_warnings:)
      grade_headers, grade_header_row = extract_narrow_grade_headers!(grade_sheet)
      imported_rows = 0
      pending_rows = 0
      error_rows = 0
      errors = mapping_errors.dup
      duplicate_warnings = []
      seen_rows = Hash.new(0)
      debug_rows_scanned = 0
      debug_rows_skipped_blank = 0
      matched_students = Set.new
      pending_students = Set.new

      ((grade_header_row + 1)..grade_sheet.last_row).each do |row_number|
        row = row_from_sheet(grade_sheet, grade_headers, row_number)
        row_course_code = normalize_course_code(row[:course_code]) || row[:course_code].to_s.strip.presence
        debug_rows_scanned += 1
        if row.values.all?(&:blank?)
          debug_rows_skipped_blank += 1
          next
        end

        assignment_name = row[:assignment_name].to_s.strip
        if assignment_name.blank?
          error_rows += 1
          errors << row_error(row_number, "assignment_name is required")
          next
        end

        raw_points = parse_decimal(row[:grade])
        if raw_points.nil?
          error_rows += 1
          errors << row_error(row_number, "grade is not numeric")
          next
        end

        applied = applied_mappings(
          assignment_name: assignment_name,
          course_code: row_course_code,
          raw_points: raw_points,
          points_possible: nil,
          mapping_rows: mapping_rows
        )

        if applied.empty?
          error_rows += 1
          errors << row_error(row_number, "No mapping match for assignment '#{assignment_name}' and score #{raw_points}")
          next
        end

        if row[:student_uin].present? && invalid_uin?(row[:student_uin])
          error_rows += 1
          errors << invalid_uin_error(row_number, column: "student_uin", value: row[:student_uin])
          next
        end

        student = find_student(row)
        unless student
          applied.each do |applied_mapping|
            import_fingerprint = build_import_fingerprint(
              grade_file: grade_file,
              row_number: row_number,
              competency_title: applied_mapping[:mapping][:competency_title],
              assignment_name: assignment_name,
              course_code: row_course_code.presence || applied_mapping[:mapping][:course_code]
            )
            if import_already_recorded?(
              import_fingerprint,
              legacy_import_fingerprint: build_legacy_import_fingerprint(
                grade_file: grade_file,
                row_number: row_number,
                competency_title: applied_mapping[:mapping][:competency_title],
                assignment_name: assignment_name
              ),
              course_code: row_course_code.presence || applied_mapping[:mapping][:course_code]
            )
              duplicate_warnings << row_error(row_number, "Duplicate import suppressed for #{assignment_name} / #{applied_mapping[:mapping][:competency_title]}")
              next
            end

            create_pending_row!(
              grade_file: grade_file,
              identifier: row[:student_uin].to_s.strip.presence || row[:student_email].to_s.strip.downcase,
              identifier_type: row[:student_uin].present? ? "uin" : "email",
              student_uin: row[:student_uin],
              student_email: row[:student_email],
              student_name: nil,
              assignment_name: assignment_name,
              course_code: row_course_code.presence || applied_mapping[:mapping][:course_code],
              raw_points: raw_points,
              mapped_level: applied_mapping[:mapping][:competency_level],
              competency_title: applied_mapping[:mapping][:competency_title],
              row_number: row_number,
              score_for_mapping: applied_mapping[:score_for_mapping],
              score_basis: applied_mapping[:mapping][:score_basis],
              points_possible: nil,
              import_fingerprint: import_fingerprint
            )
            pending_rows += 1
            pending_students << [
              row[:student_uin].present? ? "uin" : "email",
              (row[:student_uin].to_s.strip.presence || row[:student_email].to_s.strip.downcase)
            ]
          end
          next
        end
        matched_students << student.student_id

        applied.each do |applied_mapping|
          import_fingerprint = build_import_fingerprint(
            grade_file: grade_file,
            row_number: row_number,
            competency_title: applied_mapping[:mapping][:competency_title],
            assignment_name: assignment_name,
            course_code: row_course_code.presence || applied_mapping[:mapping][:course_code]
          )
          if import_already_recorded?(
            import_fingerprint,
            legacy_import_fingerprint: build_legacy_import_fingerprint(
              grade_file: grade_file,
              row_number: row_number,
              competency_title: applied_mapping[:mapping][:competency_title],
              assignment_name: assignment_name
            ),
            course_code: row_course_code.presence || applied_mapping[:mapping][:course_code]
          )
            duplicate_warnings << row_error(row_number, "Duplicate import suppressed for #{assignment_name} / #{applied_mapping[:mapping][:competency_title]}")
            next
          end

          duplicate_key = [ student.student_id, row_course_code.to_s.strip, assignment_name, applied_mapping[:mapping][:competency_title] ]
          seen_rows[duplicate_key] += 1
          if seen_rows[duplicate_key] > 1
            duplicate_warnings << row_error(row_number, "Duplicate evidence row for #{assignment_name} / #{applied_mapping[:mapping][:competency_title]}")
          end

          create_evidence!(
            grade_file: grade_file,
            student: student,
            source_key: build_source_key(
              identifier: row[:student_uin].to_s.strip.presence || row[:student_email].to_s.strip.downcase,
              course_code: row_course_code.presence || applied_mapping[:mapping][:course_code],
              assignment_name: assignment_name,
              competency_title: applied_mapping[:mapping][:competency_title],
              row_number: row_number
            ),
            import_fingerprint: import_fingerprint,
            assignment_name: assignment_name,
            course_code: row_course_code.presence || applied_mapping[:mapping][:course_code],
            raw_points: raw_points,
            mapped_level: applied_mapping[:mapping][:competency_level],
            competency_title: applied_mapping[:mapping][:competency_title],
            row_number: row_number,
            score_for_mapping: applied_mapping[:score_for_mapping],
            score_basis: applied_mapping[:mapping][:score_basis],
            points_possible: nil,
            student_identifiers: { student_uin: row[:student_uin], student_email: row[:student_email] }
          )
          imported_rows += 1
        end
      rescue ActiveRecord::RecordNotUnique
        duplicate_warnings << row_error(row_number, "Duplicate import suppressed for row #{row_number} (detected on insert)")
      rescue ActiveRecord::RecordInvalid => e
        error_rows += 1
        errors << row_error(row_number, e.record.errors.full_messages.to_sentence.presence || e.message)
      end

      [
        imported_rows,
        pending_rows,
        error_rows,
        errors,
        {
          mode: "narrow",
          header_row: grade_header_row,
          headers: grade_sheet.row(grade_header_row).map { |value| normalize_key(value) }.reject(&:blank?),
          rows_scanned: debug_rows_scanned,
          rows_skipped_blank: debug_rows_skipped_blank,
          matched_student_count: matched_students.size,
          pending_student_count: pending_students.size,
          unmatched_row_count: error_rows,
          pending_row_count: pending_rows,
          duplicate_warning_count: duplicate_warnings.size,
          duplicate_warnings_preview: duplicate_warnings.first(100),
          mapping_warnings_preview: mapping_warnings.first(100)
        }
      ]
    end

    def process_canvas_grade_sheet!(grade_file:, grade_sheet:, mapping_rows:, mapping_errors:, mapping_warnings:)
      header_row_number, headers, normalized_headers = detect_canvas_header_row(grade_sheet)

      id_index = extract_canvas_id_index(normalized_headers)
      resolved_identifier_pos = id_index[:student_identifier]
      if resolved_identifier_pos.nil?
        resolved_identifier_pos = fallback_student_identifier_index(normalized_headers)
        id_index[:student_identifier] = resolved_identifier_pos unless resolved_identifier_pos.nil?
      end

      if resolved_identifier_pos.nil?
        resolved_identifier_pos = guess_canvas_identifier_position(headers, normalized_headers)
        id_index[:student_identifier] = resolved_identifier_pos unless resolved_identifier_pos.nil?
      end

      if resolved_identifier_pos.nil?
        # Final fallback: Canvas gradebooks usually place SIS User ID in column 3
        # (0-based index 2) after Student and ID.
        resolved_identifier_pos = headers.size > 2 ? 2 : 0
        id_index[:student_identifier] = resolved_identifier_pos
      end

      assignment_columns = headers.each_with_index.filter_map do |header, index|
        normalized = normalized_headers[index]
        next if normalized.blank?
        next if CANVAS_EXCLUDED_COLUMNS.include?(normalized)

        { index: index, name: header }
      end

      points_row_number = detect_points_possible_row(grade_sheet, start_row: header_row_number + 1)
      points_row = points_row_number ? grade_sheet.row(points_row_number) : []
      data_start_row = points_row_number ? (points_row_number + 1) : (header_row_number + 1)

      imported_rows = 0
      pending_rows = 0
      error_rows = 0
      errors = mapping_errors.dup
      duplicate_warnings = []
      seen_rows = Hash.new(0)
      debug_rows_scanned = 0
      debug_rows_skipped_non_data = 0
      debug_rows_skipped_blank_identifier = 0
      debug_student_not_found = 0
      matched_students = Set.new
      pending_students = Set.new

      (data_start_row..grade_sheet.last_row).each do |row_number|
        row_values = grade_sheet.row(row_number)
        next if row_values.all?(&:blank?)

        debug_rows_scanned += 1
        if canvas_non_data_row?(row_values, id_index: id_index)
          debug_rows_skipped_non_data += 1
          next
        end

        student_name = id_index[:student_name].nil? ? nil : row_values[id_index[:student_name]].to_s.strip.presence
        identifier = normalize_numeric_identifier(row_values[id_index[:student_identifier]])
        identifier_type = "uin"
        canvas_id = id_index[:canvas_id] ? row_values[id_index[:canvas_id]].to_s.strip : nil
        raw_section = id_index[:section].nil? ? "" : row_values[id_index[:section]].to_s.strip
        sheet_name = grade_sheet.respond_to?(:name) ? grade_sheet.name : nil
        course_code = normalize_course_code(raw_section) ||
                      normalize_course_code(sheet_name) ||
                      normalize_course_code(grade_file.file_name) ||
                      raw_section.presence
        if identifier.blank? && student_name.present?
          identifier = student_name
          identifier_type = "student_name"
        end

        if identifier.blank?
          debug_rows_skipped_blank_identifier += 1
          next
        end

        if identifier_type != "student_name" && canvas_identifier_requires_uin?(normalized_headers, id_index[:student_identifier]) && invalid_uin?(identifier)
          error_rows += 1
          errors << invalid_uin_error(row_number, column: grade_sheet.row(header_row_number)[id_index[:student_identifier]], value: row_values[id_index[:student_identifier]])
          next
        end

        student = if identifier_type == "student_name"
          find_student_by_name(student_name)
        else
          find_student_by_canvas_identifier(identifier) || find_student_by_name(student_name)
        end
        debug_student_not_found += 1 if student.nil?
        matched_students << student.student_id if student

        row_assignments = assignment_columns.filter_map do |assignment|
          raw_points = parse_decimal(row_values[assignment[:index]])
          next if raw_points.nil?

          {
            name: assignment[:name].to_s.strip,
            raw_points: raw_points,
            points_possible: parse_decimal(points_row[assignment[:index]])
          }
        end

        applied_contains_mapping_groups(
          assignments: row_assignments,
          course_code: course_code,
          mapping_rows: mapping_rows
        ).each do |applied_mapping|
          assignment_name = applied_mapping[:assignment_name]
          source_key = build_source_key(
            identifier: identifier,
            course_code: course_code.presence || applied_mapping[:mapping][:course_code],
            assignment_name: assignment_name,
            competency_title: applied_mapping[:mapping][:competency_title],
            row_number: row_number
          )
          import_fingerprint = build_import_fingerprint(
            grade_file: grade_file,
            row_number: row_number,
            competency_title: applied_mapping[:mapping][:competency_title],
            assignment_name: assignment_name,
            course_code: course_code.presence || applied_mapping[:mapping][:course_code]
          )
          if import_already_recorded?(
            import_fingerprint,
            legacy_import_fingerprint: build_legacy_import_fingerprint(
              grade_file: grade_file,
              row_number: row_number,
              competency_title: applied_mapping[:mapping][:competency_title],
              assignment_name: assignment_name
            ),
            course_code: course_code.presence || applied_mapping[:mapping][:course_code]
          )
            duplicate_warnings << row_error(row_number, "Duplicate import suppressed for #{assignment_name} / #{applied_mapping[:mapping][:competency_title]}")
            next
          end

          if student.nil?
            create_pending_row!(
              grade_file: grade_file,
              identifier: identifier,
              identifier_type: identifier_type,
              student_uin: identifier_type == "student_name" ? nil : identifier,
              student_email: nil,
              student_name: student_name,
              assignment_name: assignment_name,
              course_code: course_code.presence || applied_mapping[:mapping][:course_code],
              raw_points: applied_mapping[:raw_points],
              mapped_level: applied_mapping[:mapping][:competency_level],
              competency_title: applied_mapping[:mapping][:competency_title],
              row_number: row_number,
              score_for_mapping: applied_mapping[:score_for_mapping],
              score_basis: applied_mapping[:mapping][:score_basis],
              points_possible: applied_mapping[:points_possible],
              source_key: source_key,
              import_fingerprint: import_fingerprint
            )
            pending_rows += 1
            pending_students << [ identifier_type, identifier.to_s.downcase.strip ]
            next
          end

          duplicate_key = [ student.student_id, course_code, assignment_name, applied_mapping[:mapping][:competency_title] ]
          seen_rows[duplicate_key] += 1
          if seen_rows[duplicate_key] > 1
            duplicate_warnings << row_error(row_number, "Duplicate evidence row for #{assignment_name} / #{applied_mapping[:mapping][:competency_title]}")
          end

          create_evidence!(
            grade_file: grade_file,
            student: student,
            source_key: source_key,
            import_fingerprint: import_fingerprint,
            assignment_name: assignment_name,
            course_code: course_code.presence || applied_mapping[:mapping][:course_code],
            raw_points: applied_mapping[:raw_points],
            mapped_level: applied_mapping[:mapping][:competency_level],
            competency_title: applied_mapping[:mapping][:competency_title],
            row_number: row_number,
            score_for_mapping: applied_mapping[:score_for_mapping],
            score_basis: applied_mapping[:mapping][:score_basis],
            points_possible: applied_mapping[:points_possible],
            student_identifiers: {
              student_uin: identifier_type == "student_name" ? nil : identifier,
              canvas_id: canvas_id,
              student_email: nil,
              student_name: student_name,
              assignment_count: applied_mapping[:assignment_count],
              assignment_names: applied_mapping[:assignment_names]
            }
          )
          imported_rows += 1
        end

        non_contains_mapping_rows = mapping_rows.reject { |mapping| mapping[:assignment_match_type] == "contains" }

        assignment_columns.each do |assignment|
          assignment_name = assignment[:name].to_s.strip
          raw_points = parse_decimal(row_values[assignment[:index]])
            next if raw_points.nil?

          points_possible = parse_decimal(points_row[assignment[:index]])

          applied = applied_mappings(
            assignment_name: assignment_name,
            course_code: course_code,
            raw_points: raw_points,
            points_possible: points_possible,
            mapping_rows: non_contains_mapping_rows
          )
          next if applied.empty?

          applied.each do |applied_mapping|
            source_key = build_source_key(
              identifier: identifier,
              course_code: course_code.presence || applied_mapping[:mapping][:course_code],
              assignment_name: assignment_name,
              competency_title: applied_mapping[:mapping][:competency_title],
              row_number: row_number
            )
            import_fingerprint = build_import_fingerprint(
              grade_file: grade_file,
              row_number: row_number,
              competency_title: applied_mapping[:mapping][:competency_title],
              assignment_name: assignment_name,
              course_code: course_code.presence || applied_mapping[:mapping][:course_code]
            )
            if import_already_recorded?(
              import_fingerprint,
              legacy_import_fingerprint: build_legacy_import_fingerprint(
                grade_file: grade_file,
                row_number: row_number,
                competency_title: applied_mapping[:mapping][:competency_title],
                assignment_name: assignment_name
              ),
              course_code: course_code.presence || applied_mapping[:mapping][:course_code]
            )
              duplicate_warnings << row_error(row_number, "Duplicate import suppressed for #{assignment_name} / #{applied_mapping[:mapping][:competency_title]}")
              next
            end

            if student.nil?
              create_pending_row!(
                grade_file: grade_file,
                identifier: identifier,
                identifier_type: identifier_type,
                student_uin: identifier_type == "student_name" ? nil : identifier,
                student_email: nil,
                student_name: student_name,
                assignment_name: assignment_name,
                course_code: course_code.presence || applied_mapping[:mapping][:course_code],
                raw_points: raw_points,
                mapped_level: applied_mapping[:mapping][:competency_level],
                competency_title: applied_mapping[:mapping][:competency_title],
                row_number: row_number,
                score_for_mapping: applied_mapping[:score_for_mapping],
                score_basis: applied_mapping[:mapping][:score_basis],
                points_possible: points_possible,
                source_key: source_key,
                import_fingerprint: import_fingerprint
              )
              pending_rows += 1
              pending_students << [ identifier_type, identifier.to_s.downcase.strip ]
              next
            end

            duplicate_key = [ student.student_id, course_code, assignment_name, applied_mapping[:mapping][:competency_title] ]
            seen_rows[duplicate_key] += 1
            if seen_rows[duplicate_key] > 1
              duplicate_warnings << row_error(row_number, "Duplicate evidence row for #{assignment_name} / #{applied_mapping[:mapping][:competency_title]}")
            end

            create_evidence!(
              grade_file: grade_file,
              student: student,
              source_key: source_key,
              import_fingerprint: import_fingerprint,
              assignment_name: assignment_name,
              course_code: course_code.presence || applied_mapping[:mapping][:course_code],
              raw_points: raw_points,
              mapped_level: applied_mapping[:mapping][:competency_level],
              competency_title: applied_mapping[:mapping][:competency_title],
              row_number: row_number,
              score_for_mapping: applied_mapping[:score_for_mapping],
              score_basis: applied_mapping[:mapping][:score_basis],
              points_possible: points_possible,
              student_identifiers: {
                student_uin: identifier_type == "student_name" ? nil : identifier,
                canvas_id: canvas_id,
                student_email: nil,
                student_name: student_name
              }
            )
            imported_rows += 1
          end
        rescue ActiveRecord::RecordNotUnique
          duplicate_warnings << row_error(row_number, "Duplicate import suppressed for row #{row_number} (detected on insert)")
        rescue ActiveRecord::RecordInvalid => e
          error_rows += 1
          errors << row_error(row_number, e.record.errors.full_messages.to_sentence.presence || e.message)
        end
      end

      [
        imported_rows,
        pending_rows,
        error_rows,
        errors,
        {
          mode: "canvas",
          header_row: header_row_number,
          headers: normalized_headers.reject(&:blank?),
          student_identifier_column: resolved_identifier_pos,
          points_possible_row: points_row_number,
          data_start_row: data_start_row,
          assignment_column_count: assignment_columns.size,
          assignment_columns_preview: assignment_columns.first(120),
          rows_scanned: debug_rows_scanned,
          rows_skipped_non_data: debug_rows_skipped_non_data,
          rows_skipped_blank_identifier: debug_rows_skipped_blank_identifier,
          rows_student_not_found: debug_student_not_found,
          matched_student_count: matched_students.size,
          pending_student_count: pending_students.size,
          unmatched_row_count: error_rows,
          pending_row_count: pending_rows,
          duplicate_warning_count: duplicate_warnings.size,
          duplicate_warnings_preview: duplicate_warnings.first(100),
          mapping_warnings_preview: mapping_warnings.first(100)
        }
      ]
    end

    def narrow_grade_sheet?(grade_sheet)
      extract_narrow_grade_headers!(grade_sheet)
      true
    rescue StandardError
      false
    end

    def extract_narrow_grade_headers!(sheet)
      header_index, header_row = extract_header_index_from_rows!(
        sheet,
        GRADE_HEADER_ALIASES,
        required: %i[assignment_name grade],
        max_probe: 12
      )

      unless header_index.key?(:student_uin) || header_index.key?(:student_email)
        raise "Missing required narrow grade headers: student_uin or student_email"
      end

      [ header_index, header_row ]
    end

    def canvas_grade_sheet?(sheet)
      detect_canvas_header_row(sheet)
      true
    rescue RuntimeError
      false
    end

    def canvas_identifier_present?(sheet)
      max_probe = [ sheet.last_row, 12 ].min
      (1..max_probe).any? do |row_number|
        normalized_headers = sheet.row(row_number).map { |value| normalize_key(value) }
        extract_canvas_id_index(normalized_headers)[:student_identifier].present?
      end
    end

    def extract_canvas_id_index(normalized_headers)
      index = {}
      CANVAS_ID_HEADER_ALIASES.each do |canonical, aliases|
        pos = find_header_position(normalized_headers, aliases, allow_partial_for_short_aliases: false)
        index[canonical] = pos unless pos.nil?
      end

      # Enforce identifier priority independent of left-to-right column order.
      preferred_identifier = preferred_student_identifier_index(normalized_headers)
      index[:student_identifier] = preferred_identifier if preferred_identifier

      index
    end

    def preferred_student_identifier_index(normalized_headers)
      priorities = %w[sis_user_id sis_login_id sis_login login_id student_id id]

      priorities.each do |token|
        exact = normalized_headers.index { |header| header == token }
        return exact if exact

        partial = normalized_headers.index { |header| header.present? && header.include?(token) }
        return partial if partial
      end

      nil
    end

    def fallback_student_identifier_index(normalized_headers)
      return nil if normalized_headers.blank?

      # Prefer explicit SIS/login/user identifier variants if alias matching misses
      # due to hidden characters or punctuation drift in exported headers.
      preferred = preferred_student_identifier_index(normalized_headers)
      return preferred if preferred

      student_present = normalized_headers.any? { |header| header == "student" || header.include?("student") }
      return nil unless student_present

      normalized_headers.index { |header| header == "id" }
    end

    def guess_canvas_identifier_position(headers, normalized_headers)
      # Last-resort fallback for Canvas exports with unexpected header drift.
      # Priority is SIS User ID -> SIS Login ID -> ID.
      prioritized = [
        [ "sis_user_id", /sis\s*user\s*id/i ],
        [ "sis_login_id", /sis\s*login\s*id/i ],
        [ "id", /^id$/i ]
      ]

      prioritized.each do |normalized_token, raw_regex|
        pos = normalized_headers.index { |h| h == normalized_token || h.include?(normalized_token) }
        return pos unless pos.nil?

        raw_pos = headers.index { |h| h.to_s.match?(raw_regex) }
        return raw_pos unless raw_pos.nil?
      end

      # Canvas gradebook usually has Student, ID, SIS User ID, SIS Login ID, Section
      # in the first five columns; use SIS User ID position when detectable by layout.
      student_col = normalized_headers.index { |h| h == "student" || h.include?("student") }
      section_col = normalized_headers.index { |h| h == "section" || h.include?("section") }
      return 2 if student_col == 0 && section_col == 4 && headers.size >= 5

      nil
    end

    def find_header_position(normalized_headers, aliases, allow_partial_for_short_aliases: true)
      # Prefer exact matches, then allow partial header matches to support
      # Canvas export variants such as "sis login id (read only)".
      exact = normalized_headers.index { |header| aliases.include?(header) }
      return exact if exact

      normalized_headers.index do |header|
        next false if header.blank?

        aliases.any? do |candidate|
          next false if !allow_partial_for_short_aliases && candidate.length <= 3

          header.include?(candidate)
        end
      end
    end

    def detect_canvas_header_row(sheet)
      max_probe = [ sheet.last_row, 12 ].min
      (1..max_probe).each do |row_number|
        headers = sheet.row(row_number).map { |value| value.to_s.strip }
        normalized_headers = headers.map { |value| normalize_key(value) }
        id_index = extract_canvas_id_index(normalized_headers)
        return [ row_number, headers, normalized_headers ] if canvas_header_row?(normalized_headers, id_index)
      end

      raise "Missing required Canvas headers: student_identifier"
    end

    def detect_points_possible_row(sheet, start_row: 2)
      max_probe = [ sheet.last_row, start_row + 10 ].min
      (start_row..max_probe).each do |row_number|
        first_value = sheet.row(row_number).first.to_s.strip.downcase
        return row_number if first_value.include?("points possible")
      end
      nil
    end

    def canvas_non_data_row?(row_values, id_index:)
      first_cell = row_values.first.to_s.strip.downcase
      return true if first_cell.include?("points possible")

      identifier = id_index[:student_identifier] ? row_values[id_index[:student_identifier]].to_s.strip : ""
      student_name = id_index[:student_name] ? row_values[id_index[:student_name]].to_s.strip : ""
      return true if identifier.blank? && student_name.blank?

      # Canvas often includes non-student metadata rows with repeated labels.
      compact_tokens = row_values.compact.map { |value| normalize_key(value) }.reject(&:blank?)
      return true if compact_tokens.any? { |token| token.include?("manual_posting") }
      return true if compact_tokens.any? { |token| token.include?("read_only") }

      false
    end

    def applied_mappings(assignment_name:, course_code:, raw_points:, points_possible:, mapping_rows:)
      candidate = mapping_rows.select { |mapping| assignment_matches?(mapping:, assignment_name:) }
      candidate = filter_by_course_code(candidate, course_code)

      candidate.filter_map do |mapping|
        score_for_mapping = case mapping[:score_basis]
        when "percent"
          percent_score(raw_points:, points_possible:)
        else
          raw_points
        end
        next if score_for_mapping.nil?
        next unless score_for_mapping >= mapping[:min_grade] && score_for_mapping <= mapping[:max_grade]

        { mapping: mapping, score_for_mapping: score_for_mapping }
      end
    end

    def applied_contains_mapping_groups(assignments:, course_code:, mapping_rows:)
      contains_rows = mapping_rows.select { |mapping| mapping[:assignment_match_type] == "contains" }
      return [] if contains_rows.empty? || assignments.empty?

      contains_rows
        .group_by { |mapping| [ normalize_key(mapping[:assignment_match_value]), mapping[:competency_title], mapping[:score_basis] ] }
        .filter_map do |_group_key, rows|
          applicable_rows = filter_by_course_code(rows, course_code)
          representative = applicable_rows.first
          next if representative.nil?

          matching_assignments = assignments.filter_map do |assignment|
            next unless assignment_matches?(mapping: representative, assignment_name: assignment[:name])

            score_for_mapping = case representative[:score_basis]
            when "percent"
              percent_score(raw_points: assignment[:raw_points], points_possible: assignment[:points_possible])
            else
              assignment[:raw_points]
            end
            next if score_for_mapping.nil?

            assignment.merge(score_for_mapping: score_for_mapping)
          end
          next if matching_assignments.empty?

          average_score = average_decimal(matching_assignments.map { |assignment| assignment[:score_for_mapping] })
          mapping = applicable_rows.find { |row| average_score >= row[:min_grade] && average_score <= row[:max_grade] }
          next if mapping.nil?

          assignment_names = matching_assignments.map { |assignment| assignment[:name] }
          {
            mapping: mapping,
            assignment_name: grouped_assignment_name(mapping[:assignment_match_value], assignment_names.size),
            assignment_names: assignment_names,
            assignment_count: assignment_names.size,
            raw_points: average_score,
            score_for_mapping: average_score,
            points_possible: nil
          }
        end
    end

    def average_decimal(values)
      numeric_values = Array(values).compact
      return nil if numeric_values.empty?

      numeric_values.sum(BigDecimal("0")) / numeric_values.size
    end

    def grouped_assignment_name(match_value, count)
      "#{match_value} (#{count} #{'assignment'.pluralize(count)})"
    end

    def assignment_matches?(mapping:, assignment_name:)
      lhs = assignment_name.to_s.strip
      rhs = mapping[:assignment_match_value].to_s.strip
      return false if lhs.blank? || rhs.blank?

      case mapping[:assignment_match_type]
      when "contains"
        normalize_key(lhs).include?(normalize_key(rhs))
      when "regex"
        Regexp.new(rhs, Regexp::IGNORECASE).match?(lhs)
      else
        normalize_key(lhs) == normalize_key(rhs)
      end
    rescue RegexpError
      false
    end

    def percent_score(raw_points:, points_possible:)
      return nil if points_possible.nil? || points_possible <= 0

      raw_percent = (raw_points.to_f / points_possible.to_f) * 100.0
      BigDecimal([ raw_percent, 100.0 ].min.to_s)
    end

    def create_evidence!(grade_file:, student:, source_key:, import_fingerprint:, assignment_name:, course_code:, raw_points:, mapped_level:, competency_title:, row_number:, score_for_mapping:, score_basis:, points_possible:, student_identifiers:, course_target_level: nil)
      course_offering = course_offering_for(course_code:, grade_file:)
      competency = Competency.find_by_normalized_title(competency_title) if defined?(Competency)

      attrs = {
        grade_import_file: grade_file,
        student_id: student.student_id,
        competency_title: competency_title,
        course_code: course_code,
        assignment_name: assignment_name,
        raw_grade: raw_points,
        mapped_level: mapped_level,
        course_target_level: course_target_level,
        row_number: row_number,
        source_key: source_key,
        import_fingerprint: import_fingerprint,
        metadata: student_identifiers.merge(
          score_basis: score_basis,
          score_for_mapping: score_for_mapping,
          points_possible: points_possible
        )
      }
      attrs[:competency] = competency if GradeCompetencyEvidence.column_names.include?("competency_id")
      attrs[:course_offering] = course_offering if GradeCompetencyEvidence.column_names.include?("course_offering_id")

      batch.grade_competency_evidences.create!(attrs)
    end

    def create_pending_row!(grade_file:, identifier:, identifier_type:, student_uin:, student_email:, student_name:, assignment_name:, course_code:, raw_points:, mapped_level:, competency_title:, row_number:, score_for_mapping:, score_basis:, points_possible:, source_key: nil, import_fingerprint:, course_target_level: nil)
      course_offering = course_offering_for(course_code:, grade_file:)
      competency = Competency.find_by_normalized_title(competency_title) if defined?(Competency)

      attrs = {
        grade_import_file: grade_file,
        status: "pending_student_match",
        student_identifier: identifier,
        student_identifier_type: identifier_type,
        student_uin: student_uin.to_s.strip.presence,
        student_email: student_email.to_s.strip.downcase.presence,
        student_name: student_name.to_s.strip.presence,
        competency_title: competency_title,
        course_code: course_code,
        assignment_name: assignment_name,
        raw_grade: raw_points,
        mapped_level: mapped_level,
        course_target_level: course_target_level,
        row_number: row_number,
        source_key: source_key || build_source_key(
          identifier: identifier,
          course_code: course_code,
          assignment_name: assignment_name,
          competency_title: competency_title,
          row_number: row_number
        ),
        import_fingerprint: import_fingerprint,
        metadata: {
          score_basis: score_basis,
          score_for_mapping: score_for_mapping,
          points_possible: points_possible
        }
      }
      attrs[:competency] = competency if GradeImportPendingRow.column_names.include?("competency_id")
      attrs[:course_offering] = course_offering if GradeImportPendingRow.column_names.include?("course_offering_id")

      batch.grade_import_pending_rows.create!(attrs)
    end

    def course_offering_for(course_code:, grade_file:)
      return if course_code.blank? || !defined?(CourseOffering)
      return unless CourseOffering.table_exists?

      offering = CourseOffering.find_or_create_from_code!(
        course_code,
        program_semester: batch.program_semester,
        source_name: grade_file.file_name
      )
      grade_file.update_column(:course_offering_id, offering.id) if offering.present? && GradeImportFile.column_names.include?("course_offering_id") && grade_file.course_offering_id.blank?
      offering
    end

    def find_student_by_uin(uin)
      normalized_uin = normalize_numeric_identifier(uin)
      return nil if normalized_uin.blank?
      return student_cache_by_uin[normalized_uin] if student_cache_by_uin.key?(normalized_uin)

      student_cache_by_uin[normalized_uin] = Student.find_by(uin: normalized_uin)
    end

    def find_student_by_canvas_identifier(identifier)
      token = normalize_numeric_identifier(identifier)
      return nil if token.blank?

      by_uin = find_student_by_uin(token)
      return by_uin if by_uin

      numeric_id = parse_integer(token)
      return nil if numeric_id.nil?

      Student.find_by(student_id: numeric_id)
    end

    def find_student_by_name(name)
      signature = person_name_signature(name)
      return nil if signature.blank?
      return student_cache_by_name[signature] if student_cache_by_name.key?(signature)

      first_name, last_name = signature.split(":", 2)
      matches = Student.joins(:user)
        .where("LOWER(users.name) LIKE ? AND LOWER(users.name) LIKE ?", "%#{first_name}%", "%#{last_name}%")
        .to_a
        .select { |student| person_name_signature(student.user&.name) == signature }

      student_cache_by_name[signature] = matches.one? ? matches.first : nil
    end

    def person_name_signature(name)
      token = name.to_s.strip
      return "" if token.blank?

      first_name = nil
      last_name = nil

      if token.include?(",")
        last_token, rest = token.split(",", 2)
        first_name = normalized_name_words(rest).first
        last_name = normalized_name_words(last_token).last
      else
        words = normalized_name_words(token)
        first_name = words.first
        last_name = words.last
      end

      return "" if first_name.blank? || last_name.blank?

      "#{first_name}:#{last_name}"
    end

    def normalized_name_words(value)
      value.to_s
        .downcase
        .gsub(/[^a-z\s]/, " ")
        .squeeze(" ")
        .strip
        .split
    end

    def normalize_numeric_identifier(value)
      token = value.to_s.strip
      return "" if token.blank?
      return token if token.match?(/\A\d+\z/)

      decimal = BigDecimal(token)
      return token unless decimal.frac.zero?

      decimal.to_i.to_s
    rescue ArgumentError
      token
    end

    def invalid_uin?(value)
      normalized = normalize_numeric_identifier(value)
      normalized.present? && !normalized.match?(/\A\d{9}\z/)
    end

    def canvas_identifier_requires_uin?(normalized_headers, index)
      return false if index.nil?

      %w[sis_user_id sis_login_id sis_login login_id].include?(normalized_headers[index].to_s)
    end

    def parse_boolean(value)
      token = value.to_s.strip.downcase
      return nil if token.blank?
      return true if %w[true t yes y 1].include?(token)
      return false if %w[false f no n 0].include?(token)

      nil
    end

    def normalized_competency_title(value)
      title = value.to_s.strip
      return title if COMPETENCY_TITLES.include?(title)

      alias_title = CompetencyAliasLookup.resolve(title)
      return alias_title if alias_title.present?

      normalized = normalize_competency_token(title)
      COMPETENCY_TITLES.find { |known| normalize_competency_token(known) == normalized }
    end

    def invalid_direct_level_error(row_number, label:, column:, value:)
      parsed_level = parse_level_value(value)
      received_value = display_cell_value(value)
      message = "#{label} must be an integer between 1 and 5; received #{received_value}"
      hint = if parsed_level.nil?
        "Enter a whole number from 1 to 5."
      else
        "Use the proficiency scale range only: 1, 2, 3, 4, or 5."
      end

      row_error(
        row_number,
        message,
        type: value.blank? ? "missing_value" : "invalid_value",
        column: column,
        value: value,
        expected: "whole number 1-5",
        received: received_value,
        correction_hint: hint
      )
    end

    def invalid_uin_error(row_number, column:, value:)
      received_value = display_cell_value(value)
      row_error(
        row_number,
        "Student UIN must be exactly 9 digits; received #{received_value}",
        type: "invalid_uin",
        column: column,
        value: value,
        expected: "9 digits",
        received: received_value,
        correction_hint: "Correct the Student UIN to exactly 9 digits before re-uploading."
      )
    end

    def course_code_warning_for(course_code, row_number:, column:, context:)
      return if full_course_code?(course_code)

      row_error(
        row_number,
        "#{context} should include a full course code with #{FULL_COURSE_CODE_EXPECTATION}.",
        type: "course_code",
        severity: "warning",
        column: column,
        value: course_code.presence || "blank",
        expected: "DEPT-###-###",
        received: course_code.presence || "blank",
        correction_hint: "Rename the file/sheet, correct the mapping row, or enter the full course and section in the batch review page."
      )
    end

    def full_course_code?(course_code)
      parsed = CourseOffering.parse_source_code(course_code)
      return false if parsed.blank?

      parsed[:department_code].to_s.match?(/\A[A-Z]{4}\z/) &&
        parsed[:course_number].to_s.match?(/\A\d{3}\z/) &&
        parsed[:section_number].to_s.match?(/\A\d{3}\z/)
    end

    def display_cell_value(value)
      token = value.to_s.strip
      token.present? ? token : "blank"
    end

    def missing_competency_mapping_error(row_number, raw_value, column:, context:)
      suggestions = CompetencyAliasLookup.suggestions(raw_value)
      suggestion = suggestions.first
      suggestion_text = suggestion ? " Did you mean '#{suggestion[:canonical_competency_title]}'?" : ""

      row_error(
        row_number,
        "Missing competency mapping for '#{raw_value}'.#{suggestion_text} Add this string to db/data/competency_aliases.csv or correct the #{context}.",
        type: "missing_competency_mapping",
        column: column,
        value: raw_value,
        expected: "known competency alias",
        received: raw_value,
        suggested_canonical_competency_title: suggestion&.dig(:canonical_competency_title),
        suggested_alias_string: suggestion&.dig(:raw_string),
        suggestion_score: suggestion&.dig(:score)&.round(3),
        correction_hint: "Add raw_string='#{raw_value}' with the correct canonical_competency_title in db/data/competency_aliases.csv, or rename the uploaded column."
      )
    end

    def row_error(row_number, message, type: nil, severity: nil, column: nil, value: nil, **details)
      error = {
        row: row_number,
        message: message
      }
      error[:type] = type if type.present?
      error[:severity] = severity if severity.present?
      error[:column] = column if column.present?
      error[:value] = value if value.present?
      details.each do |key, detail_value|
        error[key] = detail_value if detail_value.present?
      end
      error
    end

    def build_source_key(identifier:, course_code:, assignment_name:, competency_title:, row_number:)
      [
        normalize_key(identifier),
        normalize_key(course_code),
        normalize_key(assignment_name),
        normalize_key(competency_title),
        row_number.to_i
      ].join(":")
    end

    def build_import_fingerprint(grade_file:, row_number:, competency_title:, assignment_name: nil, course_code: nil)
      [
        grade_file.file_checksum,
        normalize_key(course_code),
        row_number.to_i,
        normalize_key(assignment_name),
        normalize_key(competency_title)
      ].compact_blank.join(":")
    end

    def build_legacy_import_fingerprint(grade_file:, row_number:, competency_title:, assignment_name: nil)
      [
        grade_file.file_checksum,
        row_number.to_i,
        normalize_key(assignment_name),
        normalize_key(competency_title)
      ].compact_blank.join(":")
    end

    def import_already_recorded?(import_fingerprint, legacy_import_fingerprint: nil, course_code: nil)
      GradeCompetencyEvidence.exists?(import_fingerprint: import_fingerprint) ||
        GradeImportPendingRow.exists?(import_fingerprint: import_fingerprint) ||
        legacy_import_already_recorded?(legacy_import_fingerprint, course_code)
    end

    def legacy_import_already_recorded?(legacy_import_fingerprint, course_code)
      normalized_course_code = normalize_key(course_code)
      return false if legacy_import_fingerprint.blank? || normalized_course_code.blank?

      GradeCompetencyEvidence.where(import_fingerprint: legacy_import_fingerprint).any? do |row|
        normalize_key(row.course_code) == normalized_course_code
      end || GradeImportPendingRow.where(import_fingerprint: legacy_import_fingerprint).any? do |row|
        normalize_key(row.course_code) == normalized_course_code
      end
    end

    def duplicate_uploads_for(file_checksum)
      GradeImportFile
        .where(file_checksum: file_checksum)
        .includes(:grade_import_batch)
        .order(created_at: :desc)
        .limit(10)
        .map do |file|
          {
            batch_id: file.grade_import_batch_id,
            file_id: file.id,
            file_name: file.file_name,
            uploaded_at: file.created_at&.iso8601,
            batch_status: file.grade_import_batch&.status
          }
        end
    end

    def preview_validation_summary(batch)
      files = batch.grade_import_files.to_a
      duplicate_file_count = files.sum { |file| file.parsed_content["duplicate_file_upload_count"].to_i }
      duplicate_row_count = files.sum { |file| file.parsed_content.dig("grade_sheet_debug", "duplicate_warning_count").to_i }
      issue_type_counts = files
        .flat_map { |file| Array(file.parse_errors).map { |error| error["type"] || error[:type] || "error" } }
        .compact_blank
        .tally

      {
        commit_ready: files.any? && files.none? { |file| file.status == "failed" },
        total_files: files.size,
        failed_files: files.count { |file| file.status == "failed" },
        imported_rows: files.sum(&:imported_rows),
        pending_rows: files.sum(&:pending_rows),
        failed_rows: files.sum(&:error_rows),
        duplicate_file_uploads: duplicate_file_count,
        duplicate_rows: duplicate_row_count,
        issue_type_counts: issue_type_counts,
        checked_at: Time.current.iso8601
      }
    end

    def validate_mapping_ranges(rows)
      warnings = []
      grouped = rows.group_by do |row|
        [
          row[:assignment_match_type],
          normalize_key(row[:assignment_match_value]),
          normalize_key(row[:course_code]),
          row[:competency_title],
          row[:score_basis]
        ]
      end

      grouped.each_value do |entries|
        sorted = entries.sort_by { |entry| [ entry[:min_grade].to_f, entry[:max_grade].to_f ] }
        previous = nil

        sorted.each do |entry|
          if previous && entry[:min_grade].to_f < previous[:max_grade].to_f - 0.001
            warnings << {
              row: entry[:source_row_number],
              type: "mapping_range",
              severity: "error",
              message: "Grade range overlaps a prior mapping range for the same assignment/course/competency"
            }
          elsif previous && entry[:min_grade].to_f > previous[:max_grade].to_f + 0.02
            warnings << {
              row: entry[:source_row_number],
              type: "mapping_range",
              severity: "error",
              message: "Grade range gap detected for the same assignment/course/competency"
            }
          end

          previous = entry
        end
      end

      warnings
    end

    def canvas_header_row?(normalized_headers, id_index)
      return false if id_index[:student_identifier].nil?

      has_student = normalized_headers.any? { |header| header == "student" || header.include?("student") }
      has_section = normalized_headers.any? { |header| header == "section" || header.include?("section") }
      assignment_column_count = normalized_headers.count do |header|
        header.present? && !CANVAS_EXCLUDED_COLUMNS.include?(header)
      end

      has_student && has_section && assignment_column_count >= 1
    end

    def normalize_competency_token(value)
      CompetencyAliasLookup.normalize(value)
    end

    def normalize_key(value)
      value.to_s
           .encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
           .tr("\u00A0", " ")
           .strip
           .downcase
           .gsub(/[^\p{Alnum}]+/, "_")
           .gsub(/\A_+|_+\z/, "")
    end
  end
end
