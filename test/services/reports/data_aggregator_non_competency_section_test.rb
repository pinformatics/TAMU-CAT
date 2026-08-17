require "test_helper"
require "securerandom"

module Reports
  # Regression coverage for a real bug: StudentQuestion answers from
  # non-competency sections (e.g. "Professional Snapshot" -- employment
  # questions like "how many hours per week do you work", answered as a
  # plain integer) were being parsed as 1-5 competency scores and inflating
  # averages past the real scale, most visibly in the Monthly Trend chart.
  class DataAggregatorNonCompetencySectionTest < ActiveSupport::TestCase
    setup do
      @admin = users(:admin)
      @student = students(:student)
      @student.update!(program_year: 2026) if @student.program_year.blank?

      @competency_name = Reports::DataAggregator::COMPETENCY_TITLES.first
      @domain_name = Reports::DataAggregator::REPORT_DOMAINS.first

      @survey = Survey.create!(
        title: "Section Scope Survey #{SecureRandom.hex(4)}",
        semester: "Fall 2025",
        categories_attributes: [
          {
            name: "Placeholder",
            description: "Placeholder category so the survey passes creation validation",
            questions_attributes: [
              { question_text: "Placeholder question", question_order: 1, question_type: "short_answer", is_required: true, has_evidence_field: false }
            ]
          }
        ]
      )
      ensure_completed_assignment(student: @student, survey: @survey)
    end

    test "excludes answers from known non-competency sections (e.g. employment hours worked)" do
      competency_question = create_question(section_title: SurveySection::MHA_COMPETENCY_SECTION_TITLE, question_text: @competency_name)
      employment_question = create_question(section_title: "Professional Snapshot", question_text: "How many hours per week do you work?")

      StudentQuestion.create!(student_id: @student.student_id, question: competency_question, response_value: "4")
      StudentQuestion.create!(student_id: @student.student_id, question: employment_question, response_value: "40")

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      rows = aggregator.send(:dataset_rows).reject { |row| row[:advisor_entry] }

      assert rows.none? { |row| row[:score].to_f > 5 }, "Expected no dataset row to exceed the 1-5 competency scale"
      assert rows.none? { |row| row[:category_name] == "Professional Snapshot" }

      item = aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }
      assert item
      assert_in_delta 4.0, item[:student_average], 0.001
    end

    test "categories with no section at all are still included (not a competency-section signal)" do
      question = create_question(section_title: nil, question_text: @competency_name)
      StudentQuestion.create!(student_id: @student.student_id, question: question, response_value: "3")

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      item = aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }

      assert item
      assert_in_delta 3.0, item[:student_average], 0.001
    end

    private

    def create_question(section_title:, question_text:)
      section = if section_title
        @survey.sections.create!(title: section_title, description: "Test section")
      end

      category = @survey.categories.create!(name: @domain_name, description: "Test domain", section: section)
      category.questions.create!(
        question_text: question_text,
        question_order: category.questions.count + 1,
        question_type: "short_answer",
        is_required: true,
        has_evidence_field: false
      )
    end

    def ensure_completed_assignment(student:, survey:)
      assignment = SurveyAssignment.find_or_initialize_by(survey: survey, student: student)
      assignment.advisor_id ||= student.advisor&.advisor_id
      assignment.assigned_at ||= Time.current - 2.weeks
      assignment.save!
      assignment.update!(completed_at: assignment.completed_at || Time.current - 1.week)
    end
  end
end
