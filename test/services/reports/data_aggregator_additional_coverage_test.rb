require "test_helper"

class DataAggregatorAdditionalCoverageTest < ActiveSupport::TestCase
  setup do
    @admin = users(:admin)
    @advisor = users(:advisor)
    @student = users(:student)
  end

  test "accessible_student_relation respects user role" do
    aggregator = Reports::DataAggregator.new(user: nil, params: {})
    assert_equal 0, aggregator.send(:accessible_student_relation).count

    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    assert_equal Student.count, aggregator.send(:accessible_student_relation).count

    aggregator = Reports::DataAggregator.new(user: @advisor, params: {})
    assert_equal @advisor.advisor_profile.advisees.count, aggregator.send(:accessible_student_relation).count

    aggregator = Reports::DataAggregator.new(user: @student, params: {})
    assert_equal 0, aggregator.send(:accessible_student_relation).count
  end

  test "accessible_student_relation scopes by advisor profile for non-admin/advisor users" do
    advisor_profile = advisors(:advisor)
    student_in_scope = students(:student)
    student_out_of_scope = students(:other_student)

    pseudo_user = Struct.new(:advisor_profile) do
      def role_admin? = false
      def role_advisor? = false
    end

    aggregator = Reports::DataAggregator.new(user: pseudo_user.new(advisor_profile), params: {})

    ids = aggregator.send(:accessible_student_relation).pluck(:student_id)
    assert_includes ids, student_in_scope.student_id
    assert_equal true, ids.exclude?(student_out_of_scope.student_id)
  end

  test "scoped_student_relation limits to students with assignments when survey filter present" do
    survey = surveys(:fall_2025)
    assigned_student = students(:student)
    other_student = students(:other_student)

    aggregator = Reports::DataAggregator.new(user: @admin, params: { survey_id: survey.id.to_s })

    ids = aggregator.send(:scoped_student_relation).pluck(:student_id)
    assert_includes ids, assigned_student.student_id
    assert_equal true, ids.exclude?(other_student.student_id)
  end

  test "filters ignore 'all' and parse ids" do
    params = {
      track: "All",
      semester: "all",
      survey_id: "0",
      advisor_id: advisors(:advisor).advisor_id.to_s,
      student_id: students(:student).student_id.to_s
    }

    aggregator = Reports::DataAggregator.new(user: @admin, params: params)
    filters = aggregator.send(:filters)

    assert_nil filters[:track]
    assert_nil filters[:semester]
    assert_nil filters[:survey_id]
    assert_equal advisors(:advisor).advisor_id, filters[:advisor_id]
    assert_equal students(:student).student_id, filters[:student_id]
  end

  test "summary_cards returns cards from benchmark" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    aggregator.stub(:benchmark, { cards: [ { key: "k" } ] }) do
      assert_equal [ { key: "k" } ], aggregator.summary_cards
    end
  end

  test "filtered_scope applies common filters without raising" do
    survey = surveys(:fall_2025)
    params = {
      track: students(:student).track,
      semester: program_semesters(:fall_2025).name,
      survey_id: survey.id.to_s,
      student_id: students(:student).student_id.to_s,
      advisor_id: advisors(:advisor).advisor_id.to_s
    }

    aggregator = Reports::DataAggregator.new(user: @admin, params: params)
    scope = aggregator.send(:filtered_scope)
    assert scope.is_a?(ActiveRecord::Relation)
  end

  test "filtered_scope applies competency filter when lookup resolves a name" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    fake_relation = Class.new do
      attr_reader :where_calls
      def initialize
        @where_calls = []
      end

      def where(*args)
        @where_calls << args
        self
      end
    end.new

    aggregator.stub(:base_scope, fake_relation) do
      aggregator.stub(:selected_category_ids, []) do
        aggregator.stub(:filters, { competency: "communication" }) do
          aggregator.stub(:competency_lookup, { "communication" => { name: "Communication" } }) do
            out = aggregator.send(:filtered_scope)
            assert_same fake_relation, out
            assert_equal true, fake_relation.where_calls.any? { |args| args.first.to_s.include?("LOWER(questions.question_text)") }
          end
        end
      end
    end
  end

  test "filtered_feedback_scope applies competency and student/advisor filters" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    fake_relation = Class.new do
      attr_reader :where_calls
      def initialize
        @where_calls = []
      end

      def where(*args)
        @where_calls << args
        self
      end
    end.new

    aggregator.stub(:feedback_scope, fake_relation) do
      aggregator.stub(:selected_category_ids, []) do
        aggregator.stub(:filters, { competency: "communication", student_id: 1, advisor_id: 2 }) do
          aggregator.stub(:competency_lookup, { "communication" => { name: "Communication" } }) do
            out = aggregator.send(:filtered_feedback_scope)
            assert_same fake_relation, out
            assert_equal true, fake_relation.where_calls.any? { |args| args.first.to_s.include?("LOWER(questions.question_text)") }
            assert_includes fake_relation.where_calls, [ { feedback: { student_id: 1 } } ]
            assert_includes fake_relation.where_calls, [ { feedback: { advisor_id: 2 } } ]
          end
        end
      end
    end
  end

  test "student_response_groups groups only student entries" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    rows = [
      { student_id: 1, advisor_entry: false, score: 1 },
      { student_id: 1, advisor_entry: true, score: 2 },
      { student_id: 2, advisor_entry: false, score: 3 }
    ]

    aggregator.stub(:dataset_rows, rows) do
      grouped = aggregator.send(:student_response_groups)
      assert_equal [ 1, 2 ], grouped.keys.sort
      assert_equal 1, grouped[1].size
      assert_equal 1, grouped[2].size
    end
  end

  test "student_survey_response_pairs skips blank ids and checks assignment completion" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    fake_scope = Struct.new(:pairs) do
      def distinct = self
      def pluck(*_args) = pairs
    end

    pairs = [ [ nil, 1 ], [ 1, nil ], [ 1, 2 ] ]

    aggregator.stub(:filtered_scope, fake_scope.new(pairs)) do
      aggregator.stub(:assignment_completed?, true) do
        map = aggregator.send(:student_survey_response_pairs)
        assert_equal true, map[[ 1, 2 ]]
        assert_nil map[[ nil, 1 ]]
      end
    end
  end

  test "parse_numeric returns float for numeric strings and nil for non-numeric" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    assert_equal 3.0, aggregator.send(:parse_numeric, " 3 ")
    assert_equal 3.5, aggregator.send(:parse_numeric, "3.5")
    assert_nil aggregator.send(:parse_numeric, "not-a-number")
  end

  test "parse_numeric returns nil when to_s raises" do
    bad = Object.new
    def bad.to_s
      raise "boom"
    end

    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    assert_nil aggregator.send(:parse_numeric, bad)
  end

  test "change_direction returns expected values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    assert_equal "flat", aggregator.send(:change_direction, nil)
    assert_equal "up", aggregator.send(:change_direction, 0.1)
    assert_equal "down", aggregator.send(:change_direction, -0.1)
    assert_equal "flat", aggregator.send(:change_direction, 0)
  end

  test "parse_employment_integer ignores legacy non-integer values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    assert_equal 40, aggregator.send(:parse_employment_integer, "40")
    assert_equal 7, aggregator.send(:parse_employment_integer, " 7 ")
    assert_nil aggregator.send(:parse_employment_integer, nil)
    assert_nil aggregator.send(:parse_employment_integer, "")
    assert_nil aggregator.send(:parse_employment_integer, "forty")
    assert_nil aggregator.send(:parse_employment_integer, "40 hours")
    assert_nil aggregator.send(:parse_employment_integer, "35.5")
  end

  test "percent_change_for returns nil when previous average is zero" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    average_call = 0
    aggregator.stub(:scores_for, [ 1, 2 ]) do
      aggregator.stub(:average, ->(_scores) {
        average_call += 1
        average_call == 1 ? 1.0 : 0.0
      }) do
        assert_nil aggregator.send(:percent_change_for, :student)
      end
    end
  end

  test "percent_change_for returns a percent when both averages are present" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    average_call = 0
    aggregator.stub(:scores_for, [ 1, 2 ]) do
      aggregator.stub(:average, ->(_scores) {
        average_call += 1
        average_call == 1 ? 2.0 : 1.0
      }) do
        assert_equal 100.0, aggregator.send(:percent_change_for, :student)
      end
    end
  end

  test "percent_change_for_category returns a percent when both averages are present" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    recent = Time.current - 1.day
    previous = Time.current - 120.days

    rows = [
      { advisor_entry: false, updated_at: recent, score: 4.0 },
      { advisor_entry: false, updated_at: previous, score: 2.0 }
    ]

    assert_equal 100.0, aggregator.send(:percent_change_for_category, rows)
  end

  test "program_track_names uses ProgramTrack.names when data source not ready" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    ProgramTrack.stub(:data_source_ready?, false) do
      ProgramTrack.stub(:names, [ "  Residential ", "", nil, "Executive", "executive" ]) do
        assert_equal [ "Residential", "Executive", "executive" ], aggregator.send(:program_track_names)
      end
    end
  end

  test "normalized_track_name returns fallback for blank" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    assert_equal "Unspecified Track", aggregator.send(:normalized_track_name, "   ")
    assert_equal "Residential", aggregator.send(:normalized_track_name, " Residential ")
  end

  test "parse_category_filter resolves numeric ids and domain labels" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    fake_lookup = {
      "leadership_skills" => { id: "leadership_skills", name: "Leadership Skills", ids: [ 123 ] }
    }

    aggregator.stub(:category_id_to_slug, { 123 => "leadership_skills" }) do
      aggregator.stub(:category_group_lookup, fake_lookup) do
        assert_equal "leadership_skills", aggregator.send(:parse_category_filter, "123")
        assert_equal "leadership_skills", aggregator.send(:parse_category_filter, "Leadership Skills")
        assert_nil aggregator.send(:parse_category_filter, "999")
        assert_nil aggregator.send(:parse_category_filter, "all")
        assert_nil aggregator.send(:parse_category_filter, "   ")
      end
    end
  end

  test "selected_category_ids returns ids for selected slug" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    aggregator.stub(:filters, { category_id: "leadership_skills" }) do
      aggregator.stub(:category_group_lookup, { "leadership_skills" => { ids: [ 1, 2, 3 ] } }) do
        assert_equal [ 1, 2, 3 ], aggregator.send(:selected_category_ids)
      end
    end
  end

  test "build_course_competency_breakdown groups by category and returns averages" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    rows = [
      { category_id: 1, category_name: "Leadership", advisor_entry: false, student_id: 1, score: 4.0 },
      { category_id: 1, category_name: "Leadership", advisor_entry: true, student_id: 1, score: 3.0 }
    ]

    aggregator.stub(:attainment_counts_for_group, { achieved_count: 1, not_met_count: 0, not_assessed_count: 0, total_students: 1 }) do
      aggregator.stub(:attainment_percentages, { achieved_percent: 100.0, not_met_percent: 0.0, not_assessed_percent: 0.0 }) do
        out = aggregator.send(:build_course_competency_breakdown, rows)
        assert_equal 1, out.size
        assert_equal 1, out.first[:id]
        assert_equal "Leadership", out.first[:name]
        assert_equal 4.0, out.first[:student_average]
        assert_equal 3.0, out.first[:advisor_average]
      end
    end
  end

  test "student_competency_averages groups scores by student and competency" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    rows = [
      { advisor_entry: false, student_id: 1, question_text: "Communication", score: 4.0 },
      { advisor_entry: false, student_id: 1, question_text: "Communication", score: 2.0 },
      { advisor_entry: true, student_id: 1, question_text: "Communication", score: 1.0 },
      { advisor_entry: false, student_id: 2, question_text: "Communication", score: 3.0 }
    ]

    aggregator.stub(:dataset_rows, rows) do
      aggregator.stub(:competency_lookup, { "communication" => { name: "Communication" } }) do
        out = aggregator.send(:student_competency_averages)
        assert_equal 3.0, out[1]["communication"]
        assert_equal 3.0, out[2]["communication"]
      end
    end
  end

  test "format_survey_label returns nil when entry is nil" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    assert_nil aggregator.send(:format_survey_label, nil)
  end

  test "competency_target_level_any_year_lookup selects lowest program year" do
    semester_id = program_semesters(:fall_2025).id
    track = "Residential"
    title = "Communication"

    row = Struct.new(:program_semester_id, :track, :program_year, :class_of, :competency_title, :target_level)
    rows = [
      row.new(semester_id, track, 2026, nil, title, 5),
      row.new(semester_id, track, 2025, nil, title, 4),
      row.new(semester_id, track, nil, nil, title, 3)
    ]

    relation = Struct.new(:rows) do
      def find_each(&block)
        rows.each(&block)
      end
    end

    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    CompetencyTargetLevel.stub(:select, relation.new(rows)) do
      key = [ semester_id, ProgramTrack.canonical_key(track), title ]
      assert_equal 4, aggregator.send(:competency_target_level_any_year_lookup)[key]
    end
  end
end
__END__
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    average_call = 0
    aggregator.stub(:scores_for, [1, 2]) do
      aggregator.stub(:average, ->(_scores) {
        average_call += 1
        average_call == 1 ? 1.0 : 0.0
      }) do
        assert_nil aggregator.send(:percent_change_for, :student)
      end
    end
  end

  test "build_timeline returns empty when no dataset rows" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    aggregator.stub(:dataset_rows, []) do
      assert_equal [], aggregator.send(:build_timeline)
    end
  end

  test "completion_stats uses scoped student ids when no assignments found" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    empty_scope = SurveyAssignment.none

    aggregator.stub(:scoped_assignment_scope, empty_scope) do
      aggregator.stub(:scoped_student_ids, [1, 2, 3]) do
        stats = aggregator.send(:completion_stats)
        assert_equal 3, stats[:total_assignments]
        assert_equal 0, stats[:completed_assignments]
      end
    end
  end

  test "alignment_trend_change handles nil values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    aggregator.stub(:build_timeline, [ { alignment: nil }, { alignment: 10 } ]) do
      assert_nil aggregator.send(:alignment_trend_change)
    end

    aggregator.stub(:build_timeline, [ { alignment: 10 }, { alignment: 15 } ]) do
      assert_equal 5, aggregator.send(:alignment_trend_change)
    end
  end

  test "program_track_names uses ProgramTrack.names when data source not ready" do

      test "normalized_track_name returns fallback for blank" do
        aggregator = Reports::DataAggregator.new(user: @admin, params: {})
        assert_equal "Unspecified Track", aggregator.send(:normalized_track_name, "   ")
        assert_equal "Residential", aggregator.send(:normalized_track_name, " Residential ")
      end
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    ProgramTrack.stub(:data_source_ready?, false) do
      ProgramTrack.stub(:names, ["  Residential ", "", nil, "Executive", "executive" ]) do
        assert_equal ["Residential", "Executive", "executive"], aggregator.send(:program_track_names)
      end
    end
  end

  test "parse_category_filter resolves numeric ids and domain labels" do

      test "selected_category_ids returns ids for selected slug" do
        aggregator = Reports::DataAggregator.new(user: @admin, params: {})

        aggregator.stub(:filters, { category_id: "leadership_skills" }) do
          aggregator.stub(:category_group_lookup, { "leadership_skills" => { ids: [1, 2, 3] } }) do
            assert_equal [1, 2, 3], aggregator.send(:selected_category_ids)
          end
        end
      end
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    fake_lookup = {
      "leadership_skills" => { id: "leadership_skills", name: "Leadership Skills", ids: [123] }
    }

    aggregator.stub(:category_id_to_slug, { 123 => "leadership_skills" }) do
      aggregator.stub(:category_group_lookup, fake_lookup) do
        assert_equal "leadership_skills", aggregator.send(:parse_category_filter, "123")
        assert_equal "leadership_skills", aggregator.send(:parse_category_filter, "Leadership Skills")
        assert_nil aggregator.send(:parse_category_filter, "999")
        assert_nil aggregator.send(:parse_category_filter, "all")
        assert_nil aggregator.send(:parse_category_filter, "   ")
      end
    end
  end

  test "export_filters falls back to All-* labels when filters unset" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    aggregator.stub(:available_advisors, []) do
      aggregator.stub(:available_categories, []) do
        aggregator.stub(:available_surveys, []) do
          aggregator.stub(:available_students, []) do
            aggregator.stub(:available_competencies, []) do
              filters = aggregator.send(:export_filters)

              assert_equal "All tracks", filters[:track]
              assert_equal "All semesters", filters[:semester]
              assert_equal "All advisors", filters[:advisor]
              assert_equal "All domains", filters[:domain]
              assert_equal "All competencies", filters[:competency]
              assert_equal CourseCompetencyRule.label_for(CourseCompetencyRule::DEFAULT_RULE), filters[:course_competency_rule]
              assert_equal "All surveys", filters[:survey]
              assert_equal "All students", filters[:student]
            end
          end
        end
      end
    end
  end

  test "assignment helpers handle blank and non-blank keys" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    assert_nil aggregator.send(:assignment_pair_key, nil, 1)
    assert_nil aggregator.send(:assignment_pair_key, 1, nil)

    aggregator.stub(:completed_assignment_pairs, { [1, 2] => true }) do
      assert_equal true, aggregator.send(:assignment_completed?, 1, 2)
      assert_equal false, aggregator.send(:assignment_completed?, 1, 3)
      assert_equal false, aggregator.send(:assignment_completed?, nil, 2)
      assert_equal false, aggregator.send(:assignment_completed?, 1, nil)
    end
  end

  test "build_dataset_row returns nil for non-numeric response values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    record = Struct.new(:response_value).new("abc")
    assert_nil aggregator.send(:build_dataset_row, record, is_advisor_entry: false)
  end

  test "build_dataset_row builds a normalized hash for numeric response values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    record = Struct.new(
      :response_value,
      :student_question_id,
      :updated_at,
      :category_id,
      :category_name,
      :question_text,
      :program_target_level,
      :survey_id,
      :survey_title,
      :survey_semester,
      :student_track,
      :student_primary_id,
      :owning_advisor_id,
      :advisor_id
    ).new(
      "4.0",
      123,
      Time.current,
      7,
      "Leadership Skills",
      "Communication",
      3,
      11,
      "Fall Survey",
      "Fall 2025",
      "Residential",
      99,
      nil,
      55
    )

    aggregator.stub(:competency_target_level_for_record, 3) do
      row = aggregator.send(:build_dataset_row, record, is_advisor_entry: true)
      assert_equal 123, row[:id]
      assert_equal 4.0, row[:score]
      assert_equal true, row[:advisor_entry]
      assert_equal 3, row[:program_target_level]
      assert_equal 55, row[:advisor_id]
    end
  end

  test "export_filters resolves selected ids and formats survey label" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    aggregator.stub(:filters, {
      track: "Residential",
      semester: "Fall 2025",
      advisor_id: 1,
      category_id: "leadership_skills",
      competency: "communication",
      survey_id: 11,
      student_id: 99
    }) do
      aggregator.stub(:available_advisors, [ { id: 1, name: "Dr. Advisor" } ]) do
        aggregator.stub(:available_categories, [ { id: "leadership_skills", name: "Leadership Skills", category_ids: [1] } ]) do
          aggregator.stub(:available_surveys, [ { id: 11, title: "Fall Survey", semester: "Fall 2025" } ]) do
            aggregator.stub(:available_students, [ { id: 99, name: "Student Name", track: "Residential", advisor_id: 1 } ]) do
              aggregator.stub(:available_competencies, [ { id: "communication", name: "Communication" } ]) do
                SiteSetting.set_course_competency_rule!("avg")
                out = aggregator.send(:export_filters)
                assert_equal "Residential", out[:track]
                assert_equal "Fall 2025", out[:semester]
                assert_equal "Dr. Advisor", out[:advisor]
                assert_equal "Leadership Skills", out[:domain]
                assert_equal "Communication", out[:competency]
                assert_equal "Avg", out[:course_competency_rule]
                assert_equal "Fall Survey · Fall 2025", out[:survey]
                assert_equal "Student Name", out[:student]
              end
            end
          end
        end
      end
    end
  ensure
    SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
  end

  test "format_survey_label returns nil when entry is nil" do

      test "build_course_competency_breakdown groups by category and returns averages" do
        aggregator = Reports::DataAggregator.new(user: @admin, params: {})
        rows = [
          { category_id: 1, category_name: "Leadership", advisor_entry: false, student_id: 1, score: 4.0 },
          { category_id: 1, category_name: "Leadership", advisor_entry: true, student_id: 1, score: 3.0 }
        ]

        aggregator.stub(:attainment_counts_for_group, { achieved_count: 1, not_met_count: 0, not_assessed_count: 0, total_students: 1 }) do
          aggregator.stub(:attainment_percentages, { achieved_percent: 100.0, not_met_percent: 0.0, not_assessed_percent: 0.0 }) do
            out = aggregator.send(:build_course_competency_breakdown, rows)
            assert_equal 1, out.size
            assert_equal 1, out.first[:id]
            assert_equal "Leadership", out.first[:name]
            assert_equal 4.0, out.first[:student_average]
            assert_equal 3.0, out.first[:advisor_average]
          end
        end
      end

      test "student_competency_averages groups scores by student and competency" do
        aggregator = Reports::DataAggregator.new(user: @admin, params: {})

        rows = [
          { advisor_entry: false, student_id: 1, question_text: "Communication", score: 4.0 },
          { advisor_entry: false, student_id: 1, question_text: "Communication", score: 2.0 },
          { advisor_entry: true, student_id: 1, question_text: "Communication", score: 1.0 },
          { advisor_entry: false, student_id: 2, question_text: "Communication", score: 3.0 }
        ]

        aggregator.stub(:dataset_rows, rows) do
          aggregator.stub(:competency_lookup, { "communication" => { name: "Communication" } }) do
            out = aggregator.send(:student_competency_averages)
            assert_equal 3.0, out[1]["communication"]
            assert_equal 3.0, out[2]["communication"]
          end
        end
      end
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    assert_nil aggregator.send(:format_survey_label, nil)
  end

  test "competency_target_level_any_year_lookup selects lowest program year" do
    semester = program_semesters(:fall_2025)
    track = "Residential"
    title = "Communication"

    CompetencyTargetLevel.create!(
      program_semester: semester,
      track: track,
      program_year: 2026,
      competency_title: title,
      target_level: 5
    )
    CompetencyTargetLevel.create!(
      program_semester: semester,
      track: track,
      program_year: 2025,
      competency_title: title,
      target_level: 4
    )

    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    key = [semester.id, track, title]
    assert_equal 4, aggregator.send(:competency_target_level_any_year_lookup)[key]
  end

  test "sanitize_tracks removes blanks and normalizes uniqueness" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    values = [nil, "", " Residential ", "executive", "Executive", "residential"]
    assert_equal ["executive", "Residential"], aggregator.send(:sanitize_tracks, values)
  end

  test "group_student_rows groups by student_id and skips blanks" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    rows = [
      { student_id: nil, score: 1 },
      { student_id: "", score: 2 },
      { student_id: 1, score: 3 },
      { student_id: 1, score: 4 },
      { student_id: 2, score: 5 }
    ]
    grouped = aggregator.send(:group_student_rows, rows)
    assert_equal [1, 2], grouped.keys.sort
    assert_equal 2, grouped[1].size
    assert_equal 1, grouped[2].size
  end

  test "assigned student count helpers handle blank and present values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    assert_equal 0, aggregator.send(:assigned_student_count_for_survey, nil)

    survey = surveys(:fall_2025)
    assert aggregator.send(:assigned_student_count_for_survey, survey.id).is_a?(Integer)

    track = students(:student).track
    assert aggregator.send(:assigned_student_count_for_track, track).is_a?(Integer)
  end
end
