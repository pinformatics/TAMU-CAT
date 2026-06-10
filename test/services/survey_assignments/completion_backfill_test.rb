require "test_helper"

module SurveyAssignments
  class CompletionBackfillTest < ActiveSupport::TestCase
    setup do
      @student = students(:student)
      @advisor = advisors(:advisor)
      @student.update!(advisor: @advisor)

      @survey = Survey.new(
        title: "Completion Backfill Survey",
        semester: "Fall 2026",
        program_semester: program_semesters(:fall_2025),
        is_active: true
      )
      @survey.save!(validate: false)
      @category = @survey.categories.create!(name: "Required")
      @required_question = @category.questions.create!(
        question_text: "Required question",
        question_type: "short_answer",
        question_order: 1,
        is_required: true
      )
      @optional_question = @category.questions.create!(
        question_text: "Optional question",
        question_type: "short_answer",
        question_order: 2,
        is_required: false
      )
    end

    test "backfills incomplete assignment when required answers are complete" do
      assignment = SurveyAssignment.create!(
        survey: @survey,
        student: @student,
        advisor: @advisor,
        assigned_at: 2.days.ago,
        completed_at: nil
      )
      answer = StudentQuestion.create!(
        student_id: @student.student_id,
        advisor: @advisor,
        question: @required_question,
        response_value: "Complete"
      )
      StudentQuestion.create!(
        student_id: @student.student_id,
        advisor: @advisor,
        question: @optional_question,
        response_value: ""
      )

      assert_difference -> { SurveyAssignment.where.not(completed_at: nil).count }, 1 do
        assert_equal 1, CompletionBackfill.call(scope: SurveyAssignment.where(id: assignment.id))
      end

      assert_equal answer.updated_at.to_i, assignment.reload.completed_at.to_i
    end

    test "does not backfill assignment when required answers are incomplete" do
      assignment = SurveyAssignment.create!(
        survey: @survey,
        student: @student,
        advisor: @advisor,
        assigned_at: 2.days.ago,
        completed_at: nil
      )

      assert_no_difference -> { SurveyAssignment.where.not(completed_at: nil).count } do
        assert_equal 0, CompletionBackfill.call(scope: SurveyAssignment.where(id: assignment.id))
      end

      assert_nil assignment.reload.completed_at
    end

    test "prefers submitted response version timestamp when available" do
      assignment = SurveyAssignment.create!(
        survey: @survey,
        student: @student,
        advisor: @advisor,
        assigned_at: 2.days.ago,
        completed_at: nil
      )
      StudentQuestion.create!(
        student_id: @student.student_id,
        advisor: @advisor,
        question: @required_question,
        response_value: "Complete"
      )
      submitted_at = Time.zone.local(2026, 6, 1, 12, 30)
      version = SurveyResponseVersion.create!(
        student_id: @student.student_id,
        survey_id: @survey.id,
        survey_assignment: assignment,
        event: "submitted",
        answers: { @required_question.id.to_s => "Complete" },
        created_at: submitted_at,
        updated_at: submitted_at
      )

      assert_equal 1, CompletionBackfill.call(scope: SurveyAssignment.where(id: assignment.id))

      assert_equal version.created_at.to_i, assignment.reload.completed_at.to_i
    end
  end
end
