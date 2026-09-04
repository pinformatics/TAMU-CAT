require "test_helper"

module SurveyResponses
  class SelfTargetSummaryTest < ActiveSupport::TestCase
    setup do
      @student = students(:student)
      @survey = Survey.create!(
        title: "Summary Coverage Survey",
        semester: "Spring 2026",
        is_active: true,
        categories_attributes: [
          {
            name: "Leadership Skills",
            description: "Domain",
            questions_attributes: [
              {
                question_text: "Communication",
                question_order: 1,
                question_type: "dropdown",
                is_required: true
              },
              {
                question_text: "Policy Analysis",
                question_order: 2,
                question_type: "dropdown",
                is_required: true
              },
              {
                question_text: "Not a competency",
                question_order: 3,
                question_type: "dropdown",
                is_required: false
              },
              {
                question_text: "Communication Reflection",
                question_order: 4,
                question_type: "short_answer",
                is_required: false
              }
            ]
          }
        ]
      )
      @category = @survey.categories.first
      @communication = @category.questions.find_by!(question_text: "Communication")
      @policy = @category.questions.find_by!(question_text: "Policy Analysis")
      @unknown = @category.questions.find_by!(question_text: "Not a competency")
      @reflection = @category.questions.find_by!(question_text: "Communication Reflection")
    end

    test "build handles missing survey response and summarizes met below and missing states" do
      empty = SelfTargetSummary.build(survey_response: nil)
      assert_empty empty[:rows]
      assert_nil empty[:met_rate]

      survey_response = SurveyResponse.build(
        student: @student,
        survey: @survey,
        answers_override: {
          @communication.id => "5 - Strong",
          @policy.id => "2",
          @unknown.id => "0"
        }
      )
      service = SelfTargetSummary.new(survey_response:)
      target_lookup = ->(question:, survey:, student:) do
        assert_equal @survey, survey
        assert_equal @student, student
        question.id == @communication.id ? 4 : 3
      end

      service.stub(:effective_competency_target_level, target_lookup) do
        summary = service.build

        assert_equal 2, summary[:total_count]
        assert_equal 2, summary[:comparable_count]
        assert_equal 1, summary[:met_count]
        assert_equal 1, summary[:below_count]
        assert_equal 50.0, summary[:met_rate]
        assert_equal [ "Communication", "Policy Analysis" ], summary[:rows].map { |row| row[:competency] }
      end
    end

    test "classifies zero self-ratings as not assessable" do
      survey_response = SurveyResponse.build(
        student: @student,
        survey: @survey,
        answers_override: { @communication.id => "0" }
      )
      service = SelfTargetSummary.new(survey_response:)

      service.stub(:effective_competency_target_level, 3) do
        summary = service.build

        assert_equal :not_assessable, summary[:rows].first[:status]
        assert_equal "Not able to assess", summary[:rows].first[:status_label]
        assert_equal 0, summary[:comparable_count]
        assert_equal 0, summary[:met_count]
        assert_equal 0, summary[:below_count]
        assert_equal 1, summary[:not_assessable_count]
      end
    end

    test "private helpers cover title rating level and label fallbacks" do
      service = SelfTargetSummary.new(survey_response: SurveyResponse.build(student: @student, survey: @survey))

      assert_nil service.send(:competency_title_for, nil)
      blank_question = Struct.new(:question_text).new(" ")
      assert_nil service.send(:competency_title_for, blank_question)
      assert_equal "Communication", service.send(:competency_title_for, @communication)
      assert_nil service.send(:competency_title_for, @unknown)

      assert_nil service.send(:normalized_self_rating, nil)
      assert_nil service.send(:normalized_self_rating, "")
      assert_equal 5, service.send(:normalized_self_rating, "5.0")
      assert_equal 4, service.send(:normalized_self_rating, "Strong (4)")
      assert_equal 3, service.send(:normalized_self_rating, "Level 3 - developing")
      assert_equal 0, service.send(:normalized_self_rating, "Not able to assess (0)")
      assert_nil service.send(:normalized_self_rating, "No rating")

      assert_nil service.send(:normalized_level, nil)
      assert_nil service.send(:normalized_level, "0")
      assert_nil service.send(:normalized_level, "6")
      assert_nil service.send(:normalized_level, "bad")
      assert_equal 3, service.send(:normalized_level, "3.7")

      assert_equal :no_target, service.send(:target_status, 4, nil)
      assert_equal :not_rated, service.send(:target_status, nil, 3)
      assert_equal :not_assessable, service.send(:target_status, 0, 3)
      assert_equal :not_assessable, service.send(:target_status, 0, nil)
      assert_equal :met, service.send(:target_status, 4, 3)
      assert_equal :below_target, service.send(:target_status, 2, 3)
      assert_equal "Target not set", service.send(:target_status_label, 4, nil)
      assert_equal "No self-rating", service.send(:target_status_label, nil, 3)
      assert_equal "Not able to assess", service.send(:target_status_label, 0, 3)
    end

    test "summary rows use unassigned domain fallback for detached category data" do
      survey_response = SurveyResponse.build(student: @student, survey: @survey, answers_override: { 99 => "4" })
      service = SelfTargetSummary.new(survey_response:)
      fake_question = Struct.new(:id, :question_text, :category) do
        def question_type_dropdown? = true
      end.new(99, "Communication", nil)

      service.stub(:competency_questions, [ fake_question ]) do
        service.stub(:effective_competency_target_level, 4) do
          row = service.send(:summary_rows).first

          assert_equal "Unassigned domain", row[:domain]
          assert_equal :met, row[:status]
        end
      end
    end

    test "completed version events are explicit" do
      assert SelfTargetSummary.completed_version_event?("submitted")
      assert SelfTargetSummary.completed_version_event?(:revised)
      refute SelfTargetSummary.completed_version_event?("autosaved")
      refute SelfTargetSummary.completed_version_event?(nil)
    end
  end
end
