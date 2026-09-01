# frozen_string_literal: true

require "caxlsx"

module Reports
  # Builds an Excel workbook summarizing the analytics dataset for offline review.
  class ExcelExporter
    WORKBOOK_SHEETS = %i[
      add_key_metrics_sheet
      add_track_sheet
      add_program_attainment_sheet
      add_course_target_summary_sheet
      add_employment_sheet
      add_raw_survey_sheet
      add_raw_advisor_sheet
      add_raw_course_sheet
      add_raw_employment_sheet
    ].freeze

    def initialize(payload, section: nil)
      @payload = payload.deep_symbolize_keys
    end

    def generate
      package = Axlsx::Package.new
      workbook = package.workbook
      @formatter = Exports::XlsxFormatter.new(workbook)

      WORKBOOK_SHEETS.each do |method_name|
        send(method_name, workbook)
      end

      package
    end

    private

    attr_reader :payload, :formatter

    def add_key_metrics_sheet(workbook)
      benchmark = payload[:benchmark] || {}
      cards = Array(benchmark[:cards])
      filters = payload[:filters] || {}

      workbook.add_worksheet(name: "Key Metrics") do |sheet|
        formatter.add_meta_row(sheet, "Generated At", format_timestamp(payload[:generated_at]))
        sheet.add_row []
        formatter.add_title_row(sheet, [ "Active Filters" ])
        filters.each do |label, value|
          formatter.add_data_row(sheet, [ label.to_s.titleize, value ])
        end

        sheet.add_row []
        metric_header_row = formatter.add_header_row(sheet, [ "Metric", "Value", "Change", "Description", "Sample Size" ])
        cards.each do |card|
          formatter.add_data_row(sheet, [
            card[:title],
            formatted_value(card[:value], card[:unit], card[:precision]),
            formatted_change(card[:change], card[:unit]),
            card[:description],
            card[:sample_size]
          ])
          Array(card.dig(:meta, :tracks)).each do |track|
            formatter.add_data_row(sheet, [
              track[:label],
              format_number(track[:percent], 1, suffix: "%"),
              nil,
              "#{track[:competencies_met_goal].to_i} competencies met benchmark; #{track[:competencies_below_goal].to_i} below benchmark",
              track[:sample_size]
            ])
          end
        end

        formatter.finish_table(sheet, header_row: metric_header_row, column_count: 5, widths: [ 28, 14, 14, 42, 16 ])
      end
    end

    def add_domain_sheet(workbook)
      summary = Array(payload[:competency_summary])

      workbook.add_worksheet(name: "Domain") do |sheet|
        headers = [
          "Domain",
          "Program Target Level",
          "Student Avg",
          "Advisor Avg",
          "Course Avg",
          "Student % Meeting Program Target",
          "Advisor % Meeting Program Target",
          "Student % Meeting Course Target",
          "Trend %",
          "Status",
          "Student Sample",
          "Advisor Sample",
          "# Achieved Program Target",
          "# Not Met Program Target",
          "# Not Assessed Program Target",
          "% Achieved Program Target",
          "% Not Met Program Target",
          "% Not Assessed Program Target"
        ]
        header_row = formatter.add_header_row(sheet, headers)

        if summary.blank?
          formatter.add_note_row(sheet, [ "No domain data available" ])
        end

        summary.each do |entry|
          formatter.add_data_row(sheet, [
            entry[:name],
            format_number(entry[:program_target_level], 2),
            format_number(entry[:student_average], 2),
            format_number(entry[:advisor_average], 2),
            format_number(entry[:course_average], 2),
            format_number(entry[:student_target_percent], 1, suffix: "%"),
            format_number(entry[:advisor_target_percent], 1, suffix: "%"),
            format_number(entry[:course_target_percent], 1, suffix: "%"),
            formatted_change(entry[:change], "percent"),
            entry[:status].to_s.titleize,
            entry[:student_sample],
            entry[:advisor_sample],
            entry[:achieved_count],
            entry[:not_met_count],
            entry[:not_assessed_count],
            format_number(entry[:achieved_percent], 1, suffix: "%"),
            format_number(entry[:not_met_percent], 1, suffix: "%"),
            format_number(entry[:not_assessed_percent], 1, suffix: "%")
          ])
        end

        formatter.finish_table(sheet, header_row: header_row, column_count: headers.size)
      end
    end

    def add_competency_sheet(workbook)
      detail = Array(payload.dig(:competency_detail, :items))

      workbook.add_worksheet(name: "Competency") do |sheet|
        headers = [
          "Competency",
          "Domain",
          "Program Target Level",
          "Student Avg",
          "Advisor Avg",
          "Course Avg",
          "Student % Meeting Program Target",
          "Advisor % Meeting Program Target",
          "Student % Meeting Course Target",
          "# Achieved Program Target",
          "# Not Met Program Target",
          "# Not Assessed Program Target",
          "% Achieved Program Target",
          "% Not Met Program Target",
          "% Not Assessed Program Target"
        ]
        header_row = formatter.add_header_row(sheet, headers)

        if detail.blank?
          formatter.add_note_row(sheet, [ "No competency data available" ])
        end

        detail.each do |item|
          formatter.add_data_row(sheet, [
            item[:name],
            item[:domain_name],
            format_number(item[:program_target_level], 2),
            format_number(item[:student_average], 2),
            format_number(item[:advisor_average], 2),
            format_number(item[:course_average], 2),
            format_number(item[:student_target_percent], 1, suffix: "%"),
            format_number(item[:advisor_target_percent], 1, suffix: "%"),
            format_number(item[:course_target_percent], 1, suffix: "%"),
            item[:achieved_count],
            item[:not_met_count],
            item[:not_assessed_count],
            format_number(item[:achieved_percent], 1, suffix: "%"),
            format_number(item[:not_met_percent], 1, suffix: "%"),
            format_number(item[:not_assessed_percent], 1, suffix: "%")
          ])
        end

        formatter.finish_table(sheet, header_row: header_row, column_count: headers.size)
      end
    end

    def add_track_sheet(workbook)
      tracks = Array(payload[:track_summary])

      workbook.add_worksheet(name: "Track") do |sheet|
        headers = [
          "Track",
          "Class",
          "Students",
          "Submissions",
          "# Achieved Program Target",
          "# Not Met Program Target",
          "% Achieved Program Target",
          "% Not Met Program Target"
        ]
        header_row = formatter.add_header_row(sheet, headers)

        if tracks.blank?
          formatter.add_note_row(sheet, [ "No track data available" ])
        end

        tracks.each do |entry|
          formatter.add_data_row(sheet, [
            entry[:track],
            entry[:class_of].present? ? "Class of #{entry[:class_of]}" : "Class Unassigned",
            entry[:total_students],
            entry[:submissions],
            entry[:achieved_count],
            entry[:not_met_count],
            format_number(entry[:achieved_percent], 1, suffix: "%"),
            format_number(entry[:not_met_percent], 1, suffix: "%")
          ])
        end

        formatter.finish_table(sheet, header_row: header_row, column_count: headers.size)
      end
    end

    def add_program_attainment_sheet(workbook)
      distribution = payload[:rating_level_distribution] || {}
      levels = (distribution[:levels] || {}).sort_by { |level, _label| level.to_i }
      rows = Array(distribution[:items])

      workbook.add_worksheet(name: "Program Attainment") do |sheet|
        headers = [
          "Track",
          "Class",
          "Competency",
          *levels.map { |level, label| rating_level_label(level, label) },
          "Students",
          "% Achieved Program Target",
          "% Not Achieved Program Target",
          "Benchmark Outcome"
        ]
        header_row = formatter.add_header_row(sheet, headers)

        if rows.blank?
          formatter.add_note_row(sheet, [ "No program-level attainment data available" ])
        end

        rows.each do |entry|
          formatter.add_data_row(sheet, [
            entry[:track],
            entry[:class_of].present? ? "Class of #{entry[:class_of]}" : "Class Unassigned",
            entry[:name],
            *levels.map { |level, _label| entry.dig(:level_counts, level) || entry.dig(:level_counts, level.to_s) || 0 },
            entry[:total_students],
            format_number(entry[:target_met_percent], 1, suffix: "%"),
            format_number(entry[:target_not_met_percent], 1, suffix: "%"),
            entry[:target_met_percent].nil? ? nil : (entry[:target_met] ? "Met" : "Not Met")
          ])
        end

        formatter.finish_table(sheet, header_row: header_row, column_count: headers.size)
      end
    end

    def add_course_target_summary_sheet(workbook)
      rows = Array(payload[:course_target_summary])

      workbook.add_worksheet(name: "Course Level") do |sheet|
        headers = [
          "Track",
          "Class",
          "Students",
          "Evidence Rows",
          "# Achieved Course Target",
          "# Not Met Course Target",
          "% Achieved Course Target",
          "% Not Met Course Target",
          "No Course Target"
        ]
        header_row = formatter.add_header_row(sheet, headers)

        if rows.blank?
          formatter.add_note_row(sheet, [ "No course-level competency achievement data available" ])
        end

        rows.each do |entry|
          formatter.add_data_row(sheet, [
            entry[:track],
            entry[:class_of].present? ? "Class of #{entry[:class_of]}" : "Class Unassigned",
            entry[:student_count],
            entry[:evidence_count],
            entry[:met_count],
            entry[:below_count],
            format_number(entry[:met_percent], 1, suffix: "%"),
            format_number(entry[:below_percent], 1, suffix: "%"),
            entry[:no_target_count]
          ])
        end

        formatter.finish_table(sheet, header_row: header_row, column_count: headers.size)
      end
    end

    def add_employment_sheet(workbook)
      employment = payload[:employment_summary] || {}
      status_counts = Array(employment[:status_counts])
      cohorts = Array(employment[:cohorts])
      hours = employment[:hours_distribution] || {}
      flexibility = employment[:flexibility_distribution] || {}

      workbook.add_worksheet(name: "Employment") do |sheet|
        formatter.add_meta_row(sheet, "Generated At", format_timestamp(payload[:generated_at]))
        formatter.add_meta_row(sheet, "Total Respondents", employment[:total_respondents])
        formatter.add_meta_row(sheet, "Employment Rate", format_number(employment[:employment_rate], 1, suffix: "%"))

        sheet.add_row []
        formatter.add_title_row(sheet, [ "Status Breakdown" ])
        status_header_row = formatter.add_header_row(sheet, [ "Status", "Count" ])
        formatter.add_note_row(sheet, [ "No employment status data available", nil ]) if status_counts.blank?
        status_counts.each do |entry|
          formatter.add_data_row(sheet, [ entry[:label], entry[:count] ])
        end

        if cohorts.any?
          sheet.add_row []
          formatter.add_title_row(sheet, [ "Track/Cohort Breakdown" ])
          formatter.add_header_row(sheet, [ "Track", "Class", "Respondents", "Employment Rate", "Employed", "Not Employed", "No Response" ])
          cohorts.each do |entry|
            counts = Array(entry[:status_counts])
            formatter.add_data_row(sheet, [
              entry[:track],
              entry[:class_of].present? ? "Class of #{entry[:class_of]}" : "Class Unassigned",
              entry[:total_respondents],
              format_number(entry[:employment_rate], 1, suffix: "%"),
              status_count(counts, "Employed"),
              status_count(counts, "Not employed"),
              status_count(counts, "No response")
            ])
          end
        end

        sheet.add_row []
        formatter.add_title_row(sheet, [ "Hours Per Week" ])
        formatter.add_header_row(sheet, [ "Bucket", "Count" ])
        formatter.add_note_row(sheet, [ "No hours data available", nil ]) if Array(hours[:labels]).blank?
        Array(hours[:labels]).zip(Array(hours[:data])).each do |label, count|
          formatter.add_data_row(sheet, [ label, count ])
        end

        sheet.add_row []
        formatter.add_title_row(sheet, [ "Work Schedule Flexibility" ])
        formatter.add_header_row(sheet, [ "Label", "Count" ])
        formatter.add_note_row(sheet, [ "No flexibility data available", nil ]) if Array(flexibility[:labels]).blank?
        Array(flexibility[:labels]).zip(Array(flexibility[:data])).each do |label, count|
          formatter.add_data_row(sheet, [ label, count ])
        end

        formatter.finish_table(sheet, header_row: status_header_row, column_count: 2, widths: [ 32, 14 ], auto_filter: false)
      end
    end

    def add_raw_survey_sheet(workbook)
      add_raw_sheet(
        workbook,
        "Raw Survey",
        [
          [ "Student ID", :student_id ],
          [ "Student Name", :student_name ],
          [ "Email", :email ],
          [ "UIN", :uin ],
          [ "Track", :track ],
          [ "Year", :year ],
          [ "Assigned Advisor", :assigned_advisor ],
          [ "Survey", :survey ],
          [ "Semester", :semester ],
          [ "Domain", :domain ],
          [ "Competency", :competency ],
          [ "Score", :score ],
          [ "Program Target", :program_target_level ],
          [ "Updated At", :updated_at ]
        ],
        raw_rows(:survey_responses)
      )
    end

    def add_raw_advisor_sheet(workbook)
      add_raw_sheet(
        workbook,
        "Raw Advisor",
        [
          [ "Student ID", :student_id ],
          [ "Student Name", :student_name ],
          [ "Email", :email ],
          [ "UIN", :uin ],
          [ "Track", :track ],
          [ "Year", :year ],
          [ "Assigned Advisor", :assigned_advisor ],
          [ "Rating Advisor", :advisor ],
          [ "Rating Advisor ID", :advisor_id ],
          [ "Survey", :survey ],
          [ "Semester", :semester ],
          [ "Domain", :domain ],
          [ "Competency", :competency ],
          [ "Score", :score ],
          [ "Program Target", :program_target_level ],
          [ "Updated At", :updated_at ]
        ],
        raw_rows(:advisor_ratings)
      )
    end

    def add_raw_course_sheet(workbook)
      add_raw_sheet(
        workbook,
        "Raw Course",
        [
          [ "Student ID", :student_id ],
          [ "Student Name", :student_name ],
          [ "Email", :email ],
          [ "UIN", :uin ],
          [ "Track", :track ],
          [ "Year", :year ],
          [ "Assigned Advisor", :assigned_advisor ],
          [ "Semester", :semester ],
          [ "Course", :course ],
          [ "Competency", :competency ],
          [ "Assignment", :assignment ],
          [ "Raw Course Score", :raw_grade ],
          [ "Course Achievement Level", :assessed_level ],
          [ "Course Target Level", :course_target_level ],
          [ "Target Status", :target_status ],
          [ "Source File", :source_file ],
          [ "Imported At", :imported_at ],
          [ "Updated At", :updated_at ]
        ],
        raw_rows(:course_evidence)
      )
    end

    def add_raw_employment_sheet(workbook)
      add_raw_sheet(
        workbook,
        "Raw Employment",
        [
          [ "Student ID", :student_id ],
          [ "Student Name", :student_name ],
          [ "Email", :email ],
          [ "UIN", :uin ],
          [ "Track", :track ],
          [ "Year", :year ],
          [ "Assigned Advisor", :assigned_advisor ],
          [ "Survey", :survey ],
          [ "Semester", :semester ],
          [ "Question", :question ],
          [ "Parsed Answer", :parsed_answer ],
          [ "Raw Response", :raw_response ],
          [ "Updated At", :updated_at ]
        ],
        raw_rows(:employment_responses)
      )
    end

    def add_raw_sheet(workbook, name, columns, rows)
      workbook.add_worksheet(name: name) do |sheet|
        header_row = formatter.add_header_row(sheet, columns.map(&:first))

        if rows.blank?
          formatter.add_note_row(sheet, [ "No raw data available" ])
        else
          rows.each do |row|
            formatter.add_data_row(sheet, columns.map { |_label, key| format_raw_value(row[key]) })
          end
        end

        formatter.finish_table(sheet, header_row: header_row, column_count: columns.size)
      end
    end

    def raw_rows(key)
      Array(payload.dig(:raw_data, key))
    end

    def rating_level_label(level, label)
      level.to_i.zero? ? "0/Not able to assess" : "#{level} #{label}"
    end

    def status_count(counts, label)
      Array(counts).find { |entry| entry[:label] == label }&.dig(:count).to_i
    end

    def format_raw_value(value)
      case value
      when ActiveSupport::TimeWithZone, Time, DateTime
        format_timestamp(value)
      when Date
        value.strftime("%Y-%m-%d")
      when BigDecimal
        value.to_f
      else
        value
      end
    end

    def formatted_value(value, unit, precision)
      return nil if value.nil?

      case unit
      when "percent"
        format_number(value, precision || 0, suffix: "%")
      else
        format_number(value, precision || 1)
      end
    end

    def formatted_change(change, unit)
      return nil if change.nil?

      prefix = change.positive? ? "+" : ""
      case unit
      when "percent"
        "#{prefix}#{format_number(change, 1)}%"
      else
        "#{prefix}#{format_number(change, 1)}"
      end
    end

    def format_number(value, precision = 2, suffix: nil)
      return nil if value.nil?

      formatted = format("%0.#{precision}f", value)
      suffix ? "#{formatted}#{suffix}" : formatted
    end

    def format_timestamp(value)
      return nil unless value

      value.in_time_zone.strftime("%Y-%m-%d %H:%M %Z")
    end
  end
end
