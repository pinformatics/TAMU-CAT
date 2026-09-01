# frozen_string_literal: true

require "test_helper"

module Reports
  class ExcelExporterTest < ActiveSupport::TestCase
    EXPECTED_SHEETS = [
      "Key Metrics",
      "Track",
      "Program Attainment",
      "Course Level",
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
          cards: [
            {
              title: "Benchmark Attainment",
              value: 50.0,
              unit: "percent",
              precision: 0,
              description: "At least 75% of the cohort achieved the program target level.",
              sample_size: 2
            }
          ]
        },
        competency_summary: [],
        competency_detail: { items: [] },
        track_summary: [],
        rating_level_distribution: {
          levels: { 0 => "Not able to assess", 1 => "Beginner", 2 => "Emerging", 3 => "Capable", 4 => "Experienced", 5 => "Mastery" },
          items: [
            {
              track: "Residential",
              class_of: 2026,
              name: "Public and Population Health Assessment",
              level_counts: { 0 => 0, 1 => 0, 2 => 0, 3 => 1, 4 => 0, 5 => 0 },
              total_students: 1,
              target_met_percent: 50.0,
              target_not_met_percent: 50.0,
              target_met: false
            }
          ]
        },
        course_target_summary: [
          {
            track: "Residential",
            class_of: 2026,
            student_count: 1,
            evidence_count: 1,
            met_count: 1,
            below_count: 0,
            no_target_count: 0,
            met_percent: 100.0,
            below_percent: 0.0
          }
        ],
        raw_data: {}
      }

      package = Reports::ExcelExporter.new(payload).generate
      sheet_names = package.workbook.worksheets.map(&:name)
      assert_equal EXPECTED_SHEETS, sheet_names

      summary_sheet = package.workbook.worksheets.find { |ws| ws.name == "Key Metrics" }
      program_attainment_sheet = package.workbook.worksheets.find { |ws| ws.name == "Program Attainment" }
      course_level_sheet = package.workbook.worksheets.find { |ws| ws.name == "Course Level" }

      summary_header = summary_sheet.rows.find { |row| row.cells.any? { |c| c.value == "Metric" } }
      assert summary_header
      summary_header_values = summary_header.cells.map(&:value)
      assert_includes summary_header_values, "Metric"
      assert_includes summary_header_values, "Sample Size"

      attainment_header = program_attainment_sheet.rows.first.cells.map(&:value)
      assert_includes attainment_header, "0/Not able to assess"
      assert_includes attainment_header, "% Achieved Program Target"
      assert_includes attainment_header, "% Not Achieved Program Target"

      course_header = course_level_sheet.rows.first.cells.map(&:value)
      assert_includes course_header, "# Achieved Course Target"
      assert_includes course_header, "# Not Met Course Target"
      assert_includes course_header, "% Achieved Course Target"
      assert_includes course_header, "% Not Met Course Target"
      assert_includes course_header, "No Course Target"
    end

    test "exports benchmark and employment track cohort detail rows" do
      payload = {
        generated_at: Time.zone.parse("2025-12-01 10:00"),
        filters: {},
        benchmark: {
          cards: [
            {
              title: "Benchmark by Track/Cohort",
              value: nil,
              unit: "percent",
              precision: 0,
              description: "Benchmark by track and cohort.",
              sample_size: 17,
              meta: {
                tracks: [
                  {
                    label: "Residential, Class of 2026",
                    percent: 76.5,
                    competencies_met_goal: 13,
                    competencies_below_goal: 4,
                    sample_size: 17
                  }
                ]
              }
            }
          ]
        },
        competency_summary: [],
        competency_detail: { items: [] },
        track_summary: [],
        rating_level_distribution: {},
        course_target_summary: [],
        employment_summary: {
          total_respondents: 2,
          employment_rate: 50.0,
          status_counts: [
            { label: "Employed", count: 1 },
            { label: "Not employed", count: 1 },
            { label: "No response", count: 0 }
          ],
          cohorts: [
            {
              track: "Residential",
              class_of: 2026,
              total_respondents: 2,
              employment_rate: 50.0,
              status_counts: [
                { label: "Employed", count: 1 },
                { label: "Not employed", count: 1 },
                { label: "No response", count: 0 }
              ]
            }
          ],
          hours_distribution: { labels: [], data: [] },
          flexibility_distribution: { labels: [], data: [] }
        },
        raw_data: {}
      }

      package = Reports::ExcelExporter.new(payload).generate

      key_metrics = package.workbook.worksheets.find { |ws| ws.name == "Key Metrics" }
      key_rows = key_metrics.rows.map { |row| row.cells.map(&:value) }
      assert key_rows.any? do |row|
        row.first == "Residential, Class of 2026" &&
          row.second == "76.5%" &&
          row.fourth == "13 competencies met benchmark; 4 below benchmark"
      end

      employment = package.workbook.worksheets.find { |ws| ws.name == "Employment" }
      employment_rows = employment.rows.map { |row| row.cells.map(&:value) }
      assert employment_rows.any? { |row| row.first == "Track/Cohort Breakdown" }
      assert employment_rows.any? do |row|
        row.first == "Residential" &&
          row.second == "Class of 2026" &&
          row.third == 2 &&
          row.fourth == "50.0%"
      end
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
      assert_includes raw_course.rows.first.cells.map(&:value), "Raw Course Score"
      assert_includes raw_course.rows.first.cells.map(&:value), "Course Achievement Level"
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
            class_of: 2027,
            total_students: 2,
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
      assert_includes header_values, "Class"
      assert_includes header_values, "Students"
      assert_includes header_values, "# Achieved Program Target"
      assert_includes header_values, "# Not Met Program Target"
      assert_includes header_values, "% Achieved Program Target"
      assert_includes header_values, "% Not Met Program Target"
      refute_includes header_values, "Not Assessed %"
    end
  end
end
