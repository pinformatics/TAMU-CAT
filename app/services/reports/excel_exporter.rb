# frozen_string_literal: true

require "caxlsx"

module Reports
  # Builds an Excel workbook summarizing the analytics dataset for offline review.
  class ExcelExporter
    WORKBOOK_SHEETS = %i[
      add_trend_sheet
      add_domain_sheet
      add_competency_sheet
      add_track_sheet
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

    def add_trend_sheet(workbook)
      benchmark = payload[:benchmark] || {}
      cards = Array(benchmark[:cards])
      filters = payload[:filters] || {}
      timeline = Array(benchmark[:timeline])

      workbook.add_worksheet(name: "Trend") do |sheet|
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
        end

        formatter.finish_table(sheet, header_row: metric_header_row, column_count: 5, widths: [ 28, 14, 14, 42, 16 ])

        next if timeline.blank?

        sheet.add_row []
        formatter.add_title_row(sheet, [ "Timeline" ])
        timeline_header_row = formatter.add_header_row(sheet, [ "Month", "Student % Meeting Target", "Advisor % Meeting Target", "Course % Meeting Target" ])
        timeline.each do |point|
          formatter.add_data_row(sheet, [
            point[:label],
            format_number(point[:student_target_percent], 1, suffix: "%"),
            format_number(point[:advisor_target_percent], 1, suffix: "%"),
            format_number(point[:course_target_percent], 1, suffix: "%")
          ])
        end
        formatter.finish_table(sheet, header_row: timeline_header_row, column_count: 4, widths: [ 18, 24, 24, 24 ], freeze: false, auto_filter: false)
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
          "Student % Meeting Target",
          "Advisor % Meeting Target",
          "Course % Meeting Target",
          "Trend %",
          "Status",
          "Student Sample",
          "Advisor Sample",
          "Achieved",
          "Not Met",
          "Not Assessed",
          "Achieved %",
          "Not Met %",
          "Not Assessed %"
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
          "Student % Meeting Target",
          "Advisor % Meeting Target",
          "Course % Meeting Target",
          "Achieved",
          "Not Met",
          "Not Assessed",
          "Achieved %",
          "Not Met %",
          "Not Assessed %"
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
          "On Track %",
          "Submissions",
          "Achieved",
          "Not Met",
          "Not Assessed",
          "Achieved %",
          "Not Met %",
          "Not Assessed %"
        ]
        header_row = formatter.add_header_row(sheet, headers)

        if tracks.blank?
          formatter.add_note_row(sheet, [ "No track data available" ])
        end

        tracks.each do |entry|
          formatter.add_data_row(sheet, [
            entry[:track],
            format_number(entry[:achieved_percent], 1, suffix: "%"),
            entry[:submissions],
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

    def add_employment_sheet(workbook)
      employment = payload[:employment_summary] || {}
      status_counts = Array(employment[:status_counts])
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
          [ "Raw Grade", :raw_grade ],
          [ "Assessed Level", :assessed_level ],
          [ "Course Target", :course_target_level ],
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
