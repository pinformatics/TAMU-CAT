require "test_helper"

class FeedbacksControllerUnitTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers

  tests FeedbacksController

  setup do
    @advisor_user = users(:advisor)
    @admin_user = users(:admin)

    @student = students(:student) || Student.first
    @survey = surveys(:fall_2025)

    # Ensure the advisor owns the student so confidential note tabs are enabled.
    if @student && @advisor_user&.advisor_profile
      @student.update!(advisor_id: @advisor_user.advisor_profile.advisor_id)
    end
  end

  test "new sanitizes unsafe return_to" do
    sign_in @advisor_user

    get :new, params: {
      survey_id: @survey.id,
      student_id: @student.student_id,
      return_to: "http://evil.example.com"
    }

    assert_response :success
    assert_equal survey_records_path, assigns(:return_to)
  end

  test "new groups existing feedback by category and question using latest updated" do
    sign_in @advisor_user

    category = @survey.categories.first || @survey.categories.create!(name: "Unit Cat", description: "")
    question = category.questions.first || category.questions.create!(
      question_text: "Unit Q",
      question_order: 0,
      question_type: "short_answer",
      is_required: false
    )

    older = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @advisor_user.advisor_profile.advisor_id,
      category_id: category.id,
      question_id: question.id,
      average_score: 3,
      comments: "older"
    )
    newer = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @advisor_user.advisor_profile.advisor_id,
      category_id: category.id,
      question_id: question.id,
      average_score: 4,
      comments: "newer"
    )

    older.update_columns(updated_at: 2.days.ago, created_at: 2.days.ago)
    newer.update_columns(updated_at: 1.day.from_now, created_at: 1.day.from_now)

    get :new, params: { survey_id: @survey.id, student_id: @student.student_id }

    assert_response :success

    by_category = assigns(:existing_feedbacks_by_category)
    by_question = assigns(:existing_feedbacks_by_question)

    assert_equal newer.id, by_category.fetch(category.id).id
    assert_equal newer.id, by_question.fetch(question.id).id
  end

  test "new enables confidential note context for matching advisor" do
    sign_in @advisor_user

    get :new, params: { survey_id: @survey.id, student_id: @student.student_id }

    assert_response :success
    assert_equal true, assigns(:confidential_notes_enabled)
    assert_equal @advisor_user.advisor_profile.advisor_id, assigns(:confidential_note_owner_advisor_id)
    assert assigns(:confidential_note_tabs).is_a?(Array)
    assert assigns(:confidential_note_tabs).any?
  end

  test "new disables confidential note context for student users" do
    sign_in users(:student)

    get :new, params: { survey_id: @survey.id, student_id: @student.student_id }

    assert_response :success
    assert_equal false, assigns(:confidential_notes_enabled)
  end

  test "new enables confidential note context for admins" do
    sign_in @admin_user

    get :new, params: { survey_id: @survey.id, student_id: @student.student_id }

    assert_response :success
    assert_equal true, assigns(:confidential_notes_enabled)
    assert_equal @student.advisor_id, assigns(:confidential_note_owner_advisor_id)
  end
end
