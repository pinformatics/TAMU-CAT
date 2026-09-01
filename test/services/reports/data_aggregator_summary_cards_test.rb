# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Reports
  class DataAggregatorSummaryCardsTest < ActiveSupport::TestCase
    setup do
      @admin = users(:admin)
      @student = students(:student)
      @other_student = students(:other_student)
    end

    test "completion rate is zero when assignments missing" do
      SurveyAssignment.delete_all
      StudentQuestion.delete_all

      question = create_numeric_question("Completion Metric Question")
      StudentQuestion.create!(
        student_id: @student.student_id,
        question: question,
        response_value: "4.0"
      )

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      completion_card = aggregator.benchmark[:cards].find { |card| card[:key] == "completion_rate" }

      refute_nil completion_card, "Expected completion card to be present"
      assert_in_delta 0.0, completion_card[:value], 0.01
      assert_equal aggregator.send(:scoped_student_ids).size, completion_card[:sample_size]
    end

    test "completion rate counts only completed assignments" do
      SurveyAssignment.delete_all
      StudentQuestion.delete_all

      question = create_numeric_question("Completion Metric Question")
      assignment = create_assignment(student: @student, survey: question.category.survey, completed: false)

      StudentQuestion.create!(
        student_id: @student.student_id,
        question: question,
        response_value: "4.0"
      )

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      completion_card = aggregator.benchmark[:cards].find { |card| card[:key] == "completion_rate" }

      refute_nil completion_card, "Expected completion card to be present"
      assert_in_delta 0.0, completion_card[:value], 0.01
      assert_equal 1, completion_card[:sample_size]

      assignment.update!(completed_at: Time.current)

      refreshed = Reports::DataAggregator.new(user: @admin, params: {})
      completion_card_after = refreshed.benchmark[:cards].find { |card| card[:key] == "completion_rate" }

      refute_nil completion_card_after
      assert_in_delta 100.0, completion_card_after[:value], 0.01
      assert_equal 1, completion_card_after[:sample_size]
    end

    test "completion rate aggregates across multiple students" do
      SurveyAssignment.delete_all
      StudentQuestion.delete_all

      question = create_numeric_question("Completion Metric Question")

      create_assignment(student: @student, survey: question.category.survey, completed: true)
      create_assignment(student: @other_student, survey: question.category.survey, completed: false)

      [ @student, @other_student ].each do |student|
        StudentQuestion.create!(
          student_id: student.student_id,
          question: question,
          response_value: "4.0"
        )
      end

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      completion_card = aggregator.benchmark[:cards].find { |card| card[:key] == "completion_rate" }

      refute_nil completion_card, "Expected completion card to be present"
      assert_in_delta 50.0, completion_card[:value], 0.01
      assert_equal 2, completion_card[:sample_size]

      SurveyAssignment.where(student_id: @other_student.student_id, survey_id: question.category.survey.id)
                      .update_all(completed_at: Time.current)

      refreshed = Reports::DataAggregator.new(user: @admin, params: {})
      completion_card_after = refreshed.benchmark[:cards].find { |card| card[:key] == "completion_rate" }

      assert_in_delta 100.0, completion_card_after[:value], 0.01
      assert_equal 2, completion_card_after[:sample_size]
    end

    test "includes benchmark attainment cards" do
      SurveyAssignment.delete_all
      StudentQuestion.delete_all
      Feedback.delete_all

      question = create_numeric_question("Advisor Average Question")
      create_assignment(student: @student, survey: question.category.survey, completed: true)

      StudentQuestion.create!(
        student_id: @student.student_id,
        question: question,
        response_value: "4.0"
      )

      Feedback.create!(
        student: @student,
        survey: question.category.survey,
        category: question.category,
        question: question,
        average_score: 3.0,
        advisor: advisors(:advisor)
      )

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})

      attainment_card = aggregator.benchmark[:cards].find { |card| card[:key] == "benchmark_attainment_overall" }
      refute_nil attainment_card, "Expected benchmark attainment card to be present"
      assert_in_delta 0.0, attainment_card[:value], 0.01
      assert_equal 1, attainment_card[:sample_size]

      below_card = aggregator.benchmark[:cards].find { |card| card[:key] == "benchmark_not_meeting_overall" }
      refute_nil below_card, "Expected below benchmark card to be present"
      assert_in_delta 100.0, below_card[:value], 0.01
      assert_equal 1, below_card[:sample_size]
    end

    test "benchmark track summary combines track details" do
      SurveyAssignment.delete_all
      StudentQuestion.delete_all
      Feedback.delete_all

      question = create_numeric_question("Combined Benchmark Summary")
      create_assignment(student: @student, survey: question.category.survey, completed: true)
      create_assignment(student: @other_student, survey: question.category.survey, completed: true)

      StudentQuestion.create!(
        student_id: @student.student_id,
        question: question,
        response_value: "4.5"
      )

      StudentQuestion.create!(
        student_id: @other_student.student_id,
        question: question,
        response_value: "2.5"
      )

      Feedback.create!(
        student: @student,
        survey: question.category.survey,
        category: question.category,
        question: question,
        average_score: 4.0,
        advisor: advisors(:advisor)
      )

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      track_card = aggregator.benchmark[:cards].find { |card| card[:key] == "benchmark_attainment_by_track" }

      refute_nil track_card, "Expected combined benchmark track card"
      assert_equal 2, Array(track_card.dig(:meta, :tracks)).size

      residential = track_card[:meta][:tracks].find { |entry| entry[:label] == "Residential, Class of 2026" }
      executive = track_card[:meta][:tracks].find { |entry| entry[:label] == "Executive, Class of 2027" }

      refute_nil residential, "Expected Residential track entry"
      refute_nil executive, "Expected Executive track entry"

      assert_equal "Advisor ratings", residential[:source_label]
      assert_equal "Student self-ratings", executive[:source_label]

      assert_in_delta 100.0, residential[:percent], 0.01
      assert_in_delta 0.0, executive[:percent], 0.01
      assert_equal 1, residential[:competencies_met_goal]
      assert_equal 0, executive[:competencies_met_goal]
      assert_equal 2, track_card[:sample_size]
    end

    test "includes student advisor alignment card when both ratings present" do
      SurveyAssignment.delete_all
      StudentQuestion.delete_all
      Feedback.delete_all

      question = create_numeric_question("Alignment Metric Question")
      create_assignment(student: @student, survey: question.category.survey, completed: true)

      StudentQuestion.create!(
        student_id: @student.student_id,
        question: question,
        response_value: "4.0"
      )

      Feedback.create!(
        student: @student,
        survey: question.category.survey,
        category: question.category,
        question: question,
        average_score: 4.0,
        advisor: advisors(:advisor)
      )

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      alignment_card = aggregator.benchmark[:cards].find { |card| card[:key] == "student_advisor_alignment" }

      refute_nil alignment_card, "Expected alignment card to be present"
      assert_in_delta 100.0, alignment_card[:value], 0.01
      assert_equal 1, alignment_card[:sample_size]
      assert_equal "Advisor & student ratings", alignment_card.dig(:meta, :name)
    end

    test "advisor alignment uses 1-5 max gap" do
      aggregator = Reports::DataAggregator.new(user: @admin, params: {})

      assert_in_delta 100.0, aggregator.send(:alignment_percent, 4.0, 4.0), 0.001
      assert_in_delta 0.0, aggregator.send(:alignment_percent, 1.0, 5.0), 0.001
      assert_in_delta 75.0, aggregator.send(:alignment_percent, 4.0, 3.0), 0.001
    end

    private

    def create_assignment(student:, survey:, completed: true)
      SurveyAssignment.create!(
        survey: survey,
        student: student,
        advisor_id: student.advisor&.advisor_id,
        assigned_at: Time.current - 1.week,
        completed_at: completed ? (Time.current - 1.day) : nil
      )
    end

    def create_numeric_question(question_text)
      survey = Survey.create!(
        title: "Completion Metric Survey #{SecureRandom.hex(4)}",
        semester: "Fall 2025",
        categories_attributes: [
          {
            name: Reports::DataAggregator::REPORT_DOMAINS.first,
            description: "Test domain",
            questions_attributes: [
              {
                question_text: question_text,
                question_order: 1,
                question_type: "short_answer",
                is_required: true,
                has_evidence_field: false
              }
            ]
          }
        ]
      )

      survey.questions.first
    end
  end
end
