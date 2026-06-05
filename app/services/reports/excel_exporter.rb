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

      WORKBOOK_SHEETS.each do |method_name|
        send(method_name, workbook)
      end

      package
    end

    private

    attr_reader :payload

    def add_trend_sheet(workbook)
      benchmark = payload[:benchmark] || {}
      cards = Array(benchmark[:cards])
      filters = payload[:filters] || {}
      timeline = Array(benchmark[:timeline])

      workbook.add_worksheet(name: "Trend") do |sheet|
        sheet.add_row [ "Generated At", format_timestamp(payload[:generated_at]) ]
        sheet.add_row []
        sheet.add_row [ "Active Filters" ]
        filters.each do |label, value|
          sheet.add_row [ label.to_s.titleize, value ]
        end

        sheet.add_row []
        sheet.add_row [ "Metric", "Value", "Change", "Description", "Sample Size" ]
        cards.each do |card|
          sheet.add_row [
            card[:title],
            formatted_value(card[:value], card[:unit], card[:precision]),
            formatted_change(card[:change], card[:unit]),
            card[:description],
            card[:sample_size]
          ]
        end

        next if timeline.blank?

        sheet.add_row []
        sheet.add_row [ "Timeline" ]
        sheet.add_row [ "Month", "Student % Meeting Target", "Advisor % Meeting Target", "Course % Meeting Target" ]
        timeline.each do |point|
          sheet.add_row [
            point[:label],
            format_number(point[:student_target_percent], 1, suffix: "%"),
            format_number(point[:advisor_target_percent], 1, suffix: "%"),
            format_number(point[:course_target_percent], 1, suffix: "%")
          ]
        end
      end
    end

    def add_domain_sheet(workbook)
      summary = Array(payload[:competency_summary])

      workbook.add_worksheet(name: "Domain") do |sheet|
        sheet.add_row [
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

        if summary.blank?
          sheet.add_row [ "No domain data available" ]
        end

        summary.each do |entry|
          sheet.add_row [
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
          ]
        end
      end
    end

    def add_competency_sheet(workbook)
      detail = Array(payload.dig(:competency_detail, :items))

      workbook.add_worksheet(name: "Competency") do |sheet|
        sheet.add_row [
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

        if detail.blank?
          sheet.add_row [ "No competency data available" ]
        end

        detail.each do |item|
          sheet.add_row [
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
          ]
        end
      end
    end

    def add_track_sheet(workbook)
      tracks = Array(payload[:track_summary])

      workbook.add_worksheet(name: "Track") do |sheet|
        sheet.add_row [
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

        if tracks.blank?
          sheet.add_row [ "No track data available" ]
        end

        tracks.each do |entry|
          sheet.add_row [
            entry[:track],
            format_number(entry[:achieved_percent], 1, suffix: "%"),
            entry[:submissions],
            entry[:achieved_count],
            entry[:not_met_count],
            entry[:not_assessed_count],
            format_number(entry[:achieved_percent], 1, suffix: "%"),
            format_number(entry[:not_met_percent], 1, suffix: "%"),
            format_number(entry[:not_assessed_percent], 1, suffix: "%")
          ]
        end
      end
    end

    def add_employment_sheet(workbook)
      employment = payload[:employment_summary] || {}
      status_counts = Array(employment[:status_counts])
      hours = employment[:hours_distribution] || {}
      flexibility = employment[:flexibility_distribution] || {}

      workbook.add_worksheet(name: "Employment") do |sheet|
        sheet.add_row [ "Generated At", format_timestamp(payload[:generated_at]) ]
        sheet.add_row [ "Total Respondents", employment[:total_respondents] ]
        sheet.add_row [ "Employment Rate", format_number(employment[:employment_rate], 1, suffix: "%") ]

        sheet.add_row []
        sheet.add_row [ "Status Breakdown" ]
        sheet.add_row [ "Status", "Count" ]
        sheet.add_row [ "No employment status data available", nil ] if status_counts.blank?
        status_counts.each do |entry|
          sheet.add_row [ entry[:label], entry[:count] ]
        end

        sheet.add_row []
        sheet.add_row [ "Hours Per Week" ]
        sheet.add_row [ "Bucket", "Count" ]
        sheet.add_row [ "No hours data available", nil ] if Array(hours[:labels]).blank?
        Array(hours[:labels]).zip(Array(hours[:data])).each do |label, count|
          sheet.add_row [ label, count ]
        end

        sheet.add_row []
        sheet.add_row [ "Work Schedule Flexibility" ]
        sheet.add_row [ "Label", "Count" ]
        sheet.add_row [ "No flexibility data available", nil ] if Array(flexibility[:labels]).blank?
        Array(flexibility[:labels]).zip(Array(flexibility[:data])).each do |label, count|
          sheet.add_row [ label, count ]
        end
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
        sheet.add_row columns.map(&:first)

        if rows.blank?
          sheet.add_row [ "No raw data available" ]
          next
        end

        rows.each do |row|
          sheet.add_row columns.map { |_label, key| format_raw_value(row[key]) }
        end
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
