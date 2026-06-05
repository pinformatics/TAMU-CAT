# frozen_string_literal: true

require "test_helper"

module Reports
  class CompetencyInsightsTest < ActiveSupport::TestCase
    test "normalizes dashboard category and competency filters for matrix-backed exports" do
      domain_name = DataAggregator::REPORT_DOMAINS.first
      competency_title = DataAggregator::COMPETENCY_TITLES.first

      service = CompetencyInsights.new(
        user: users(:admin),
        params: {
          category_id: domain_name.parameterize(separator: "_"),
          competency: competency_title.parameterize(separator: "_")
        }
      )

      normalized = service.send(:params)

      assert_equal domain_name, normalized[:domain]
      assert_equal [ competency_title ], normalized[:competencies]
    end

    test "preserves explicit matrix filters when both filter styles are present" do
      explicit_domain = DataAggregator::REPORT_DOMAINS.second
      explicit_competency = DataAggregator::COMPETENCY_TITLES.second

      service = CompetencyInsights.new(
        user: users(:admin),
        params: {
          domain: explicit_domain,
          category_id: DataAggregator::REPORT_DOMAINS.first.parameterize(separator: "_"),
          competencies: [ explicit_competency ],
          competency: DataAggregator::COMPETENCY_TITLES.first.parameterize(separator: "_")
        }
      )

      normalized = service.send(:params)

      assert_equal explicit_domain, normalized[:domain]
      assert_equal [ explicit_competency ], normalized[:competencies]
    end

    test "filter helpers cover blank numeric slug and unknown values" do
      category = categories(:clinical_skills)
      category.update!(name: DataAggregator::REPORT_DOMAINS.first)
      service = CompetencyInsights.new(user: users(:admin), params: {})

      assert_nil service.send(:domain_name_for_filter, nil)
      assert_equal DataAggregator::REPORT_DOMAINS.first, service.send(:domain_name_for_filter, category.id.to_s)
      assert_equal DataAggregator::REPORT_DOMAINS.first, service.send(:domain_name_for_filter, DataAggregator::REPORT_DOMAINS.first)
      assert_equal DataAggregator::REPORT_DOMAINS.first, service.send(:domain_name_for_filter, DataAggregator::REPORT_DOMAINS.first.parameterize(separator: "_"))
      assert_nil service.send(:domain_name_for_filter, "999999")
      assert_nil service.send(:domain_name_for_filter, "not-a-domain")

      title = DataAggregator::COMPETENCY_TITLES.first
      assert_nil service.send(:competency_title_for_filter, nil)
      assert_equal title, service.send(:competency_title_for_filter, title)
      assert_equal title, service.send(:competency_title_for_filter, title.parameterize(separator: "_"))
      assert_nil service.send(:competency_title_for_filter, "not-a-competency")
    end

    test "matrix-backed insights build cohort heatmap and target rows" do
      service = CompetencyInsights.new(user: users(:admin), params: { semester: "Fall 2025" })
      communication = DataAggregator::COMPETENCY_TITLES.first
      payload = {
        filters: { semester: "All" },
        filter_options: { tracks: [ "Residential" ] },
        students: [
          {
            id: 1,
            name: "Student One",
            track: "Residential",
            program_year: "2026",
            ratings: {
              communication => { self_rating: 4, advisor_rating: 5, course_rating: 3, program_target: 4 }
            }
          },
          {
            id: 2,
            name: "Student Two",
            track: "Executive",
            program_year: nil,
            ratings: {
              communication => { self_rating: 2, advisor_rating: nil, course_rating: nil, program_target: 3 }
            }
          }
        ],
        domains: [
          {
            name: "Leadership Skills",
            competencies: [ { title: communication } ]
          }
        ]
      }

      service.stub(:matrix_payload, payload) do
        result = service.call

        assert_equal [ "Student One", "Student Two" ], result[:filter_options][:students].map { |row| row[:name] }
        assert result[:cohort_comparison].any? { |row| row[:program_year] == "2026" }
        assert result[:cohort_comparison].any? { |row| row[:program_year] == "Unassigned" }
        assert_equal "watch", result[:heatmap].first[:domains].first[:status]
        assert_equal 0, result[:target_attainment].first[:met_count]
        assert_equal 1, result[:target_attainment].second[:total_count]
      end
    end

    test "average target and heatmap helpers cover edge statuses" do
      service = CompetencyInsights.new(user: users(:admin), params: {})

      assert_nil service.send(:average, [])
      assert_equal 3.5, service.send(:average, [ 3, nil, 4 ])
      assert_equal "missing", service.send(:heatmap_status, nil)
      assert_equal "strong", service.send(:heatmap_status, 4)
      assert_equal "watch", service.send(:heatmap_status, 3)
      assert_equal "attention", service.send(:heatmap_status, 2)

      assert service.send(:target_met?, { program_target: 3, course_rating: 3, self_rating: 1 })
      assert service.send(:target_met?, { program_target: 3, course_rating: nil, self_rating: 4 })
      refute service.send(:target_met?, { program_target: nil, course_rating: 5, self_rating: 5 })
      refute service.send(:target_met?, { program_target: 4, course_rating: nil, self_rating: nil })
      refute service.send(:target_met?, { program_target: 4, course_rating: 3, self_rating: 5 })
    end

    test "matrix payload for semester reuses current payload for current or all semesters" do
      service = CompetencyInsights.new(user: users(:admin), params: { semester: "Fall 2025" })
      payload = { students: [], domains: [], filter_options: {}, filters: {} }

      service.stub(:matrix_payload, payload) do
        assert_same payload, service.send(:matrix_payload_for_semester, "Fall 2025")
      end

      all_service = CompetencyInsights.new(user: users(:admin), params: { semester: "All" })
      all_service.stub(:matrix_payload, payload) do
        assert_same payload, all_service.send(:matrix_payload_for_semester, "All semesters")
      end
    end
  end
end
