# frozen_string_literal: true

require "test_helper"

module Reports
  class DataAggregatorTrackSummaryTest < ActiveSupport::TestCase
    include Devise::Test::IntegrationHelpers

    setup do
      @admin = users(:admin)
    end

    test "track_summary aggregates into program track rows" do
      aggregator = Reports::DataAggregator.new(user: @admin, params: {})

      # Force deterministic track list so the summary always returns exactly these rows
      aggregator.stub(:program_track_names, [ "Executive", "Residential" ]) do
        # Avoid DB dependence in this unit-style test; we stub assignment counts.
        aggregator.stub(:assigned_student_count_for_track_and_year, 5) do
          rows = [
            # Executive: student 1 achieved (avg 4.0 >= target 4.0)
            {
              score: 4.0,
              advisor_entry: false,
              track: "Executive",
              class_of: 2027,
              student_id: 1,
              program_target_level: 4.0,
              question_text: "Communication",
              survey_id: 1
            },
            # Executive: student 2 not met (avg 3.0 < target 4.0)
            {
              score: 3.0,
              advisor_entry: false,
              track: "Executive",
              class_of: 2027,
              student_id: 2,
              program_target_level: 4.0,
              question_text: "Communication",
              survey_id: 1
            },
            # Residential: student 3 achieved (avg 5.0 >= target 4.0)
            {
              score: 5.0,
              advisor_entry: false,
              track: "Residential",
              class_of: 2026,
              student_id: 3,
              program_target_level: 4.0,
              question_text: "Communication",
              survey_id: 2
            },
            # Advisor rows should not affect achieved/not_met counts (they are excluded)
            {
              score: 4.5,
              advisor_entry: true,
              track: "Residential",
              class_of: 2026,
              student_id: 3,
              program_target_level: 4.0,
              question_text: "Communication",
              survey_id: 2
            }
          ]

          aggregator.stub(:dataset_rows, rows) do
            cohorts = [
              { key: "executive|2027", track_key: "executive", track: "Executive", class_of: 2027, label: "Executive, Class of 2027" },
              { key: "residential|2026", track_key: "residential", track: "Residential", class_of: 2026, label: "Residential, Class of 2026" }
            ]

            aggregator.stub(:track_cohort_metadata, cohorts) do
              track_summary = aggregator.track_summary

              assert_equal 2, track_summary.size
              assert_equal [ "Executive, Class of 2027", "Residential, Class of 2026" ], track_summary.map { |entry| entry[:cohort_label] }

              executive = track_summary.find { |entry| entry[:cohort_label] == "Executive, Class of 2027" }
              residential = track_summary.find { |entry| entry[:cohort_label] == "Residential, Class of 2026" }

              assert_equal 1, executive[:achieved_count]
              assert_equal 1, executive[:not_met_count]
              assert_equal 3, executive[:not_assessed_count]

              assert_equal 1, residential[:achieved_count]
              assert_equal 0, residential[:not_met_count]
              assert_equal 4, residential[:not_assessed_count]

              assert_in_delta 20.0, executive[:achieved_percent], 0.001
              assert_in_delta 20.0, executive[:not_met_percent], 0.001
              assert_in_delta 60.0, executive[:not_assessed_percent], 0.001

              assert_in_delta 20.0, residential[:achieved_percent], 0.001
              assert_in_delta 0.0, residential[:not_met_percent], 0.001
              assert_in_delta 80.0, residential[:not_assessed_percent], 0.001
            end
          end
        end
      end
    end

    test "track_summary includes a row for each program track even without data" do
      aggregator = Reports::DataAggregator.new(user: @admin, params: {})

      aggregator.stub(:program_track_names, [ "Executive", "Residential" ]) do
        aggregator.stub(:assigned_student_count_for_track_and_year, 0) do
          aggregator.stub(:dataset_rows, []) do
            cohorts = [
              { key: "executive|unassigned", track_key: "executive", track: "Executive", class_of: nil, label: "Executive, Class Unassigned" },
              { key: "residential|unassigned", track_key: "residential", track: "Residential", class_of: nil, label: "Residential, Class Unassigned" }
            ]

            aggregator.stub(:track_cohort_metadata, cohorts) do
              summary = aggregator.track_summary

              assert_equal 2, summary.size
              assert_equal [ "Executive, Class Unassigned", "Residential, Class Unassigned" ], summary.map { |entry| entry[:cohort_label] }

              summary.each do |entry|
                assert_nil entry[:achieved_percent]
                assert_nil entry[:not_met_percent]
                assert_nil entry[:not_assessed_percent]
                assert_equal 0, entry[:achieved_count]
                assert_equal 0, entry[:not_met_count]
                assert_equal 0, entry[:not_assessed_count]
              end
            end
          end
        end
      end
    end
  end
end
