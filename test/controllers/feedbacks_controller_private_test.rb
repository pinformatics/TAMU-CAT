require "test_helper"

class FeedbacksControllerPrivateTest < ActionController::TestCase
  tests FeedbacksController
  include ActiveJob::TestHelper

  setup do
    @advisor_user = users(:advisor)
    @admin_user = users(:admin)
    @student_user = users(:student)
    @student = students(:student)
    @survey = surveys(:fall_2025)
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in @advisor_user
    @controller.instance_variable_set(:@student, @student)
    @controller.instance_variable_set(:@survey, @survey)
    @controller.instance_variable_set(:@survey_response, SurveyResponse.build(student: @student, survey: @survey))
  end

  test "confidential note owner resolves advisor admin and denied viewers" do
    assert_equal @student.advisor_id, @controller.send(:confidential_note_owner_advisor_id_for_current_user)

    other_advisor = users(:other_advisor).advisor_profile
    @controller.stub(:current_user, users(:other_advisor)) do
      @controller.stub(:current_advisor_profile, other_advisor) do
        assert_nil @controller.send(:confidential_note_owner_advisor_id_for_current_user)
      end
    end

    sign_out @advisor_user
    sign_in @admin_user
    @controller.instance_variable_set(:@current_advisor, nil)
    assert_equal @student.advisor_id, @controller.send(:confidential_note_owner_advisor_id_for_current_user)

    @student.update!(advisor_id: nil)
    assert_equal @admin_user.id, @controller.send(:confidential_note_owner_advisor_id_for_current_user)

    sign_out @admin_user
    sign_in @student_user
    assert_nil @controller.send(:confidential_note_owner_advisor_id_for_current_user)
  end

  test "confidential note context builds editable and historical tabs for owner" do
    current_note = ConfidentialAdvisorNote.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      body: "Current note"
    )
    other_survey = surveys(:spring_2025)
    other_note = ConfidentialAdvisorNote.create!(
      student_id: @student.student_id,
      survey_id: other_survey.id,
      advisor_id: @student.advisor_id,
      body: "Prior note"
    )

    @controller.send(:load_confidential_note_context)

    assert_equal true, @controller.instance_variable_get(:@confidential_notes_enabled)
    assert_equal current_note, @controller.instance_variable_get(:@confidential_note_current)
    tabs = @controller.instance_variable_get(:@confidential_note_tabs)
    assert_equal true, tabs.find { |tab| tab[:note] == current_note }[:editable]
    assert_equal false, tabs.find { |tab| tab[:note] == other_note }[:editable]
  end

  test "summary visibility follows submitted versions assignments and status" do
    version = SurveyResponseVersion.new(event: "submitted")
    assert_equal true, @controller.send(:self_target_summary_visible?, version)

    SurveyAssignment.find_or_create_by!(student_id: @student.student_id, survey_id: @survey.id) do |assignment|
      assignment.advisor_id = @student.advisor_id
      assignment.assigned_at = Time.current
    end.update!(completed_at: Time.current)
    assert_equal true, @controller.send(:self_target_summary_visible?, nil)

    SurveyAssignment.where(student_id: @student.student_id, survey_id: @survey.id).delete_all
    submitted_response = Struct.new(:status).new(:submitted)
    @controller.instance_variable_set(:@survey_response, submitted_response)
    assert_equal true, @controller.send(:self_target_summary_visible?, nil)

    draft_response = Struct.new(:status).new(:draft)
    @controller.instance_variable_set(:@survey_response, draft_response)
    assert_equal false, @controller.send(:self_target_summary_visible?, nil)
  end

  test "feedback helper methods normalize notices scores offsets and safe return paths" do
    @controller.instance_variable_set(:@submission_intent, "submit")
    assert_match "Submitted feedback", @controller.send(:feedback_saved_notice)

    @controller.instance_variable_set(:@submission_intent, "save")
    assert_match "Saved draft feedback", @controller.send(:feedback_saved_notice)

    q1 = Question.new(id: 100)
    q2 = Question.new(id: 101)
    assert_equal 0, @controller.send(:legacy_answer_id_offset, [], {})
    assert_equal 0, @controller.send(:legacy_answer_id_offset, [ q1 ], {})
    assert_equal 0, @controller.send(:legacy_answer_id_offset, [ q1 ], { "100" => "4" })
    assert_equal 50, @controller.send(:legacy_answer_id_offset, [ q1, q2 ], { "50" => "4", "51" => "3" })

    @controller.params = ActionController::Parameters.new(return_to: "/survey_records")
    assert_equal "/survey_records", @controller.send(:safe_return_to_param)
    @controller.params = ActionController::Parameters.new(return_to: "https://evil.example")
    assert_equal survey_records_path, @controller.send(:safe_return_to_param)
  end

  test "required feedback questions and notification enqueue respect settings and intent" do
    @survey.update!(advisor_numeric_feedback_enabled: false)
    assert_equal [], @controller.send(:required_feedback_question_ids)

    @survey.update!(advisor_numeric_feedback_enabled: true)
    section = SurveySection.find_or_create_by!(survey: @survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = @survey.categories.create!(name: "Private Feedback Questions", section: section)
    included = category.questions.create!(
      question_text: "Included",
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5].to_json,
      has_feedback: true
    )
    category.questions.create!(
      question_text: "Excluded",
      question_type: "dropdown",
      question_order: 2,
      answer_options: %w[1 2 3 4 5].to_json,
      has_feedback: false
    )

    assert_includes @controller.send(:required_feedback_question_ids), included.id
    missing = @controller.send(:missing_required_rating_question_ids, { included.id.to_s => { "average_score" => "" } })
    assert_includes missing, included.id
    assert_equal [], @controller.send(:missing_required_rating_question_ids, { included.id.to_s => { "average_score" => "4" } })

    feedback = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      category_id: category.id,
      question_id: included.id,
      average_score: 4
    )
    @controller.instance_variable_set(:@submission_intent, "save")
    assert_nil @controller.send(:enqueue_feedback_received_notification!, feedback, kind: :submitted)

    @controller.instance_variable_set(:@submission_intent, "submit")
    assert_nil @controller.send(:enqueue_feedback_received_notification!, feedback)

    assert_enqueued_with(job: SurveyNotificationJob) do
      @controller.send(:enqueue_feedback_received_notification!, feedback, kind: :submitted)
    end

    SurveyNotificationJob.stub(:perform_later, ->(*) { raise StandardError, "queue failed" }) do
      assert_nothing_raised { @controller.send(:enqueue_feedback_received_notification!, feedback, kind: :submitted) }
    end
  end

  test "confidential advisor note save handles absent params blank deletion lock versions and missing owner" do
    assert_no_difference "ConfidentialAdvisorNote.count" do
      @controller.instance_variable_set(:@_params, ActionController::Parameters.new({}))
      @controller.send(:save_confidential_advisor_note_from_params!)
    end

    note = ConfidentialAdvisorNote.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      body: "Existing note"
    )
    assert_difference "ConfidentialAdvisorNote.count", -1 do
      @controller.instance_variable_set(:@_params, ActionController::Parameters.new(confidential_advisor_note: { body: " " }))
      @controller.send(:save_confidential_advisor_note_from_params!)
    end

    @controller.instance_variable_set(:@_params, ActionController::Parameters.new(confidential_advisor_note: { body: "Updated note", lock_version: "0" }))
    @controller.send(:save_confidential_advisor_note_from_params!)
    saved = ConfidentialAdvisorNote.find_by!(student_id: @student.student_id, survey_id: @survey.id, advisor_id: @student.advisor_id)
    assert_equal "Updated note", saved.body
    assert_equal 0, saved.lock_version

    @student.update!(advisor_id: nil)
    assert_no_difference "ConfidentialAdvisorNote.count" do
      @controller.instance_variable_set(:@_params, ActionController::Parameters.new(confidential_advisor_note: { body: "No owner" }))
      @controller.send(:save_confidential_advisor_note_from_params!)
    end
  ensure
    @student.update!(advisor_id: advisors(:advisor).advisor_id)
  end

  test "feedback submission state destroys empty persisted rows and saves draft or submitted timestamps" do
    AdvisorFeedbackSubmission.where(student_id: @student.student_id, survey_id: @survey.id, advisor_id: @student.advisor_id).delete_all
    Feedback.where(student_id: @student.student_id, survey_id: @survey.id, advisor_id: @student.advisor_id).delete_all
    ConfidentialAdvisorNote.where(student_id: @student.student_id, survey_id: @survey.id, advisor_id: @student.advisor_id).delete_all
    submission = AdvisorFeedbackSubmission.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      last_saved_at: 2.days.ago
    )

    assert_no_difference "AdvisorFeedbackSubmission.count" do
      @controller.send(:sync_feedback_submission_state!, nil)
    end

    assert_difference "AdvisorFeedbackSubmission.count", -1 do
      @controller.send(:sync_feedback_submission_state!, @student.advisor_id)
    end
    assert_not AdvisorFeedbackSubmission.exists?(submission.id)

    category = categories(:clinical_skills)
    question = questions(:fall_q1)
    Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      category_id: category.id,
      question_id: question.id,
      average_score: 4
    )

    @controller.instance_variable_set(:@submission_intent, "save")
    @controller.send(:sync_feedback_submission_state!, @student.advisor_id)
    draft = AdvisorFeedbackSubmission.find_by!(student_id: @student.student_id, survey_id: @survey.id, advisor_id: @student.advisor_id)
    assert draft.last_saved_at.present?
    assert_nil draft.submitted_at

    @controller.instance_variable_set(:@submission_intent, "submit")
    @controller.send(:sync_feedback_submission_state!, @student.advisor_id)
    assert AdvisorFeedbackSubmission.find(draft.id).submitted_at.present?
  end

  test "version answer remapping supports legacy answer id offsets" do
    @survey = Survey.create!(
      title: "Prefill Remap Survey",
      program_semester: program_semesters(:fall_2025),
      is_active: true,
      categories_attributes: {
        "0" => {
          name: "Initial category",
          questions_attributes: {
            "0" => {
              question_text: "Initial question",
              question_type: "short_answer",
              question_order: 1
            }
          }
        }
      }
    )
    @controller.instance_variable_set(:@survey, @survey)
    @survey.categories.destroy_all
    section = SurveySection.find_or_create_by!(survey: @survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    category = @survey.categories.create!(name: "Prefill Feedback Questions", section: section)
    first = category.questions.create!(
      question_text: "Communication",
      question_type: "dropdown",
      question_order: 100,
      answer_options: %w[1 2 3 4 5].to_json,
      has_feedback: true
    )
    second = category.questions.create!(
      question_text: "Policy Analysis",
      question_type: "dropdown",
      question_order: 101,
      answer_options: %w[1 2 3 4 5].to_json,
      has_feedback: true
    )
    old_first_id = first.id - 50
    version = Struct.new(:answers).new({ old_first_id.to_s => "5", (second.id - 50).to_s => "4" })

    remapped = @controller.send(:remapped_version_answers, version)
    assert_equal "5", remapped[first.id]
    assert_equal "4", remapped[second.id]
  end

  test "load feedback context covers latest versions and disabled summary branches" do
    SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      survey_assignment: survey_assignments(:residential_assignment),
      event: "submitted",
      answers: { questions(:fall_q1).id => "4" }
    )

    @survey_response = SurveyResponse.build(student: @student, survey: @survey)
    @controller.instance_variable_set(:@survey_response, @survey_response)
    @controller.send(:load_feedback_new_context)

    assert @controller.instance_variable_get(:@latest_survey_response_version).present?
    assert_kind_of Hash, @controller.instance_variable_get(:@existing_feedbacks_by_question)
    assert_not_nil @controller.instance_variable_get(:@self_target_summary)
  end

  test "notice intent and active survey guard cover fallback branches" do
    fallback_student = Struct.new(:full_name, :user, :email).new("", nil, nil)
    fallback_survey = Struct.new(:title).new("")
    @controller.instance_variable_set(:@student, fallback_student)
    @controller.instance_variable_set(:@survey, fallback_survey)

    @controller.instance_variable_set(:@submission_intent, "submit")
    assert_equal "submit", @controller.send(:normalize_submission_intent, " submit ")
    assert_equal "save", @controller.send(:normalize_submission_intent, "other")
    assert_match "Submitted feedback for Student on Survey.", @controller.send(:feedback_saved_notice)

    inactive_survey = surveys(:fall_2025)
    inactive_survey.update!(is_active: false)
    @controller.instance_variable_set(:@survey, inactive_survey)
    @controller.stub(:redirect_to, ->(*args, **kwargs) { @redirect_args = [ args, kwargs ]; true }) do
      @controller.send(:ensure_survey_active_for_feedback!)
    end

    assert_equal survey_records_path, @redirect_args.first.first
    assert_match "feedback is read-only", @redirect_args.second[:alert]
  ensure
    surveys(:fall_2025).update!(is_active: true)
    @controller.instance_variable_set(:@student, @student)
    @controller.instance_variable_set(:@survey, @survey)
  end

  test "confidential note context exits for unauthenticated unrelated and student viewers" do
    @controller.stub(:current_user, nil) do
      @controller.send(:load_confidential_note_context)
      assert_equal false, @controller.instance_variable_get(:@confidential_notes_enabled)
    end

    unrelated_advisor = users(:other_advisor)
    @controller.stub(:current_user, unrelated_advisor) do
      @controller.stub(:current_advisor_profile, unrelated_advisor.advisor_profile) do
        @controller.send(:load_confidential_note_context)
        assert_equal false, @controller.instance_variable_get(:@confidential_notes_enabled)
      end
    end

    @controller.stub(:current_user, @student_user) do
      @controller.send(:load_confidential_note_context)
      assert_equal false, @controller.instance_variable_get(:@confidential_notes_enabled)
    end
  end

  test "feedback question filtering skips sub questions non dropdowns and non competency sections" do
    @survey.update!(advisor_numeric_feedback_enabled: true)
    section = SurveySection.find_or_create_by!(survey: @survey, title: SurveySection::MHA_COMPETENCY_SECTION_TITLE)
    competency_category = @survey.categories.create!(name: "Feedback filter competency", section: section)
    plain_category = @survey.categories.create!(name: "Feedback filter plain")
    included = competency_category.questions.create!(
      question_text: "Communication",
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5].to_json,
      has_feedback: true
    )
    competency_category.questions.create!(
      question_text: "Reflection",
      question_type: "short_answer",
      question_order: 2,
      has_feedback: true
    )
    competency_category.questions.create!(
      question_text: "Sub question",
      question_type: "dropdown",
      question_order: 3,
      parent_question: included,
      has_feedback: true
    )
    plain_category.questions.create!(
      question_text: "Plain dropdown",
      question_type: "dropdown",
      question_order: 4,
      has_feedback: true
    )

    assert_equal [ included.id ], @controller.send(:feedback_questions).map(&:id)
  end
end
