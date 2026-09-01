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

  test "employment helpers classify fields parse stored values and bucket hours" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    record = Struct.new(:response_value)

    assert_equal :currently_employed, aggregator.send(:employment_field_key, "Are you currently employed?")
    assert_equal :employer, aggregator.send(:employment_field_key, "If yes, where are you employed?")
    assert_equal :job_title, aggregator.send(:employment_field_key, "What is your title?")
    assert_equal :hours_per_week, aggregator.send(:employment_field_key, "How many hours per week?")
    assert_equal :flexibility, aggregator.send(:employment_field_key, "How flexible are your work hours?")
    assert_nil aggregator.send(:employment_field_key, "Unrelated question")

    assert_equal "Yes", aggregator.send(:parse_employment_value, record.new("Yes"))
    assert_equal "No", aggregator.send(:parse_employment_value, record.new({ answer: "No" }.to_json))
    assert_equal "Some", aggregator.send(:parse_employment_value, record.new({ value: "Some" }.to_json))
    assert_equal "4", aggregator.send(:parse_employment_value, record.new({ rating: "4" }.to_json))
    assert_equal "First", aggregator.send(:parse_employment_value, record.new([ "First", "Second" ].to_json))
    assert_equal "{not json", aggregator.send(:parse_employment_value, record.new("{not json"))

    assert_equal "<10", aggregator.send(:hours_bucket, 0)
    assert_equal "10–19", aggregator.send(:hours_bucket, 10)
    assert_equal "20–29", aggregator.send(:hours_bucket, 20)
    assert_equal "30–39", aggregator.send(:hours_bucket, 30)
    assert_equal "40–49", aggregator.send(:hours_bucket, 40)
    assert_equal "50+", aggregator.send(:hours_bucket, 50)
  end

  test "employment summary aggregates one response set per student" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    row = Struct.new(:student_id, :question_text, :response_value, :student_track, :student_program_year)
    fake_scope = Struct.new(:records) do
      def select(*_columns)
        records
      end
    end

    records = [
      row.new(1, "Are you currently employed?", { answer: "Yes" }.to_json, "Residential", 2026),
      row.new(1, "How many hours per week do you work on average?", "8", "Residential", 2026),
      row.new(1, "How flexible are your work hours?", "5 — Very flexible", "Residential", 2026),
      row.new(1, "What is your title?", "Analyst", "Residential", 2026),
      row.new(2, "Are you currently employed?", "No", "Residential", 2026),
      row.new(3, "Are you currently employed?", "Maybe", "Executive", 2027),
      row.new(4, "Where are you employed?", "No status only", "Executive", 2027),
      row.new(5, "Are you currently employed?", "Yes", "Executive", 2027),
      row.new(5, "How many hours per week do you work on average?", "42", "Executive", 2027),
      row.new(5, "How flexible are your work hours?", "2 — Limited", "Executive", 2027)
    ]

    aggregator.stub(:employment_response_scope, fake_scope.new(records)) do
      summary = aggregator.employment_summary
      status_counts = summary[:status_counts].index_by { |entry| entry[:label] }

      assert_equal 5, summary[:total_respondents]
      assert_equal 40.0, summary[:employment_rate]
      assert_equal 2, status_counts.fetch("Employed")[:count]
      assert_equal 1, status_counts.fetch("Not employed")[:count]
      assert_equal 2, status_counts.fetch("No response")[:count]
      assert_equal [ "<10", "10–19", "20–29", "30–39", "40–49", "50+" ], summary[:hours_distribution][:labels]
      assert_equal 1, summary[:hours_distribution][:data].first
      assert_equal 1, summary[:hours_distribution][:data].fifth
      assert_equal 1, summary[:flexibility_distribution][:data][1]
      assert_equal 1, summary[:flexibility_distribution][:data][4]

      cohorts = summary[:cohorts].index_by { |entry| entry[:cohort_label] }
      residential = cohorts.fetch("Residential, Class of 2026")
      executive = cohorts.fetch("Executive, Class of 2027")

      assert_equal 2, residential[:total_respondents]
      assert_equal 50.0, residential[:employment_rate]
      assert_equal 3, executive[:total_respondents]
      assert_in_delta 33.3, executive[:employment_rate], 0.1
    end
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

  test "benchmark payload builds overall track completion and alignment cards" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    benchmark_attainment = {
      overall: {
        total_students: 3,
        total_competencies: 3,
        competencies_meeting_count: 2,
        competencies_not_meeting_count: 1,
        competencies_meeting_percent: 66.7,
        competencies_not_meeting_percent: 33.3,
        students_meeting_count: 2,
        students_meeting_percent: 66.7,
        students_not_meeting_percent: 33.3,
        students_goal_percent: 75.0
      },
      by_track: {
        "residential" => {
          total_students: 2,
          total_competencies: 2,
          competencies_meeting_count: 2,
          competencies_not_meeting_count: 0,
          competencies_meeting_percent: 100.0,
          competencies_not_meeting_percent: 0.0,
          label: "Residential"
        }
      },
      by_cohort: {
        "residential|2026" => {
          total_students: 2,
          total_competencies: 2,
          competencies_meeting_count: 2,
          competencies_not_meeting_count: 0,
          competencies_meeting_percent: 100.0,
          competencies_not_meeting_percent: 0.0,
          label: "Residential, Class of 2026",
          track: "Residential",
          class_of: 2026
        }
      },
      per_student: {},
      source_breakdown: {
        overall: { advisor: 1, student: 2 },
        by_track: {
          "residential" => { advisor: 1, student: 1 }
        },
        by_cohort: {
          "residential|2026" => { advisor: 1, student: 1 }
        }
      }
    }
    alignment_card = {
      key: "student_advisor_alignment",
      title: "Student & Advisor Alignment",
      value: 90.0,
      unit: "percent",
      precision: 0,
      change: nil,
      sample_size: 2
    }

    aggregator.stub(:dataset_rows, [ { student_id: 1 } ]) do
      aggregator.stub(:benchmark_attainment_stats, benchmark_attainment) do
        aggregator.stub(:build_alignment_card, alignment_card) do
          aggregator.stub(:completion_stats, { completion_rate: 75.0, trend: 5.0, total_assignments: 4 }) do
            aggregator.stub(:competency_summary, []) do
              aggregator.stub(:build_timeline, [ { label: "Jun 2026" } ]) do
                aggregator.stub(:rating_level_distribution, {}) do
                  aggregator.stub(:course_target_summary, []) do
                    payload = aggregator.send(:build_benchmark_payload)
                    card_keys = payload[:cards].map { |card| card[:key] }

                    assert_equal 75.0, payload[:completion_rate]
                    assert_includes card_keys, "benchmark_attainment_overall"
                    assert_includes card_keys, "benchmark_not_meeting_overall"
                    assert_includes card_keys, "benchmark_attainment_by_track"
                    assert_includes card_keys, "student_advisor_alignment"
                    track_card = payload[:cards].find { |card| card[:key] == "benchmark_attainment_by_track" }
                    assert_equal 1, track_card[:meta][:tracks].size
                    assert_equal "Residential, Class of 2026", track_card[:meta][:tracks].first[:label]
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  test "alignment card and source labels cover empty advisor student and mixed states" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    aggregator.stub(:alignment_summary, nil) do
      assert_nil aggregator.send(:build_alignment_card)
    end

    aggregator.stub(:alignment_summary, { percent: 80.0, change: -5.0, sample_size: 2, meta: { name: "Advisor & student ratings" } }) do
      card = aggregator.send(:build_alignment_card)
      assert_equal "student_advisor_alignment", card[:key]
      assert_equal "down", card[:change_direction]
    end

    assert_nil aggregator.send(:rating_source_label, { advisor: 0, student: 0 })
    assert_equal "Advisor ratings", aggregator.send(:rating_source_label, { advisor: 1, student: 0 })
    assert_equal "Student self-ratings", aggregator.send(:rating_source_label, { advisor: 0, student: 1 })
    assert_equal "Advisor & student ratings", aggregator.send(:rating_source_label, { advisor: 1, student: 1 })
  end

  test "benchmark attainment prefers advisor rows and newer duplicate rows" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    now = Time.current
    rows = [
      { student_id: nil, question_text: "Communication", score: 5, advisor_entry: false, updated_at: now, track: "Residential", program_target_level: 4 },
      { student_id: 1, question_text: nil, score: 5, advisor_entry: false, updated_at: now, track: "Residential", program_target_level: 4 },
      { student_id: 1, question_text: "Communication", score: 2, advisor_entry: false, updated_at: now - 2.days, track: "Residential", program_target_level: 4 },
      { student_id: 1, question_text: "Communication", score: 5, advisor_entry: true, updated_at: now - 1.day, track: "Residential", program_target_level: 4 },
      { student_id: 1, question_text: "Policy Analysis", score: 3, advisor_entry: false, updated_at: now - 1.day, track: "Residential", program_target_level: nil },
      { student_id: 1, question_text: "Policy Analysis", score: 5, advisor_entry: false, updated_at: now, track: "Residential", program_target_level: nil },
      { student_id: 2, question_text: "Communication", score: 1, advisor_entry: false, updated_at: nil, track: "Executive", program_target_level: 4 }
    ]

    stats = aggregator.send(:benchmark_attainment_stats, rows, competencies_goal_percent: 85)

    assert_equal 2, stats[:overall][:total_students]
    assert_equal 1, stats[:overall][:students_meeting_count]
    assert_equal true, stats[:per_student][1][:meets_benchmark]
    assert_equal false, stats[:per_student][2][:meets_benchmark]
    assert_equal 1, stats[:source_breakdown][:overall][:advisor]
    assert_equal 2, stats[:source_breakdown][:overall][:student]
    assert_equal 100.0, stats[:by_track]["residential"][:competencies_meeting_percent]
    assert_equal 0.0, stats[:by_track]["executive"][:competencies_meeting_percent]
  end

  test "program attainment distribution includes level zero and cohort percentages" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    rows = [
      {
        student_id: 1,
        question_text: "Communication",
        score: 0,
        advisor_entry: false,
        track: "Residential",
        class_of: 2026,
        program_target_level: 4
      },
      {
        student_id: 2,
        question_text: "Communication",
        score: 5,
        advisor_entry: false,
        track: "Residential",
        class_of: 2026,
        program_target_level: 4
      },
      {
        student_id: 3,
        question_text: "Communication",
        score: 4,
        advisor_entry: false,
        track: "Executive",
        class_of: 2027,
        program_target_level: 4
      }
    ]

    aggregator.stub(:dataset_rows, rows) do
      distribution = aggregator.rating_level_distribution
      residential = distribution[:items].find do |item|
        item[:cohort_label] == "Residential, Class of 2026"
      end
      executive = distribution[:cohorts].find do |item|
        item[:cohort_label] == "Executive, Class of 2027"
      end

      assert_equal "Not able to assess", distribution[:levels][0]
      assert_equal 75.0, distribution[:program_target_met_percent]
      assert_equal 1, residential[:level_counts][0]
      assert_equal 1, residential[:level_counts][5]
      assert_equal 1, residential[:target_met_count]
      assert_equal 1, residential[:target_not_met_count]
      assert_equal 50.0, residential[:target_met_percent]
      assert_equal 50.0, residential[:target_not_met_percent]
      assert_equal false, residential[:target_met]
      assert_equal 100.0, executive[:target_met_percent]
      assert_equal 0.0, executive[:target_not_met_percent]
    end
  end

  test "course target summary reports course achievement by track cohort" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    student = Struct.new(:track, :program_year) do
      def track_key
        ProgramTrack.canonical_key(track)
      end
    end
    row = Struct.new(:student, :student_id, :mapped_level, :course_target_level)
    relation = Struct.new(:rows) do
      def to_a
        rows
      end
    end

    residential = student.new("Residential", 2026)
    executive = student.new("Executive", 2027)
    rows = [
      row.new(residential, 1, 4, 4),
      row.new(residential, 1, 2, 4),
      row.new(executive, 2, 3, nil)
    ]

    aggregator.stub(:reportable_course_evidence_scope, relation.new(rows)) do
      summary = aggregator.course_target_summary.index_by { |entry| entry[:cohort_label] }
      residential_summary = summary.fetch("Residential, Class of 2026")
      executive_summary = summary.fetch("Executive, Class of 2027")

      assert_equal 1, residential_summary[:student_count]
      assert_equal 2, residential_summary[:evidence_count]
      assert_equal 1, residential_summary[:met_count]
      assert_equal 1, residential_summary[:below_count]
      assert_equal 50.0, residential_summary[:met_percent]
      assert_equal 50.0, residential_summary[:below_percent]
      assert_equal 1, executive_summary[:no_target_count]
      assert_nil executive_summary[:met_percent]
      assert_nil executive_summary[:below_percent]
    end
  end

  test "average percent and alignment helpers cover nil and clamped edges" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    assert_nil aggregator.send(:average, [])
    assert_nil aggregator.send(:safe_percent, 1, 0)
    assert_nil aggregator.send(:alignment_percent, nil, 3)
    assert_equal 100.0, aggregator.send(:alignment_percent, 3, 3)
    assert_equal 0.0, aggregator.send(:alignment_percent, 1, 9)
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
    assert_equal "Fall Survey · Fall 2025", aggregator.send(:format_survey_label, { title: "Fall Survey", semester: "Fall 2025" })
    assert_equal "Fall Survey", aggregator.send(:format_survey_label, { title: "Fall Survey", semester: nil })
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

  test "build_timeline returns empty when no dataset or course rows exist" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    aggregator.stub(:dataset_rows, []) do
      aggregator.stub(:course_rating_rows, []) do
        assert_equal [], aggregator.send(:build_timeline)
      end
    end
  end

  test "alignment_trend_change handles short nil and changed timelines" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    aggregator.stub(:build_timeline, [ { alignment: 10 } ]) do
      assert_nil aggregator.send(:alignment_trend_change)
    end

    aggregator.stub(:build_timeline, [ { alignment: nil }, { alignment: 10 } ]) do
      assert_nil aggregator.send(:alignment_trend_change)
    end

    aggregator.stub(:build_timeline, [ { alignment: 10 }, { alignment: 15 } ]) do
      assert_equal 5, aggregator.send(:alignment_trend_change)
    end
  end

  test "completion_stats uses scoped student ids when no assignments are found" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    empty_scope = SurveyAssignment.none

    aggregator.stub(:scoped_assignment_scope, empty_scope) do
      aggregator.stub(:scoped_student_ids, [ 1, 2, 3 ]) do
        stats = aggregator.send(:completion_stats)

        assert_equal 3, stats[:total_assignments]
        assert_equal 0, stats[:completed_assignments]
        assert_equal 0.0, stats[:completion_rate]
      end
    end
  end

  test "assignment helpers handle blank and non blank keys" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    assert_nil aggregator.send(:assignment_pair_key, nil, 1)
    assert_nil aggregator.send(:assignment_pair_key, 1, nil)

    aggregator.stub(:completed_assignment_pairs, { [ 1, 2 ] => true }) do
      assert_equal true, aggregator.send(:assignment_completed?, 1, 2)
      assert_equal false, aggregator.send(:assignment_completed?, 1, 3)
      assert_equal false, aggregator.send(:assignment_completed?, nil, 2)
      assert_equal false, aggregator.send(:assignment_completed?, 1, nil)
    end
  end

  test "build_dataset_row returns nil for non numeric values and normalized rows for numeric values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    bad_record = Struct.new(:response_value).new("abc")
    assert_nil aggregator.send(:build_dataset_row, bad_record, is_advisor_entry: false)

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
      :program_semester_id,
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
      program_semesters(:fall_2025).id,
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

  test "export_filters falls back and resolves selected filter labels" do
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
              assert_equal "All surveys", filters[:survey]
              assert_equal "All students", filters[:student]
            end
          end
        end
      end
    end

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
        aggregator.stub(:available_categories, [ { id: "leadership_skills", name: "Leadership Skills", category_ids: [ 1 ] } ]) do
          aggregator.stub(:available_surveys, [ { id: 11, title: "Fall Survey", semester: "Fall 2025" } ]) do
            aggregator.stub(:available_students, [ { id: 99, name: "Student Name", track: "Residential", advisor_id: 1 } ]) do
              aggregator.stub(:available_competencies, [ { id: "communication", name: "Communication" } ]) do
                SiteSetting.set_course_competency_rule!("avg")
                filters = aggregator.send(:export_filters)

                assert_equal "Residential", filters[:track]
                assert_equal "Fall 2025", filters[:semester]
                assert_equal "Dr. Advisor", filters[:advisor]
                assert_equal "Leadership Skills", filters[:domain]
                assert_equal "Communication", filters[:competency]
                assert_equal "Avg", filters[:course_competency_rule]
                assert_equal "Fall Survey · Fall 2025", filters[:survey]
                assert_equal "Student Name", filters[:student]
              end
            end
          end
        end
      end
    end
  ensure
    SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
  end

  test "sanitize_tracks and group_student_rows normalize values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    assert_equal [ "executive", "Residential" ], aggregator.send(:sanitize_tracks, [ nil, "", " Residential ", "executive", "Executive", "residential" ])

    grouped = aggregator.send(:group_student_rows, [
      { student_id: nil, score: 1 },
      { student_id: "", score: 2 },
      { student_id: 1, score: 3 },
      { student_id: 1, score: 4 },
      { student_id: 2, score: 5 }
    ])

    assert_equal [ 1, 2 ], grouped.keys.sort
    assert_equal 2, grouped[1].size
    assert_equal 1, grouped[2].size
  end

  test "assigned student count helpers handle blank and present values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    assert_equal 0, aggregator.send(:assigned_student_count_for_survey, nil)
    assert aggregator.send(:assigned_student_count_for_survey, surveys(:fall_2025).id).is_a?(Integer)
    assert aggregator.send(:assigned_student_count_for_track, students(:student).track).is_a?(Integer)
  end

  test "course rating scope applies semester competency and domain filters" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    aggregator.stub(:filters, { semester: "No Such Semester" }) do
      assert_equal [], aggregator.send(:reportable_course_rating_scope)
    end

    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    aggregator.stub(:filters, { category_id: "leadership_skills" }) do
      aggregator.stub(:domain_slug_for_competency, ->(title) { title == "Communication" ? "leadership_skills" : "other" }) do
        assert_equal [ "Communication" ], aggregator.send(:competency_titles_for_domain_filter)
      end
    end

    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    aggregator.stub(:filters, { category_id: nil }) do
      assert_equal Reports::DataAggregator::COMPETENCY_TITLES, aggregator.send(:competency_titles_for_domain_filter)
    end
  end

  test "scores_for separates advisor and student roles inside the selected range" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    now = Time.current
    rows = [
      { advisor_entry: true, updated_at: now, score: 5 },
      { advisor_entry: false, updated_at: now, score: 3 },
      { advisor_entry: true, updated_at: now - 1.year, score: 1 },
      { advisor_entry: false, updated_at: now - 1.year, score: 2 }
    ]

    aggregator.stub(:dataset_rows, rows) do
      range = (now - 1.day)..now
      assert_equal [ 5 ], aggregator.send(:scores_for, :advisor_entry, range)
      assert_equal [ 3 ], aggregator.send(:scores_for, :student_entry, range)
    end
  end

  test "build_card skips empty cards but keeps cards with track metadata" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    assert_nil aggregator.send(
      :build_card,
      key: "empty",
      title: "Empty",
      value: nil,
      unit: "percent",
      precision: 0,
      description: "No value",
      change: nil,
      sample_size: 0,
      meta: nil
    )

    card = aggregator.send(
      :build_card,
      key: "track",
      title: "Track",
      value: nil,
      unit: "percent",
      precision: 0,
      description: "Track metadata only",
      change: 1,
      sample_size: 2,
      meta: { tracks: [ { label: "Residential", percent: 90 } ] }
    )

    assert_equal "track", card[:key]
    assert_equal "up", card[:change_direction]
  end

  test "target percent handles empty scopes blank rows and met targets" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    rows = [
      { student_id: students(:student).student_id, score: 4, program_target_level: 3 },
      { student_id: students(:other_student).student_id, score: 2, program_target_level: nil },
      { student_id: nil, score: 5, program_target_level: 5 }
    ]

    aggregator.stub(:scoped_student_ids, []) do
      assert_nil aggregator.send(:target_percent_for_rows, rows)
    end

    aggregator.stub(:scoped_student_ids, [ students(:student).student_id, students(:other_student).student_id ]) do
      assert_equal 50.0, aggregator.send(:target_percent_for_rows, rows)
    end
  end

  test "attainment counts and percentages cover achieved not met missing and zero totals" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    rows_by_student = {
      1 => [
        { score: 5, program_target_level: 4 },
        { score: 3, program_target_level: 4 }
      ],
      2 => [ { score: 2, program_target_level: 4 } ],
      3 => [ { score: 5, program_target_level: nil } ],
      4 => []
    }

    counts = aggregator.send(:attainment_counts_for_group, rows_by_student, total_students: 3)
    assert_equal 1, counts[:achieved_count]
    assert_equal 1, counts[:not_met_count]
    assert_equal 1, counts[:not_assessed_count]
    assert_equal 3, counts[:total_students]

    percentages = aggregator.send(:attainment_percentages, counts)
    assert_equal 33.33333333333333, percentages[:achieved_percent]
    assert_equal 33.33333333333333, percentages[:not_met_percent]
    assert_equal 33.33333333333333, percentages[:not_assessed_percent]

    assert_equal(
      { achieved_percent: nil, not_met_percent: nil, not_assessed_percent: nil },
      aggregator.send(:attainment_percentages, { achieved_count: 0, not_met_count: 0, not_assessed_count: 0, total_students: 0 })
    )
  end

  test "alignment summary requires paired student and advisor data" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    now = Time.current

    aggregator.stub(:dataset_rows, [ { student_id: 1, advisor_entry: false, score: 4, updated_at: now } ]) do
      assert_nil aggregator.send(:alignment_summary)
    end

    paired_rows = [
      { student_id: 1, advisor_entry: false, score: 4, updated_at: now },
      { student_id: 1, advisor_entry: true, score: 5, updated_at: now },
      { student_id: 2, advisor_entry: false, score: 2, updated_at: now }
    ]

    aggregator.stub(:dataset_rows, paired_rows) do
      aggregator.stub(:alignment_trend_change, -2.5) do
        summary = aggregator.send(:alignment_summary)
        assert_equal 1, summary[:sample_size]
        assert_equal -2.5, summary[:change]
        assert_equal "Advisor & student ratings", summary[:meta][:name]
      end
    end
  end

  test "fallback course target level honors class and program year fallback order" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    semester_id = program_semesters(:fall_2025).id
    title = "Communication"
    target_record = Struct.new(:program_semester_id, :track, :class_of, :program_year, :competency_title, :target_level)
    target_student = Struct.new(:track_value, :class_of, :program_year) do
      def [](key)
        key == :track ? track_value : nil
      end
    end

    key = [ semester_id, "residential", title ]

    class_records = [
      target_record.new(semester_id, "Residential", 2026, nil, title, 5),
      target_record.new(semester_id, "Residential", nil, nil, title, 3)
    ]
    aggregator.stub(:competency_target_records_by_semester_track_and_title, { key => class_records }) do
      assert_equal 5, aggregator.send(:fallback_course_target_level, student: target_student.new("Residential", 2026, nil), competency_title: title, program_semester_id: semester_id)
      assert_equal 3, aggregator.send(:fallback_course_target_level, student: target_student.new("Residential", 2030, nil), competency_title: title, program_semester_id: semester_id)
    end

    year_records = [
      target_record.new(semester_id, "Residential", 9999, 2026, title, 4),
      target_record.new(semester_id, "Residential", 9999, nil, title, 2)
    ]
    aggregator.stub(:competency_target_records_by_semester_track_and_title, { key => year_records }) do
      assert_equal 4, aggregator.send(:fallback_course_target_level, student: target_student.new("Residential", nil, 2026), competency_title: title, program_semester_id: semester_id)
      assert_equal 2, aggregator.send(:fallback_course_target_level, student: target_student.new("Residential", nil, 2028), competency_title: title, program_semester_id: semester_id)
    end

    first_record = [ target_record.new(semester_id, "Residential", 9999, 2025, title, 1) ]
    aggregator.stub(:competency_target_records_by_semester_track_and_title, { key => first_record }) do
      assert_equal 1, aggregator.send(:fallback_course_target_level, student: target_student.new("Residential", nil, 2030), competency_title: title, program_semester_id: semester_id)
    end

    aggregator.stub(:competency_target_records_by_semester_track_and_title, {}) do
      assert_nil aggregator.send(:fallback_course_target_level, student: target_student.new(nil, nil, nil), competency_title: title, program_semester_id: semester_id)
      assert_nil aggregator.send(:fallback_course_target_level, student: target_student.new("Residential", nil, nil), competency_title: "", program_semester_id: semester_id)
      assert_nil aggregator.send(:fallback_course_target_level, student: target_student.new("Residential", nil, nil), competency_title: title, program_semester_id: nil)
    end
  end

  test "competency target level for record uses semester track class year and fallback values" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    semester_id = program_semesters(:fall_2025).id
    record = Struct.new(:program_target_level, :program_semester_id, :student_track, :question_text, :student_class_of, :student_program_year, keyword_init: true)
    bare_record = Struct.new(:program_target_level)

    assert_equal 2, aggregator.send(:competency_target_level_for_record, bare_record.new(2))

    base_key = [ semester_id, "residential", "Communication" ]
    lookup_bundle = {
      class_of_exact: {
        [ semester_id, "residential", 2026, "Communication" ] => 5,
        [ semester_id, "residential", nil, "Communication" ] => 4
      },
      class_of_any: { base_key => 3 },
      program_year_exact: {
        [ semester_id, "residential", 2027, "Communication" ] => 2,
        [ semester_id, "residential", nil, "Communication" ] => 1
      },
      program_year_any_year: { base_key => 6 }
    }

    aggregator.stub(:competency_target_level_lookup_bundle, lookup_bundle) do
      assert_equal 5, aggregator.send(:competency_target_level_for_record, record.new(program_target_level: 9, program_semester_id: semester_id, student_track: "Residential", question_text: "Communication", student_class_of: 2026, student_program_year: 2027))
      assert_equal 4, aggregator.send(:competency_target_level_for_record, record.new(program_target_level: 9, program_semester_id: semester_id, student_track: "Residential", question_text: "Communication", student_class_of: 2028, student_program_year: 2027))
    end

    lookup_bundle[:class_of_exact] = {}
    aggregator.stub(:competency_target_level_lookup_bundle, lookup_bundle) do
      assert_equal 3, aggregator.send(:competency_target_level_for_record, record.new(program_target_level: 9, program_semester_id: semester_id, student_track: "Residential", question_text: "Communication", student_class_of: nil, student_program_year: 2027))
    end

    lookup_bundle[:class_of_any] = {}
    aggregator.stub(:competency_target_level_lookup_bundle, lookup_bundle) do
      assert_equal 2, aggregator.send(:competency_target_level_for_record, record.new(program_target_level: 9, program_semester_id: semester_id, student_track: "Residential", question_text: "Communication", student_class_of: nil, student_program_year: 2027))
      assert_equal 1, aggregator.send(:competency_target_level_for_record, record.new(program_target_level: 9, program_semester_id: semester_id, student_track: "Residential", question_text: "Communication", student_class_of: nil, student_program_year: 2030))
    end

    lookup_bundle[:program_year_exact] = {}
    aggregator.stub(:competency_target_level_lookup_bundle, lookup_bundle) do
      assert_equal 6, aggregator.send(:competency_target_level_for_record, record.new(program_target_level: 9, program_semester_id: semester_id, student_track: "Residential", question_text: "Communication", student_class_of: nil, student_program_year: nil))
      assert_equal 9, aggregator.send(:competency_target_level_for_record, record.new(program_target_level: 9, program_semester_id: semester_id, student_track: "Residential", question_text: "Communication", student_class_of: 2030, student_program_year: 2030))
    end
  end

  test "course target level for rating prefers dataset targets and handles semester fallback" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    batch = Struct.new(:program_semester_id)
    rating = Struct.new(:student, :competency_title, :grade_import_batch)
    student = students(:student)
    semester_id = program_semesters(:fall_2025).id

    assert_nil aggregator.send(:course_target_level_for_rating, rating.new(nil, "Communication", nil))
    assert_equal semester_id, aggregator.send(:target_program_semester_id_for_rating, rating.new(student, "Communication", batch.new(semester_id)))

    aggregator_with_filter = Reports::DataAggregator.new(user: @admin, params: { semester: "Fall 2025" })
    assert_equal semester_id, aggregator_with_filter.send(:target_program_semester_id_for_rating, rating.new(student, "Communication", nil))
    assert_equal ProgramSemester.current&.id, aggregator.send(:target_program_semester_id_for_rating, rating.new(student, "Communication", nil))

    aggregator.stub(:target_program_semester_id_for_rating, semester_id) do
      aggregator.stub(:course_target_level_from_dataset, 4) do
        aggregator.stub(:fallback_course_target_level, 2) do
          assert_equal 4, aggregator.send(:course_target_level_for_rating, rating.new(student, "Communication Reflection", nil))
        end
      end
    end

    aggregator.stub(:target_program_semester_id_for_rating, semester_id) do
      aggregator.stub(:course_target_level_from_dataset, nil) do
        aggregator.stub(:fallback_course_target_level, 2) do
          assert_equal 2, aggregator.send(:course_target_level_for_rating, rating.new(student, "Communication", nil))
        end
      end
    end
  end

  test "raw export helpers cover optional association fallbacks" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    student_user = Struct.new(:display_name).new("Lookup Student")
    student = Struct.new(:student_id, :user, :full_name, :email, :uin, :track, :program_year, :advisor)
                    .new(123, student_user, "Fallback Student", "lookup@example.edu", "123456789", "Residential", 2026, nil)
    advisor = Struct.new(:display_name).new("Lookup Advisor")
    rows = [
      {
        student_id: 123,
        advisor_entry: false,
        advisor_id: 77,
        rating_advisor_id: nil,
        survey_id: 1,
        survey_title: "Survey",
        survey_semester: "Fall 2025",
        category_name: "Domain",
        question_text: "Communication Reflection",
        score: 4.0,
        program_target_level: 3,
        updated_at: Time.current
      },
      {
        student_id: 999,
        advisor_entry: true,
        advisor_id: nil,
        rating_advisor_id: 88,
        survey_id: 2,
        survey_title: "Advisor Survey",
        survey_semester: nil,
        category_name: "Domain",
        question_text: "Policy Analysis",
        score: 5.0,
        program_target_level: nil,
        updated_at: Time.current
      }
    ]

    aggregator.stub(:dataset_rows, rows) do
      aggregator.stub(:student_export_lookup, { 123 => student }) do
        aggregator.stub(:advisor_export_lookup, { 77 => advisor, 88 => advisor }) do
          student_rows = aggregator.send(:raw_rating_rows, advisor_entry: false)
          advisor_rows = aggregator.send(:raw_rating_rows, advisor_entry: true)

          assert_equal "Lookup Student", student_rows.first[:student_name]
          assert_equal "Lookup Advisor", student_rows.first[:advisor]
          assert_nil advisor_rows.first[:student_name]
          assert_equal "Lookup Advisor", advisor_rows.first[:advisor]
          assert_equal "Communication", student_rows.first[:competency]
        end
      end
    end

    semester = Struct.new(:name).new("Spring 2026")
    batch = Struct.new(:program_semester).new(semester)
    file = Struct.new(:file_name).new("source.csv")
    evidence = Struct.new(
      :student,
      :grade_import_batch,
      :grade_import_file,
      :course_code,
      :competency_title,
      :assignment_name,
      :raw_grade,
      :mapped_level,
      :course_target_level,
      :created_at,
      :updated_at
    )
    scope = chainable_records([
      evidence.new(student, batch, file, "PHPM-601", "Communication", "Assignment", 95, 4, 3, Time.current, Time.current),
      evidence.new(nil, nil, nil, nil, "Policy Analysis", nil, nil, 2, nil, Time.current, Time.current)
    ])

    aggregator.stub(:reportable_course_evidence_scope, scope) do
      course_rows = aggregator.send(:raw_course_evidence_rows)

      assert_equal "Spring 2026", course_rows.first[:semester]
      assert_equal "source.csv", course_rows.first[:source_file]
      assert_nil course_rows.second[:semester]
      assert_nil course_rows.second[:source_file]
    end

    survey = Struct.new(:id, :title, :program_semester).new(42, "Employment Survey", semester)
    category = Struct.new(:survey).new(survey)
    question = Struct.new(:category, :question_text).new(category, "Are you currently employed?")
    employment_record = Struct.new(:student, :question, :response_value, :updated_at)
    employment_scope = chainable_records([
      employment_record.new(student, question, { answer: "Yes" }.to_json, Time.current),
      employment_record.new(nil, nil, "No", Time.current)
    ])

    aggregator.stub(:employment_response_scope, employment_scope) do
      employment_rows = aggregator.send(:raw_employment_response_rows)

      assert_equal 42, employment_rows.first[:survey_id]
      assert_equal "Employment Survey", employment_rows.first[:survey]
      assert_equal "Spring 2026", employment_rows.first[:semester]
      assert_equal "Are you currently employed?", employment_rows.first[:question]
      assert_nil employment_rows.second[:survey_id]
      assert_nil employment_rows.second[:question]
    end
  end

  test "filters and scoped relations cover valid invalid and memoized branches" do
    valid_competency = Reports::DataAggregator.new(user: @admin, params: { competency: "Communication" })
    assert_equal "communication", valid_competency.send(:filters)[:competency]

    invalid_filters = Reports::DataAggregator.new(
      user: @admin,
      params: {
        track: "Residential",
        program_year: "not a year",
        semester: "Spring 2026",
        survey_id: surveys(:fall_2025).id.to_s,
        student_id: "999999",
        advisor_id: "999999",
        competency: "Not a competency"
      }
    ).send(:filters)

    assert_equal "Residential", invalid_filters[:track]
    assert_equal "Spring 2026", invalid_filters[:semester]
    assert_equal surveys(:fall_2025).id, invalid_filters[:survey_id]
    assert_nil invalid_filters[:program_year]
    assert_nil invalid_filters[:student_id]
    assert_nil invalid_filters[:advisor_id]
    assert_nil invalid_filters[:competency]

    scoped = Reports::DataAggregator.new(
      user: @admin,
      params: {
        track: students(:student).track,
        program_year: students(:student).program_year.to_s,
        advisor_id: students(:student).advisor_id.to_s,
        student_id: students(:student).student_id.to_s
      }
    )
    first_relation = scoped.send(:scoped_student_relation)
    assert_same first_relation, scoped.send(:scoped_student_relation)

    assert_empty Reports::DataAggregator.new(user: nil, params: {}).send(:accessible_advisor_ids)
  end

  test "dataset and response-pair builders cover skipped rows" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    row = Struct.new(
      :response_value,
      :student_question_id,
      :updated_at,
      :category_id,
      :category_name,
      :question_text,
      :program_target_level,
      :survey_id,
      :survey_title,
      :program_semester_id,
      :survey_semester,
      :student_track,
      :student_primary_id,
      :owning_advisor_id,
      :advisor_id
    )
    records = [
      row.new("4", 1, Time.current, 1, "Domain", "Communication", 3, 10, "Survey", nil, "Fall 2025", "Residential", 1, nil, nil),
      row.new("not numeric", 2, Time.current, 1, "Domain", "Communication", 3, 10, "Survey", nil, "Fall 2025", "Residential", 2, nil, nil),
      row.new("5", 3, Time.current, 1, "Domain", "Policy Analysis", 3, 11, "Survey", nil, "Fall 2025", "Residential", 3, nil, 22)
    ]
    assignment_check = ->(student_id, _survey_id) { student_id != 1 }

    aggregator.stub(:filtered_scope, finder_records(records)) do
      aggregator.stub(:filtered_feedback_scope, finder_records(records)) do
        aggregator.stub(:assignment_completed?, assignment_check) do
          result = aggregator.send(:dataset_rows)

          assert_equal 2, result.size
          assert_equal [ 3, 3 ], result.map { |entry| entry[:student_id] }
          assert_equal [ false, true ], result.map { |entry| entry[:advisor_entry] }
        end
      end
    end

    pair_scope = Struct.new(:pairs) do
      def distinct = self
      def pluck(*_columns) = pairs
    end
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    aggregator.stub(:filtered_scope, pair_scope.new([ [ nil, 1 ], [ 1, nil ], [ 1, 2 ], [ 2, 3 ] ])) do
      aggregator.stub(:assignment_completed?, ->(student_id, _survey_id) { student_id == 1 }) do
        pairs = aggregator.send(:student_survey_response_pairs)

        assert_equal true, pairs[[ 1, 2 ]]
        assert_nil pairs[[ 2, 3 ]]
      end
    end
  end

  test "course rating rows skip missing targets and include student metadata when present" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    student = Struct.new(:student_id, :track, :program_year, :advisor_id).new(123, "Residential", 2026, 77)
    rating = Struct.new(:student_id, :student, :competency_title, :aggregated_level, :updated_at, :grade_import_batch)
    ratings = [
      rating.new(123, student, "Communication", 4, Time.current, nil),
      rating.new(456, nil, "Policy Analysis", 2, Time.current, nil)
    ]

    target_lookup = ->(row) { row.student ? 3 : nil }
    aggregator.stub(:reportable_course_rating_scope, ratings) do
      aggregator.stub(:course_target_level_for_rating, target_lookup) do
        aggregator.stub(:competency_detail_domain_lookup, { "communication" => "Leadership Skills" }) do
          rows = aggregator.send(:course_rating_rows)

          assert_equal 1, rows.size
          assert_equal 123, rows.first[:student_id]
          assert_equal "Residential", rows.first[:track]
          assert_equal 2026, rows.first[:class_of]
          assert_equal 77, rows.first[:advisor_id]
          assert_equal "Leadership Skills", rows.first[:category_name]
        end
      end
    end
  end

  test "scopes apply year advisor domain competency semester and student filters" do
    category = categories(:clinical_skills)
    student = students(:student)
    params = {
      track: student.track,
      program_year: student.program_year.to_s,
      advisor_id: student.advisor_id.to_s,
      student_id: student.student_id.to_s,
      semester: program_semesters(:fall_2025).name,
      survey_id: surveys(:fall_2025).id.to_s,
      competency: "Communication"
    }
    aggregator = Reports::DataAggregator.new(user: @admin, params: params)

    assert_nothing_raised { aggregator.send(:reportable_course_evidence_scope).to_a }
    assert_nothing_raised { aggregator.send(:employment_response_scope).to_a }
    assert_nothing_raised { aggregator.send(:filtered_scope).limit(1).to_a }
    assert_nothing_raised { aggregator.send(:filtered_feedback_scope).limit(1).to_a }

    domain_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    domain_aggregator.stub(:filters, { category_id: "clinical_skills" }) do
      domain_aggregator.stub(:selected_category_ids, [ category.id ]) do
        assert_nothing_raised { domain_aggregator.send(:filtered_scope).limit(1).to_a }
        assert_nothing_raised { domain_aggregator.send(:filtered_feedback_scope).limit(1).to_a }
      end
    end

    unresolved_competency = Reports::DataAggregator.new(user: @admin, params: {})
    unresolved_competency.stub(:filters, { competency: "missing" }) do
      unresolved_competency.stub(:competency_lookup, {}) do
        assert_nothing_raised { unresolved_competency.send(:reportable_course_evidence_scope).to_a }
        assert_nothing_raised { unresolved_competency.send(:reportable_course_rating_scope) }
      end
    end
  end

  test "memoized summary helpers and empty detail buckets cover nil paths" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    empty_assignments = SurveyAssignment.none

    aggregator.stub(:scoped_assignment_scope, empty_assignments) do
      aggregator.stub(:scoped_student_ids, [ 1, 2 ]) do
        first = aggregator.send(:completion_stats)
        assert_same first, aggregator.send(:completion_stats)
        assert_equal 2, first[:total_assignments]
      end
    end

    track_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    ProgramTrack.stub(:data_source_ready?, false) do
      ProgramTrack.stub(:names, [ "Residential", "Executive" ]) do
        first = track_aggregator.send(:program_track_names)
        assert_same first, track_aggregator.send(:program_track_names)
      end
    end

    detail_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    detail_aggregator.stub(:dataset_rows, []) do
      detail_aggregator.stub(:assigned_student_ids_in_scope, []) do
        detail_aggregator.stub(:available_categories, [ { id: "leadership_skills", name: "Leadership Skills" } ]) do
          detail_aggregator.stub(:course_competency_average_lookup, {}) do
            detail_aggregator.stub(:course_competency_target_percent_lookup, {}) do
              detail = detail_aggregator.send(:build_competency_detail)
              first_item = detail[:items].first

              assert_nil first_item[:domain_id]
              assert_nil first_item[:domain_name]
              assert_nil first_item[:student_average]
            end
          end
        end
      end
    end
  end

  test "course competency and domain lookups skip nil averages and blank slugs" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    rating = Struct.new(:competency_title, :aggregated_level)
    ratings = [
      rating.new("Communication", 4),
      rating.new("Communication", nil),
      rating.new("Policy Analysis", 2)
    ]

    aggregator.stub(:reportable_course_rating_scope, ratings) do
      averages = aggregator.send(:course_competency_average_lookup)

      assert_equal 4, averages["Communication"]
      assert_equal 2, averages["Policy Analysis"]
    end

    domain_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    domain_aggregator.stub(:course_competency_average_lookup, {
      "Communication" => 4,
      "Policy Analysis" => nil,
      "Mystery" => 3
    }) do
      domain_aggregator.stub(:domain_slug_for_competency, ->(title) { title == "Mystery" ? nil : "leadership_skills" }) do
        assert_equal({ "leadership_skills" => 4.0 }, domain_aggregator.send(:course_domain_average_lookup))
      end
    end

    target_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    target_rows = [
      { question_text: "Communication", student_id: 1, score: 4, program_target_level: 3 },
      { question_text: "Mystery", student_id: 1, score: 4, program_target_level: 3 }
    ]
    target_aggregator.stub(:course_rating_rows, target_rows) do
      target_aggregator.stub(:domain_slug_for_competency, ->(title) { title == "Mystery" ? nil : "leadership_skills" }) do
        target_aggregator.stub(:target_percent_for_rows, 100.0) do
          assert_equal({ "leadership_skills" => 100.0 }, target_aggregator.send(:course_domain_target_percent_lookup))
        end
      end
    end
  end

  test "category grouping and competency detail lookup skip malformed rows" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    fake_scope = Struct.new(:rows) do
      def distinct = self
      def pluck(*_args) = rows
    end

    aggregator.stub(:base_scope, fake_scope.new([ [ nil, "Domain" ], [ 10, "" ], [ 11, "Leadership Skills" ] ])) do
      lookup = aggregator.send(:category_group_lookup)

      assert_equal [ 11 ], lookup["leadership_skills"][:ids]
      assert_equal({ 11 => "leadership_skills" }, aggregator.send(:category_id_to_slug))
    end

    detail_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    rows = [
      { question_text: nil, category_name: "Leadership Skills" },
      { question_text: "Communication", category_name: "" },
      { question_text: "Communication", category_name: "Leadership Skills" }
    ]

    detail_aggregator.stub(:dataset_rows, rows) do
      assert_equal({ "communication" => "Leadership Skills" }, detail_aggregator.send(:competency_detail_domain_lookup))
    end
  end

  test "target record lookup ordering covers class and year any fallbacks" do
    semester_id = program_semesters(:fall_2025).id
    row = Struct.new(:id, :program_semester_id, :track, :program_year, :class_of, :competency_title, :target_level)
    rows = [
      row.new(1, semester_id, "Residential", 2027, 2027, "Communication", 5),
      row.new(2, semester_id, "Residential", 2026, 2026, "Communication", 4),
      row.new(3, semester_id, "Residential", nil, nil, "Communication", 3)
    ]
    relation = Struct.new(:rows) do
      def to_a = rows
      def find_each(&block) = rows.each(&block)
    end

    records_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    CompetencyTargetLevel.stub(:select, relation.new(rows)) do
      key = [ semester_id, "residential", "Communication" ]
      records = records_aggregator.send(:competency_target_records_by_semester_track_and_title)[key]

      assert_equal [ 2027, 2026, nil ], records.map(&:class_of)
    end

    bundle_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    CompetencyTargetLevel.stub(:select, relation.new(rows)) do
      bundle = bundle_aggregator.send(:competency_target_level_lookup_bundle)
      any_key = [ semester_id, "residential", "Communication" ]

      assert_equal 4, bundle[:class_of_any][any_key]
      assert_equal 4, bundle[:program_year_any_year][any_key]
      assert_equal 3, bundle[:class_of_exact][[ semester_id, "residential", nil, "Communication" ]]
    end
  end

  test "scoped assignments honor advisor filter and completed pairs skip blank keys" do
    student = students(:student)
    aggregator = Reports::DataAggregator.new(user: @admin, params: { advisor_id: student.advisor_id.to_s })

    assert_nothing_raised { aggregator.send(:scoped_assignment_scope).limit(1).to_a }

    pair_scope = Struct.new(:pairs) do
      def where(*_args) = self
      def not(*_args) = self
      def pluck(*_args) = pairs
    end
    pair_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
    pair_aggregator.stub(:scoped_assignment_scope, pair_scope.new([ [ nil, 1 ], [ 1, nil ], [ 1, 2 ] ])) do
      assert_equal({ [ 1, 2 ] => true }, pair_aggregator.send(:completed_assignment_pairs))
    end
  end

  test "reportable course rating scope applies semester track year advisor student competency and category filters" do
    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )
    other_batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: program_semesters(:spring_2026),
      status: "completed",
      summary: { "dry_run" => false }
    )
    communication = batch.grade_competency_ratings.create!(
      student: students(:student),
      competency_title: "Communication",
      aggregated_level: 4,
      aggregation_rule: "max",
      evidence_count: 1
    )
    policy = batch.grade_competency_ratings.create!(
      student: students(:other_student),
      competency_title: "Policy Analysis",
      aggregated_level: 3,
      aggregation_rule: "max",
      evidence_count: 1
    )
    other_batch.grade_competency_ratings.create!(
      student: students(:student),
      competency_title: "Communication",
      aggregated_level: 2,
      aggregation_rule: "max",
      evidence_count: 1
    )

    filtered = Reports::DataAggregator.new(
      user: @admin,
      params: {
        track: students(:student).track,
        program_year: students(:student).program_year.to_s,
        advisor_id: students(:student).advisor_id.to_s,
        student_id: students(:student).student_id.to_s,
        semester: program_semesters(:fall_2025).name,
        competency: "communication"
      }
    ).send(:reportable_course_rating_scope)

    assert_equal [ communication.id ], filtered.map(&:id)

    missing_semester = Reports::DataAggregator.new(user: @admin, params: { semester: "Missing 2099" })
    assert_empty missing_semester.send(:reportable_course_rating_scope)

    category_filtered = Reports::DataAggregator.new(user: @admin, params: { category_id: "leadership_skills" })
    category_filtered.stub(:category_group_lookup, { "leadership_skills" => { name: "Leadership Skills", ids: [ 1 ] } }) do
      category_filtered.stub(:competency_titles_for_domain_filter, [ "Communication" ]) do
        category_ids = category_filtered.send(:reportable_course_rating_scope).map(&:id)
        assert_includes category_ids, communication.id
        refute_includes category_ids, policy.id
      end
    end
  end

  test "course target and export helper branches cover blank selected semester and missing lookup labels" do
    aggregator = Reports::DataAggregator.new(user: @admin, params: {})

    assert_nil aggregator.send(:selected_report_program_semester)
    assert_nil aggregator.send(:course_target_level_from_dataset, student_id: students(:student).student_id, competency_title: "Communication", program_semester_id: nil)
    assert_equal "Communication", aggregator.send(:normalized_competency_title, "Communication Reflection")
    assert_equal "", aggregator.send(:normalized_competency_title, " ")
    assert_nil aggregator.send(:normalize_competency_slug, " ")
    assert_equal "communication", aggregator.send(:normalize_competency_slug, "Communication Reflection")

    aggregator.stub(:available_advisors, []) do
      aggregator.stub(:available_categories, []) do
        aggregator.stub(:available_surveys, []) do
          aggregator.stub(:available_students, []) do
            aggregator.stub(:available_competencies, []) do
              aggregator.stub(:filters, { advisor_id: 999, category_id: "missing", competency: "missing", student_id: 888, survey_id: 777 }) do
                filters = aggregator.send(:export_filters)

                assert_nil filters[:advisor]
                assert_nil filters[:domain]
                assert_nil filters[:competency]
                assert_nil filters[:student]
                assert_nil filters[:survey]
              end
            end
          end
        end
      end
    end
  end

  private

  def chainable_records(records)
    Struct.new(:records) do
      def includes(*_args) = self
      def order(*_args) = self
      def map(&block) = records.map(&block)
    end.new(records)
  end

  def finder_records(records)
    Struct.new(:records) do
      def select(*_args) = self
      def find_each(batch_size: nil)
        records.each { |record| yield record }
      end
    end.new(records)
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
