# frozen_string_literal: true

require "test_helper"

module Reports
  class ExcelExporterTest < ActiveSupport::TestCase
    EXPECTED_SHEETS = [
      "Trend",
      "Domain",
      "Competency",
      "Track",
      "Employment",
      "Raw Survey",
      "Raw Advisor",
      "Raw Course",
      "Raw Employment"
    ].freeze

    test "exports include target percent and target level columns" do
      payload = {
        generated_at: Time.zone.parse("2025-12-01 10:00"),
        filters: { track: "All tracks" },
        benchmark: {
          cards: [],
          timeline: [
            {
              label: "Dec 2025",
              student: 3.5,
              advisor: 4.0,
              course: 4.1,
              alignment: 90.0,
              student_target_percent: 55.0,
              advisor_target_percent: 60.0,
              course_target_percent: 65.0
            }
          ]
        },
        competency_summary: [
          {
            name: "Health Care Environment and Community",
            student_average: 3.0,
            advisor_average: 3.2,
            course_average: 4.1,
            program_target_level: 4.0,
            student_target_percent: 50.0,
            advisor_target_percent: 40.0,
            course_target_percent: 65.0,
            gap: 0.2,
            change: 1.0,
            status: "watch",
            student_sample: 1,
            advisor_sample: 1,
            achieved_count: 0,
            not_met_count: 1,
            not_assessed_count: 0,
            achieved_percent: 0.0,
            not_met_percent: 100.0,
            not_assessed_percent: 0.0
          }
        ],
        competency_detail: {
          items: [
            {
              name: "Public and Population Health Assessment",
              domain_name: "Health Care Environment and Community",
              student_average: 3.0,
              advisor_average: 3.2,
              course_average: 4.1,
              program_target_level: 4.0,
              student_target_percent: 50.0,
              advisor_target_percent: 40.0,
              course_target_percent: 65.0,
              gap: 0.2,
              achieved_count: 0,
              not_met_count: 1,
              not_assessed_count: 0,
              achieved_percent: 0.0,
              not_met_percent: 100.0,
              not_assessed_percent: 0.0
            }
          ]
        },
        track_summary: [],
        raw_data: {}
      }

      package = Reports::ExcelExporter.new(payload).generate
      sheet_names = package.workbook.worksheets.map(&:name)
      assert_equal EXPECTED_SHEETS, sheet_names

      summary_sheet = package.workbook.worksheets.find { |ws| ws.name == "Trend" }
      competency_sheet = package.workbook.worksheets.find { |ws| ws.name == "Domain" }
      detail_sheet = package.workbook.worksheets.find { |ws| ws.name == "Competency" }

      summary_header = summary_sheet.rows.find { |row| row.cells.any? { |c| c.value == "Month" } }
      assert summary_header
      summary_header_values = summary_header.cells.map(&:value)
      assert_includes summary_header_values, "Student % Meeting Target"
      assert_includes summary_header_values, "Advisor % Meeting Target"
      assert_includes summary_header_values, "Course % Meeting Target"

      competency_header = competency_sheet.rows.first
      competency_header_values = competency_header.cells.map(&:value)
      assert_includes competency_header_values, "Program Target Level"
      assert_includes competency_header_values, "Course Avg"
      assert_includes competency_header_values, "Student % Meeting Target"
      assert_includes competency_header_values, "Advisor % Meeting Target"
      assert_includes competency_header_values, "Course % Meeting Target"

      detail_header = detail_sheet.rows.first
      detail_header_values = detail_header.cells.map(&:value)
      assert_includes detail_header_values, "Program Target Level"
      assert_includes detail_header_values, "Course Avg"
      assert_includes detail_header_values, "Student % Meeting Target"
      assert_includes detail_header_values, "Advisor % Meeting Target"
      assert_includes detail_header_values, "Course % Meeting Target"
    end

    test "exports raw report rows in dedicated sheets" do
      payload = {
        generated_at: Time.zone.parse("2025-12-01 10:00"),
        filters: { track: "Residential" },
        benchmark: { cards: [], timeline: [] },
        competency_summary: [],
        competency_detail: { items: [] },
        track_summary: [],
        employment_summary: {},
        raw_data: {
          survey_responses: [
            {
              student_id: 123,
              student_name: "Student User",
              email: "student@example.com",
              uin: "123456789",
              track: "Residential",
              year: 2026,
              assigned_advisor: "Advisor User",
              survey: "Fall Survey",
              semester: "Fall 2025",
              domain: "Health Care Environment and Community",
              competency: "Public and Population Health Assessment",
              score: 4.0,
              program_target_level: 3,
              updated_at: Time.zone.parse("2025-12-01 09:00")
            }
          ],
          advisor_ratings: [
            {
              student_id: 123,
              student_name: "Student User",
              email: "student@example.com",
              uin: "123456789",
              track: "Residential",
              year: 2026,
              assigned_advisor: "Advisor User",
              advisor: "Advisor User",
              advisor_id: 456,
              survey: "Fall Survey",
              semester: "Fall 2025",
              domain: "Health Care Environment and Community",
              competency: "Public and Population Health Assessment",
              score: 5.0,
              program_target_level: 3,
              updated_at: Time.zone.parse("2025-12-01 09:15")
            }
          ],
          course_evidence: [
            {
              student_id: 123,
              student_name: "Student User",
              email: "student@example.com",
              uin: "123456789",
              track: "Residential",
              year: 2026,
              assigned_advisor: "Advisor User",
              semester: "Fall 2025",
              course: "PHPM-601",
              competency: "Public and Population Health Assessment",
              assignment: "Canvas Result",
              raw_grade: BigDecimal("95.5"),
              assessed_level: 4,
              course_target_level: 3,
              target_status: "Met",
              source_file: "Outcomes-26S-PHPM-601.csv",
              imported_at: Time.zone.parse("2025-12-01 08:30"),
              updated_at: Time.zone.parse("2025-12-01 08:45")
            }
          ],
          employment_responses: [
            {
              student_id: 123,
              student_name: "Student User",
              email: "student@example.com",
              uin: "123456789",
              track: "Residential",
              year: 2026,
              assigned_advisor: "Advisor User",
              survey: "Fall Survey",
              semester: "Fall 2025",
              question: "Are you currently employed?",
              parsed_answer: "Yes",
              raw_response: "{\"answer\":\"Yes\"}",
              updated_at: Time.zone.parse("2025-12-01 09:30")
            }
          ]
        }
      }

      package = Reports::ExcelExporter.new(payload).generate

      raw_survey = package.workbook.worksheets.find { |ws| ws.name == "Raw Survey" }
      assert_equal "Student ID", raw_survey.rows.first.cells.first.value
      assert_includes raw_survey.rows.second.cells.map(&:value), "Public and Population Health Assessment"

      raw_advisor = package.workbook.worksheets.find { |ws| ws.name == "Raw Advisor" }
      assert_includes raw_advisor.rows.first.cells.map(&:value), "Rating Advisor"
      assert_includes raw_advisor.rows.second.cells.map(&:value), 456

      raw_course = package.workbook.worksheets.find { |ws| ws.name == "Raw Course" }
      assert_includes raw_course.rows.first.cells.map(&:value), "Raw Grade"
      assert_includes raw_course.rows.second.cells.map(&:value), "PHPM-601"
      assert_includes raw_course.rows.second.cells.map(&:value), 95.5

      raw_employment = package.workbook.worksheets.find { |ws| ws.name == "Raw Employment" }
      assert_includes raw_employment.rows.second.cells.map(&:value), "Are you currently employed?"
      assert_includes raw_employment.rows.second.cells.map(&:value), "Yes"
    end

    test "track section export includes Tracks sheet and excludes Courses sheet" do
      payload = {
        generated_at: Time.zone.parse("2025-12-01 10:00"),
        filters: { track: "All tracks" },
        benchmark: { cards: [], timeline: [] },
        competency_summary: [],
        competency_detail: { items: [] },
        track_summary: [
          {
            track: "Executive",
            student_average: 4.0,
            advisor_average: 4.2,
            gap: 0.2,
            submissions: 2,
            achieved_count: 2,
            not_met_count: 0,
            not_assessed_count: 0,
            achieved_percent: 100.0,
            not_met_percent: 0.0,
            not_assessed_percent: 0.0
          }
        ],
        raw_data: {}
      }

      package = Reports::ExcelExporter.new(payload).generate
      sheet_names = package.workbook.worksheets.map(&:name)
      assert_equal EXPECTED_SHEETS, sheet_names

      tracks_sheet = package.workbook.worksheets.find { |ws| ws.name == "Track" }
      assert tracks_sheet
      header_values = tracks_sheet.rows.first.cells.map(&:value)
      assert_equal "Track", header_values.first
      assert_includes header_values, "Achieved %"
      assert_includes header_values, "Not Met %"
      assert_includes header_values, "Not Assessed %"
    end
  end
end
