require "test_helper"

module Surveys
  class CopyToSemesterTest < ActiveSupport::TestCase
    setup do
      @admin = users(:admin)
      @source_semester = program_semesters(:fall_2025)
      @target_semester = ProgramSemester.create!(name: "Coverage Copy #{SecureRandom.hex(4)}")
      @source = Survey.new(
        title: "Copy Source #{SecureRandom.hex(4)}",
        program_semester: @source_semester,
        creator: @admin,
        is_active: true,
        show_course_competencies_with_survey: true,
        advisor_numeric_feedback_enabled: false
      )
      @source.save!(validate: false)
      @section = @source.sections.create!(title: SurveySection::MHA_COMPETENCY_SECTION_TITLE, position: 1)
      @category = @source.categories.create!(name: "Copy Category", section: @section)
      @parent = @category.questions.create!(
        question_text: "Are you currently employed?",
        question_type: "multiple_choice",
        question_order: 1,
        answer_options: %w[Yes No].to_json,
        is_required: true
      )
      @child = @category.questions.create!(
        question_text: "If yes, where are you employed?",
        question_type: "short_answer",
        question_order: 1,
        parent_question: @parent,
        sub_question_order: 1,
        is_required: true
      )
      @source.create_legend!(body: "Copy legend")
      @source.assign_tracks!([ "Residential" ])
      @source.offerings.create!(
        track: "Residential",
        class_of: 2026,
        stage: "midpoint",
        active: true,
        available_from: 1.day.ago,
        available_until: 1.month.from_now
      )
    end

    test "raises clear errors for missing same or duplicate target semester" do
      assert_raises(CopyToSemester::Error) do
        CopyToSemester.call(source_survey: @source, target_semester: nil, actor: @admin)
      end

      assert_raises(CopyToSemester::Error) do
        CopyToSemester.call(source_survey: @source, target_semester: @source_semester, actor: @admin)
      end

      Survey.create!(
        title: @source.title,
        program_semester: @target_semester,
        creator: @admin,
        is_active: true,
        categories_attributes: [
          {
            name: "Existing",
            questions_attributes: [
              { question_text: "Existing question", question_type: "short_answer", question_order: 1 }
            ]
          }
        ]
      )

      error = assert_raises(CopyToSemester::Error) do
        CopyToSemester.call(source_survey: @source, target_semester: @target_semester, actor: @admin)
      end
      assert_includes error.message, "already exists"
    end

    test "copies sections categories questions parent links legend tracks and offerings without assignments" do
      copied = nil

      assert_difference "Survey.count", 1 do
        assert_no_difference "SurveyAssignment.count" do
          copied = CopyToSemester.call(source_survey: @source, target_semester: @target_semester, actor: @admin)
        end
      end

      assert_equal @target_semester, copied.program_semester
      assert_equal @source.title, copied.title
      assert_equal [ "Residential" ], copied.track_list
      assert_equal "Copy legend", copied.legend.body
      assert_equal 1, copied.sections.count
      assert_equal 1, copied.offerings.count
      assert_equal 2, copied.questions.count

      copied_parent = copied.questions.find_by!(question_text: @parent.question_text)
      copied_child = copied.questions.find_by!(question_text: @child.question_text)
      assert_equal copied_parent.id, copied_child.parent_question_id
      assert copied.survey_change_logs.where(action: "copy").exists?
    end
  end
end
