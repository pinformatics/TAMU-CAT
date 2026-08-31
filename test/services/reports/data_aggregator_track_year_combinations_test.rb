# frozen_string_literal: true

require "test_helper"

module Reports
  class DataAggregatorTrackYearCombinationsTest < ActiveSupport::TestCase
    test "returns one entry per distinct track/program_year pair, normalized to canonical keys" do
      admin = users(:admin)
      aggregator = Reports::DataAggregator.new(user: admin, params: {})

      combinations = aggregator.available_track_year_combinations

      assert_includes combinations, { track_key: "residential", track_name: "Residential", program_year: 2026 }
      assert_includes combinations, { track_key: "executive", track_name: "Executive", program_year: 2027 }
      # student and completed_student fixtures share (Residential, 2026) -- must not produce a duplicate row.
      assert_equal combinations.uniq.size, combinations.size
    end

    test "scopes to the advisor's own advisees only" do
      advisor_user = users(:advisor)
      aggregator = Reports::DataAggregator.new(user: advisor_user, params: {})

      combinations = aggregator.available_track_year_combinations

      combinations.each do |entry|
        assert_equal "residential", entry[:track_key]
        assert_equal 2026, entry[:program_year]
      end
    end

    test "returns an empty array when the user has no visible students" do
      student_user = users(:student)
      aggregator = Reports::DataAggregator.new(user: student_user, params: {})

      assert_equal [], aggregator.available_track_year_combinations
    end
  end
end
