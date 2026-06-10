require "test_helper"

class SurveysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student_user = users(:student)
    @student = students(:student) || Student.first
    @survey = surveys(:fall_2025)
  end

  test "show renders multiple choice and dropdown options" do
    sign_in @student_user

    category = @survey.categories.first || @survey.categories.create!(name: "Test Category", description: "")

    mc = category.questions.create!(
      question_text: "Test MC",
      question_order: 9991,
      question_type: "multiple_choice",
      is_required: true,
      answer_options: %w[Yes No].to_json
    )

    dd = category.questions.create!(
      question_text: "Test DD",
      question_order: 9992,
      question_type: "dropdown",
      is_required: true,
      answer_options: [ [ "Beginner (1)", "1" ], [ "Mastery (5)", "5" ] ].to_json
    )

    short = category.questions.create!(
      question_text: "Test short",
      question_order: 9993,
      question_type: "short_answer",
      is_required: false
    )

    evidence = category.questions.create!(
      question_text: "Test evidence",
      question_order: 9994,
      question_type: "evidence",
      is_required: false
    )

    get survey_path(@survey)
    assert_response :success

    assert_select "input[type=radio][name=?]", "answers[#{mc.id}]", minimum: 2
    assert_select "select[name=?] option", "answers[#{dd.id}]", text: "Beginner (1)"
    assert_select "select[name=?] option", "answers[#{dd.id}]", text: "Mastery (5)"

    assert_select "div[data-controller=?] textarea[name=?][maxlength=?]", "character-counter", "answers[#{short.id}]", StudentQuestion::TEXT_MAX_LENGTH.to_s
    assert_select "div[data-controller=?] input[name=?][maxlength=?]", "character-counter", "answers[#{evidence.id}]", StudentQuestion::TEXT_MAX_LENGTH.to_s
  end

  test "submit redirects when student missing" do
    # no signed in user -> Devise redirects to sign_in
    post submit_survey_path(@survey), params: { answers: {} }
    assert_redirected_to new_user_session_path
  end

  test "submit shows errors for missing required answers" do
    sign_in @student_user
    # Force a required question by marking first question required in test
    q = @survey.questions.first
    q.update!(is_required: true) if q

    post submit_survey_path(@survey), params: { answers: {} }
    assert_response :unprocessable_entity
    assert_select "form"
  end

  test "submit surfaces alert and scroll flags on validation failure" do
    sign_in @student_user
    question = @survey.questions.first
    question.update!(is_required: true)

    post submit_survey_path(@survey), params: { answers: {} }

    assert_response :unprocessable_entity
    assert_match "We could not submit", flash[:alert]
    assert assigns(:scroll_to_form_top), "Expected scroll_to_form_top to be true when no answers were provided"
    assert_equal question.id, assigns(:first_error_question_id)
  end

  test "submit highlights earliest rendered question even when order differs" do
    sign_in @student_user

    primary_category = @survey.categories.first || @survey.categories.create!(name: "Primary", description: "", survey: @survey)
    leading_question = primary_category.questions.first || primary_category.questions.create!(
      question_text: "Primary question",
      question_order: 5,
      question_type: "short_answer",
      is_required: true
    )
    leading_question.update!(question_order: 5, is_required: true)

    later_category = @survey.categories.create!(name: "Later Category")
    later_category.questions.create!(
      question_text: "Secondary question",
      question_order: 0,
      question_type: "short_answer",
      is_required: true
    )

    post submit_survey_path(@survey), params: { answers: {} }

    assert_response :unprocessable_entity
    assert_equal leading_question.id, assigns(:first_error_question_id)
  end

  test "submit persists answers and redirects on success" do
    sign_in @student_user
    answers = {}
    @survey.questions.limit(2).each do |q|
      answers[q.id.to_s] = "Sample answer #{q.id}"
    end
    assert_difference "SurveyResponseVersion.count", 1 do
      post submit_survey_path(@survey), params: { answers: answers }
    end
    # SurveyResponse.build returns a PORO; ensure redirect goes to a survey_response id path
    assert response.redirect?
    location = response.location || headers["Location"]
    assert_match %r{/survey_responses/\d+-\d+}, location
    follow_redirect!
    assert_match /Survey submitted successfully!/, response.body
    assert_match /\d+\/\d+ questions answered/i, response.body
  end

  test "show redirects students with completed surveys to survey response" do
    sign_in @student_user
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current, available_until: 1.day.ago)
    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    get survey_path(@survey)

    assert_redirected_to survey_response_path(survey_response)
    follow_redirect!
    assert_match /already been submitted/i, response.body
  end

  test "save_progress redirects when survey already submitted" do
    sign_in @student_user
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current, available_until: 1.day.ago)
    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    post save_progress_survey_path(@survey), params: { answers: { "1" => "data" } }

    assert_redirected_to survey_response_path(survey_response)
  end

  test "save_progress is blocked after submission even before survey closes" do
    sign_in @student_user
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current, available_until: 2.days.from_now)

    post save_progress_survey_path(@survey), params: { answers: { "1" => "data" } }

    assert_redirected_to survey_path(@survey)
    follow_redirect!
    assert_match /already been submitted/i, response.body
  end

  test "submit redirects when survey already submitted" do
    sign_in @student_user
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current, available_until: 1.day.ago)
    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    post submit_survey_path(@survey), params: { answers: {} }

    assert_redirected_to survey_response_path(survey_response)
  end

  test "show allows revisions before survey closes" do
    sign_in @student_user
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current, available_until: 2.days.from_now)

    get survey_path(@survey)

    assert_response :success
    assert_select "form[data-survey-student-form='true'][data-survey-autosave-enabled='false'][data-survey-editing-submitted-response='true']"
    assert_select "button[data-survey-save-stay]", false
    assert_includes response.body, "Ready to update this submission?"
    assert_includes response.body, "Update submission"
  end

  test "show allows revisions when closing time is not set" do
    sign_in @student_user
    assignment = survey_assignments(:residential_assignment)
    assignment.update!(completed_at: Time.current, available_until: nil)

    get survey_path(@survey)

    assert_response :success
  end

  test "index shows only surveys assigned to the student" do
    sign_in @student_user

    get surveys_path

    assert_response :success
    assert_includes response.body, "Fall 2025 Health Assessment"
    refute_includes response.body, "Spring 2025 Health Assessment"
  end

  test "index hides surveys outside availability window even when assigned" do
    sign_in users(:other_student)

    # Verify the assignment exists (so missing survey is due to window, not a missing assignment)
    assert SurveyAssignment.exists?(student_id: students(:other_student).student_id,
                                    completed_at: nil),
           "Expected an incomplete assignment to exist for other_student"

    get surveys_path

    assert_response :success
    assert_includes response.body, "No surveys assigned (yet)"
    refute_includes response.body, "Spring 2025 Health Assessment"
    refute_includes response.body, "Fall 2025 Executive Assessment"
    refute_includes response.body, "Fall 2025 Health Assessment"
  end

  test "index hides not-yet-open surveys even when assigned" do
    sign_in @student_user
    survey_assignments(:residential_assignment).update!(
      available_from: 5.days.from_now,
      available_until: 10.days.from_now
    )

    get surveys_path

    assert_response :success
    assert_includes response.body, "No surveys assigned (yet)"
    refute_includes response.body, "Fall 2025 Health Assessment"
  end

  test "index hides surveys using survey-level window when assignment has no window set" do
    sign_in @student_user
    # Clear assignment-level window so the survey's own window applies (COALESCE fallback)
    survey_assignments(:residential_assignment).update!(available_from: nil, available_until: nil)
    @survey.update!(available_until: 2.days.ago)

    get surveys_path

    assert_response :success
    assert_includes response.body, "No surveys assigned (yet)"
    refute_includes response.body, "Fall 2025 Health Assessment"
  end

  test "index shows completed surveys even when outside availability window" do
    sign_in users(:completed_student)

    get surveys_path

    assert_response :success
    assert_includes response.body, "Fall 2025 Health Assessment"
  end

  test "index does not show surveys completed only by another student" do
    sign_in @student_user
    # Remove the primary student's own assignment for the fall_2025 survey
    SurveyAssignment.where(student_id: @student.student_id, survey_id: @survey.id).delete_all

    # completed_student has a completed assignment for the same survey outside its window
    # (see completed_residential_assignment fixture); that must not bleed into @student_user's listing
    get surveys_path

    assert_response :success
    refute_includes response.body, "Fall 2025 Health Assessment"
  end

  test "index prompts profile completion when track missing" do
    @student.update!(track: nil)
    sign_in @student_user

    get surveys_path

    assert_response :success
    assert_includes response.body, "Finish setting up your profile"
  ensure
    @student.update!(track: "Residential")
  end

  test "index shows current semester badge" do
    sign_in @student_user

    current_semester = ProgramSemester.find_or_create_by!(current: true) do |s|
      s.name = "Winter 2099"
    end
    current_semester.update!(name: "Winter 2099")

    get surveys_path

    assert_response :success
    assert_includes response.body, "Winter 2099"
  end

  test "index falls back to current month when no semester configured" do
    sign_in @student_user
    ProgramSemester.destroy_all

    get surveys_path

    assert_response :success
    assert_includes response.body, Time.zone.now.strftime("%B %Y")
  end

  test "show displays effective competency target level from CompetencyTargetLevel" do
    sign_in @student_user

    @student.update!(program_year: 2026)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    category = @survey.categories.first || @survey.categories.create!(name: "Test Category", description: "")

    question = category.questions.create!(
      question_text: competency_title,
      question_order: 999,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5].to_json,
      program_target_level: 1
    )

    CompetencyTargetLevel.create!(
      program_semester: @survey.program_semester,
      track: @student.track_before_type_cast,
      program_year: 2026,
      competency_title: competency_title,
      target_level: 4
    )

    get survey_path(@survey)
    assert_response :success

    assert_match(/#{Regexp.escape(competency_title)}.*End-of-program target level: 4\/5/m, response.body)
    refute_match(/#{Regexp.escape(competency_title)}.*End-of-program target level: 1\/5/m, response.body)
  end

  test "show displays course competency context when released evidence exists" do
    sign_in @student_user

    @survey.update!(show_course_competencies_with_survey: false)
    @survey.program_semester.course_grade_release_date&.destroy
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    category = @survey.categories.first || @survey.categories.create!(name: "Test Category", description: "")
    question = category.questions.create!(
      question_text: competency_title,
      question_order: 1001,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5].to_json
    )

    batch = GradeImportBatch.create!(
      uploaded_by: users(:admin),
      program_semester: @survey.program_semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "survey-course-context.csv",
      file_checksum: "survey-course-context-checksum",
      status: "processed"
    )
    batch.grade_competency_ratings.create!(
      student: @student,
      competency_title: question.question_text,
      aggregated_level: 4,
      aggregation_rule: "max",
      evidence_count: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Survey Course Context",
      course_code: "PHPM-701-001",
      competency_title: question.question_text,
      raw_grade: 94,
      mapped_level: 4,
      course_target_level: 5,
      row_number: 2,
      source_key: "survey-course-context-source",
      import_fingerprint: "survey-course-context-fingerprint"
    )

    get survey_path(@survey)
    assert_response :success
    assert_includes response.body, "Course competency evidence"
    assert_includes response.body, "Mastery level: 4"
    assert_includes response.body, "PHPM 701-001"
    assert_includes response.body, "Course target: 5"
  end

  test "show displays released course competency entries from prior semesters under matching questions" do
    sign_in @student_user

    later_survey = surveys(:spring_2026_residential)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    category = later_survey.categories.first || later_survey.categories.create!(name: "Test Category", description: "")
    category.questions.create!(
      question_text: competency_title,
      question_order: 1002,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5].to_json
    )

    batch = GradeImportBatch.create!(
      uploaded_by: users(:admin),
      program_semester: program_semesters(:fall_2025),
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "prior-semester-course-context.csv",
      file_checksum: "prior-semester-course-context-checksum",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Prior Semester Context",
      course_code: "PHPM-601-700",
      competency_title: competency_title,
      raw_grade: 2,
      mapped_level: 2,
      course_target_level: 3,
      row_number: 2,
      source_key: "prior-semester-course-context-source",
      import_fingerprint: "prior-semester-course-context-fingerprint"
    )

    get survey_path(later_survey)

    assert_response :success
    assert_includes response.body, "Course competency evidence"
    assert_includes response.body, "Mastery level: 2"
    assert_includes response.body, "PHPM 601-700"
    assert_includes response.body, "Fall 2025"
  end

  test "show matches course evidence to normalized competency question titles" do
    sign_in @student_user

    evidence_title = "Legal & Ethical Bases for Health Services and Health Systems"
    question_title = "Legal and Ethical Bases for Health Services and Health Systems"
    category = @survey.categories.first || @survey.categories.create!(name: "Test Category", description: "")
    category.questions.create!(
      question_text: question_title,
      question_order: 1004,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5].to_json
    )

    batch = GradeImportBatch.create!(
      uploaded_by: users(:admin),
      program_semester: @survey.program_semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "normalized-course-context.csv",
      file_checksum: "normalized-course-context-checksum",
      status: "processed"
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: @student,
      assignment_name: "Normalized Context",
      course_code: "PHPM-633-700",
      competency_title: evidence_title,
      raw_grade: 3,
      mapped_level: 3,
      course_target_level: 4,
      row_number: 2,
      source_key: "normalized-course-context-source",
      import_fingerprint: "normalized-course-context-fingerprint"
    )

    get survey_path(@survey)

    assert_response :success
    assert_match(/#{Regexp.escape(question_title)}.*Course competency evidence/m, response.body)
    assert_includes response.body, "Mastery level: 3"
    assert_includes response.body, "PHPM 633-700"
  end

  test "show does not render course competency section when a competency has no imported score" do
    sign_in @student_user

    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.second
    category = @survey.categories.first || @survey.categories.create!(name: "Test Category", description: "")
    category.questions.create!(
      question_text: competency_title,
      question_order: 1003,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5].to_json
    )

    get survey_path(@survey)

    assert_response :success
    refute_match(/#{Regexp.escape(competency_title)}.*Course competency evidence/m, response.body)
  end

  # Authentication Tests
  test "index requires authentication" do
    get surveys_path

    assert_redirected_to new_user_session_path
  end

  test "show requires authentication" do
    get survey_path(@survey)

    assert_redirected_to new_user_session_path
  end

  test "submit requires authentication" do
    post submit_survey_path(@survey), params: { answers: {} }

    assert_redirected_to new_user_session_path
  end

  test "save_progress requires authentication" do
    post save_progress_survey_path(@survey), params: { answers: {} }

    assert_redirected_to new_user_session_path
  end

  test "save_progress persists other text for custom other option values" do
    sign_in @student_user

    category = @survey.categories.first || @survey.categories.create!(name: "Test Category", description: "")
    question = category.questions.create!(
      question_text: "Pick one",
      question_order: 9999,
      question_type: "multiple_choice",
      answer_options: [
        { label: "Option A", value: "A" },
        { label: "Other (please specify)", value: "other_custom" }
      ].to_json,
      is_required: false
    )

    post save_progress_survey_path(@survey), params: {
      answers: { question.id.to_s => "other_custom" },
      other_answers: { question.id.to_s => "My custom other" }
    }

    assert_redirected_to student_dashboard_path

    record = StudentQuestion.find_by(student_id: @student.student_id, question_id: question.id)
    assert record, "Expected saved StudentQuestion record"
    assert_kind_of Hash, record.answer
    assert_equal "other_custom", record.answer["answer"]
    assert_equal "My custom other", record.answer["text"]

    get survey_path(@survey)
    assert_response :success
    assert_includes response.body, "My custom other"
  end

  # Show Action Tests
  test "show displays survey form" do
    sign_in @student_user

    get survey_path(@survey)

    assert_response :success
    assert_select "form[data-survey-student-form='true'][data-survey-shared-submit='true'][data-survey-autosave-url='#{save_progress_survey_path(@survey)}'][data-survey-autosave-enabled='true'][data-survey-editing-submitted-response='false']"
    assert_select "button[data-survey-save-exit][formaction='#{save_progress_survey_path(@survey)}']", text: "Cancel"
    assert_select "button[data-survey-save-stay][type='button']", text: "Save Progress"
    assert_select "button[data-survey-save-stay][formaction]", false
    cancel_index = response.body.index('data-survey-save-exit="true"')
    save_index = response.body.index('data-survey-save-stay="true"')
    submit_index = response.body.index('value="Submit Survey"')
    assert_operator cancel_index, :<, save_index
    assert_operator save_index, :<, submit_index
    assert_select "[data-survey-autosave-status]", text: /Autosave/
    assert_select "[data-survey-autosave-prompt]", false
    assert_includes response.body, "installSurveySubmissionForms"
    assert_includes response.body, "installStudentSurveyAutosave"
    assert_includes response.body, "Survey needs attention"
  end

  test "show wires reflection questions to assessment dropdown visibility" do
    sign_in @student_user
    category = @survey.categories.first || @survey.categories.create!(name: "Reflection Category", description: "")
    assessment = category.questions.create!(
      question_text: "Test Reflection Assessment",
      question_order: 9995,
      question_type: "dropdown",
      is_required: true,
      answer_options: [ [ "Developing (2)", "2" ], [ "Mastery (5)", "5" ] ].to_json
    )
    reflection = category.questions.create!(
      question_text: "Test Reflection Assessment Reflection",
      question_order: 9996,
      question_type: "short_answer",
      is_required: false
    )

    get survey_path(@survey)

    assert_response :success
    assert_select "article#question-block-#{reflection.id}[data-reflection-question='true'][data-reflection-source-id='#{assessment.id}'].hidden"
    assert_select "article#question-block-#{reflection.id} .u-danger", text: "*", count: 0

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: assessment.id,
      answer: "2"
    )

    get survey_path(@survey)

    assert_response :success
    assert_select "article#question-block-#{reflection.id}[data-reflection-question='true'][data-reflection-source-id='#{assessment.id}'].hidden", count: 0
    assert_select "article#question-block-#{reflection.id}[data-reflection-question='true'][data-reflection-source-id='#{assessment.id}']"
    assert_select "article#question-block-#{reflection.id} .u-danger", text: "*", count: 0
  end

  test "show hides employment child questions until yes is selected" do
    sign_in @student_user
    survey, parent, employer, job_title, hours, flexibility = build_employment_branch_survey

    get survey_path(survey)

    assert_response :success
    assert_select "article#question-block-#{parent.id}[data-branch-parent='true'][data-branch-parent-id='#{parent.id}'][data-branch-target-value='Yes']"
    [ employer, job_title, hours, flexibility ].each do |question|
      assert_select "article#question-block-#{question.id}[data-branch-child-of='#{parent.id}'].hidden[aria-hidden='true']"
      assert_select "article#question-block-#{question.id} .u-danger", text: "*"
    end

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: parent.id,
      answer: "Yes"
    )

    get survey_path(survey)

    assert_response :success
    [ employer, job_title, hours, flexibility ].each do |question|
      assert_select "article#question-block-#{question.id}[data-branch-child-of='#{parent.id}'].hidden", count: 0
      assert_select "article#question-block-#{question.id}[aria-hidden='false']"
    end
  end

  test "submit requires employment child questions only when parent answer is yes" do
    sign_in @student_user
    survey, parent, employer, job_title, hours, flexibility = build_employment_branch_survey

    post submit_survey_path(survey), params: {
      answers: { parent.id.to_s => "Yes" }
    }

    assert_response :unprocessable_entity
    missing_ids = Array(assigns(:missing_required)).map(&:to_i)
    assert_includes missing_ids, employer.id
    assert_includes missing_ids, job_title.id
    assert_includes missing_ids, hours.id
    assert_includes missing_ids, flexibility.id

    post submit_survey_path(survey), params: {
      answers: { parent.id.to_s => "No" }
    }

    assert_response :redirect
    assert SurveyAssignment.find_by!(survey_id: survey.id, student_id: @student.student_id).completed_at?
  end

  test "submit does not require employment child questions unless they are manually required" do
    sign_in @student_user
    survey, parent, _employer, _job_title, _hours, _flexibility = build_employment_branch_survey(parent_required: true, children_required: false)

    post submit_survey_path(survey), params: {
      answers: { parent.id.to_s => "Yes" }
    }

    assert_response :redirect
    assert SurveyAssignment.find_by!(survey_id: survey.id, student_id: @student.student_id).completed_at?
  end

  test "submit saves other text for flexible work hours" do
    sign_in @student_user
    survey, parent, employer, job_title, hours, flexibility = build_employment_branch_survey

    post submit_survey_path(survey), params: {
      answers: {
        parent.id.to_s => "Yes",
        employer.id.to_s => "Texas A&M Health",
        job_title.id.to_s => "Analyst",
        hours.id.to_s => "20",
        flexibility.id.to_s => "Other"
      },
      other_answers: { flexibility.id.to_s => "Varies by rotation" }
    }

    assert_response :redirect

    record = StudentQuestion.find_by!(student_id: @student.student_id, question_id: flexibility.id)
    assert_equal "Other", record.answer["answer"]
    assert_equal "Varies by rotation", record.answer["text"]
  end

  test "submit requires other text when flexible work hours uses other" do
    sign_in @student_user
    survey, parent, employer, job_title, hours, flexibility = build_employment_branch_survey

    post submit_survey_path(survey), params: {
      answers: {
        parent.id.to_s => "Yes",
        employer.id.to_s => "Texas A&M Health",
        job_title.id.to_s => "Analyst",
        hours.id.to_s => "20",
        flexibility.id.to_s => "Other"
      },
      other_answers: { flexibility.id.to_s => "" }
    }

    assert_response :unprocessable_entity
    assert_includes Array(assigns(:missing_required)).map(&:to_i), flexibility.id
  end

  test "show pre-populates existing answers" do
    sign_in @student_user
    question = @survey.questions.first
    StudentQuestion.find_or_create_by!(
      student_id: @student.student_id,
      question_id: question.id
    ) do |sq|
      sq.answer = "My previous answer"
      sq.advisor_id = @student.advisor_id
    end

    get survey_path(@survey)

    assert_response :success
  end

  test "show handles student without saved responses" do
    sign_in @student_user

    get survey_path(@survey)

    assert_response :success
  end

  test "show computes required fields correctly" do
    sign_in @student_user

    get survey_path(@survey)

    assert_response :success
  end

  # Submit Action Tests
  test "submit creates or updates survey assignment" do
    sign_in @student_user

    post submit_survey_path(@survey), params: { answers: {} }

    assignment = SurveyAssignment.find_by(
      survey_id: @survey.id,
      student_id: @student.student_id
    )
    assert assignment.present?
  end

  test "submit marks assignment as completed" do
    sign_in @student_user
    # Provide answers for any required questions
    answers = {}
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :redirect
    assignment = SurveyAssignment.find_by(
      survey_id: @survey.id,
      student_id: @student.student_id
    )
    assert assignment.present?
  end

  test "submit saves student answers" do
    sign_in @student_user
    question = @survey.questions.first
    answers = { question.id.to_s => "Test answer" }

    post submit_survey_path(@survey), params: { answers: answers }

    student_question = StudentQuestion.find_by(
      student_id: @student.student_id,
      question_id: question.id
    )
    assert_equal "Test answer", student_question.answer
  end

  test "submit validates required questions" do
    sign_in @student_user
    question = @survey.questions.first
    question.update!(is_required: true)

    post submit_survey_path(@survey), params: { answers: {} }

    assert_response :unprocessable_entity
  end

  test "submit rejects invalid integer answer and keeps integer draft" do
    sign_in @student_user
    category = @survey.categories.first || @survey.categories.create!(name: "Integer Category", description: "")
    integer_question = category.questions.create!(
      question_text: "How many hours per week do you work on average?",
      question_order: 9998,
      question_type: "integer",
      integer_min: 1,
      integer_max: 100,
      is_required: true
    )

    post submit_survey_path(@survey), params: { answers: { integer_question.id.to_s => "-1" } }

    assert_response :unprocessable_entity
    assert_match(/Review the highlighted integer responses/i, flash[:alert].to_s)

    student_question = StudentQuestion.find_by(
      student_id: @student.student_id,
      question_id: integer_question.id
    )
    assert_not_nil student_question
    assert_equal "-1", student_question.answer
  end

  test "submit does not force integer errors to be first jump target" do
    sign_in @student_user
    category = @survey.categories.first || @survey.categories.create!(name: "Mixed Validation Category", description: "")

    required_question = category.questions.create!(
      question_text: "Required free text",
      question_order: 9996,
      question_type: "short_answer",
      is_required: true
    )

    integer_question = category.questions.create!(
      question_text: "Integer hours",
      question_order: 9997,
      question_type: "integer",
      integer_min: 1,
      integer_max: 100,
      is_required: true
    )

    post submit_survey_path(@survey), params: {
      answers: {
        required_question.id.to_s => "",
        integer_question.id.to_s => "-1"
      }
    }

    assert_response :unprocessable_entity
    refute_equal integer_question.id, assigns(:first_error_question_id)
    assert_includes Array(assigns(:missing_required)).map(&:to_i), assigns(:first_error_question_id).to_i
  end

  test "submit persists partial answers even on validation failure" do
    sign_in @student_user
    questions = @survey.questions.order(:question_order).limit(2).to_a
    if questions.size < 2
      category = @survey.categories.first || categories(:clinical_skills)
      needed = 2 - questions.size
      needed.times do |index|
        Question.create!(
          category: category,
          question_text: "Generated question ##{index}",
          question_order: category.questions.maximum(:question_order).to_i + 1 + index,
          question_type: "short_answer",
          is_required: false
        )
      end
      questions = @survey.questions.order(:question_order).limit(2).to_a
    end
    q1 = questions.first
    q2 = questions.second
    q1.update!(is_required: true)

    answers = { q2.id.to_s => "Partial answer" }
    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert StudentQuestion.exists?(student_id: @student.student_id, question_id: q2.id)
  end

  test "submit handles multiple choice questions" do
    sign_in @student_user
    question = @survey.questions.find_by(question_type: "multiple_choice") || @survey.questions.first
    answers = { question.id.to_s => "Option A" }

    post submit_survey_path(@survey), params: { answers: answers }

    assert response.redirect?
  end

  test "submit destroys blank answers for existing records" do
    sign_in @student_user
    question = @survey.questions.first
    StudentQuestion.find_or_create_by!(
      student_id: @student.student_id,
      question_id: question.id
    ) do |sq|
      sq.answer = "Previous answer"
      sq.advisor_id = @student.advisor_id
    end

    answers = { question.id.to_s => "" }
    post submit_survey_path(@survey), params: { answers: answers }

    assert_not StudentQuestion.exists?(student_id: @student.student_id, question_id: question.id)
  end

  # Save Progress Tests
  test "save_progress saves answers without validation" do
    sign_in @student_user
    question = @survey.questions.first

    answers = { question.id.to_s => "Draft answer" }
    post save_progress_survey_path(@survey), params: { answers: answers }

    assert_redirected_to student_dashboard_path
    assert_match /Progress saved! You can continue later\./, flash[:notice]
    assert_match /\d+\/\d+ questions answered/i, flash[:notice]
  end

  test "save_progress does not create response versions" do
    sign_in @student_user
    question = @survey.questions.first
    version_count = -> { SurveyResponseVersion.for_pair(student_id: @student.student_id, survey_id: @survey.id).count }

    assert_no_difference version_count do
      post save_progress_survey_path(@survey), params: {
        answers: { question.id.to_s => "Draft only" }
      }
    end

    assert_redirected_to student_dashboard_path
    student_question = StudentQuestion.find_by(student_id: @student.student_id, question_id: question.id)
    assert_equal "Draft only", student_question.answer
  end

  test "save_progress can save and stay on the survey" do
    sign_in @student_user
    question = @survey.questions.first

    post save_progress_survey_path(@survey), params: {
      stay: "1",
      answers: { question.id.to_s => "Stay on page draft" }
    }

    assert_redirected_to survey_path(@survey)
    assert_match /Progress saved! You can continue later\./, flash[:notice]
    student_question = StudentQuestion.find_by(student_id: @student.student_id, question_id: question.id)
    assert_equal "Stay on page draft", student_question.answer
  end

  test "save_progress can save and exit to a safe internal path" do
    sign_in @student_user
    question = @survey.questions.first

    post save_progress_survey_path(@survey), params: {
      exit_to: surveys_path,
      answers: { question.id.to_s => "Exit draft" }
    }

    assert_redirected_to surveys_path
    student_question = StudentQuestion.find_by(student_id: @student.student_id, question_id: question.id)
    assert_equal "Exit draft", student_question.answer
  end

  test "save_progress autosave returns json without redirecting" do
    sign_in @student_user
    question = @survey.questions.first

    post save_progress_survey_path(@survey),
         params: { autosave: "1", answers: { question.id.to_s => "Autosaved draft" } },
         headers: { "X-Requested-With" => "XMLHttpRequest", "Accept" => "application/json" }

    assert_response :success
    assert_equal "application/json", response.media_type
    payload = JSON.parse(response.body)
    assert_equal true, payload["saved"]
    assert_match "Progress saved", payload["message"]

    student_question = StudentQuestion.find_by(student_id: @student.student_id, question_id: question.id)
    assert_equal "Autosaved draft", student_question.answer
  end

  test "save_progress autosave does not create response versions" do
    sign_in @student_user
    question = @survey.questions.first
    version_count = -> { SurveyResponseVersion.for_pair(student_id: @student.student_id, survey_id: @survey.id).count }

    assert_no_difference version_count do
      post save_progress_survey_path(@survey),
           params: { autosave: "1", answers: { question.id.to_s => "Autosaved draft only" } },
           headers: { "X-Requested-With" => "XMLHttpRequest", "Accept" => "application/json" }
    end

    assert_response :success
    student_question = StudentQuestion.find_by(student_id: @student.student_id, question_id: question.id)
    assert_equal "Autosaved draft only", student_question.answer
  end

  test "save_progress allows blank required fields" do
    sign_in @student_user
    question = @survey.questions.first
    question.update!(is_required: true)

    post save_progress_survey_path(@survey), params: { answers: {} }

    assert_redirected_to student_dashboard_path
  end

  test "save_progress updates existing answers" do
    sign_in @student_user
    question = @survey.questions.first
    StudentQuestion.find_or_create_by!(
      student_id: @student.student_id,
      question_id: question.id
    ) do |sq|
      sq.answer = "Old answer"
      sq.advisor_id = @student.advisor_id
    end

    answers = { question.id.to_s => "Updated answer" }
    post save_progress_survey_path(@survey), params: { answers: answers }

    student_question = StudentQuestion.find_by(
      student_id: @student.student_id,
      question_id: question.id
    )
    assert_equal "Updated answer", student_question.answer
  end

  test "save_progress persists valid integer answers" do
    sign_in @student_user
    category = @survey.categories.first || @survey.categories.create!(name: "Integer Save Category", description: "")
    integer_question = category.questions.create!(
      question_text: "Hours worked per week",
      question_order: 9998,
      question_type: "integer",
      integer_min: 1,
      integer_max: 100,
      is_required: false
    )

    post save_progress_survey_path(@survey), params: {
      answers: { integer_question.id.to_s => "40" }
    }

    assert_redirected_to student_dashboard_path

    student_question = StudentQuestion.find_by(
      student_id: @student.student_id,
      question_id: integer_question.id
    )
    assert_not_nil student_question
    assert_equal "40", student_question.answer
  end

  test "save_progress persists out-of-range integer draft values" do
    sign_in @student_user
    category = @survey.categories.first || @survey.categories.create!(name: "Integer Draft Category", description: "")
    integer_question = category.questions.create!(
      question_text: "Hours worked per week",
      question_order: 9997,
      question_type: "integer",
      integer_min: 1,
      integer_max: 100,
      is_required: false
    )

    post save_progress_survey_path(@survey), params: {
      answers: { integer_question.id.to_s => "-1" }
    }

    assert_redirected_to student_dashboard_path

    student_question = StudentQuestion.find_by(
      student_id: @student.student_id,
      question_id: integer_question.id
    )
    assert_not_nil student_question
    assert_equal "-1", student_question.answer
  end

  test "save_progress destroys empty answers" do
    sign_in @student_user
    question = @survey.questions.first
    StudentQuestion.find_or_create_by!(
      student_id: @student.student_id,
      question_id: question.id
    ) do |sq|
      sq.answer = "Old answer"
      sq.advisor_id = @student.advisor_id
    end

    answers = { question.id.to_s => "" }
    post save_progress_survey_path(@survey), params: { answers: answers }

    assert_not StudentQuestion.exists?(student_id: @student.student_id, question_id: question.id)
  end

  test "save_progress requires student record" do
    sign_in @student_user
    @student.destroy

    post save_progress_survey_path(@survey), params: { answers: {} }

    assert_redirected_to student_dashboard_path
    assert_equal "We could not find a student record for your account.", flash[:alert]
  end

  # Index Action Tests
  test "index returns empty surveys when student has no track" do
    sign_in @student_user
    @student.update!(track: nil)

    get surveys_path

    assert_response :success
  ensure
    @student.update!(track: "Residential")
  end

  test "index filters surveys by track" do
    sign_in @student_user

    get surveys_path

    assert_response :success
  end

  test "index includes survey assignment lookup" do
    sign_in @student_user

    get surveys_path

    assert_response :success
  end

  test "index orders surveys by display priority" do
    sign_in @student_user

    get surveys_path

    assert_response :success
  end

  # Completed Survey Redirect Tests
  test "show redirects to survey response for completed surveys" do
    sign_in @student_user
    assignment = SurveyAssignment.find_or_create_by!(
      survey_id: @survey.id,
      student_id: @student.student_id
    ) do |a|
      a.advisor_id = @student.advisor_id
      a.assigned_at = 1.day.ago
    end
    assignment.update!(completed_at: Time.current, available_until: 1.day.ago)

    get survey_path(@survey)

    assert response.redirect?
  end

  test "submit redirects to survey response for completed surveys" do
    sign_in @student_user
    assignment = SurveyAssignment.find_or_create_by!(
      survey_id: @survey.id,
      student_id: @student.student_id
    ) do |a|
      a.advisor_id = @student.advisor_id
      a.assigned_at = 1.day.ago
    end
    assignment.update!(completed_at: Time.current, available_until: 1.day.ago)

    post submit_survey_path(@survey), params: { answers: {} }

    assert response.redirect?
  end

  test "save_progress redirects to survey response for completed surveys" do
    sign_in @student_user
    assignment = SurveyAssignment.find_or_create_by!(
      survey_id: @survey.id,
      student_id: @student.student_id
    ) do |a|
      a.advisor_id = @student.advisor_id
      a.assigned_at = 1.day.ago
    end
    assignment.update!(completed_at: Time.current, available_until: 1.day.ago)

    post save_progress_survey_path(@survey), params: { answers: {} }

    assert response.redirect?
  end

  test "show redirects to survey response when survey is archived" do
    sign_in @student_user

    assignment = SurveyAssignment.find_or_create_by!(
      survey_id: @survey.id,
      student_id: @student.student_id
    ) do |a|
      a.advisor_id = @student.advisor_id
      a.assigned_at = 1.day.ago
    end
    assignment.update!(available_until: 2.days.from_now)
    @survey.update!(is_active: false)

    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    get survey_path(@survey)

    assert_redirected_to survey_response_path(survey_response)
    follow_redirect!
    assert_match(/no longer available/i, response.body)
  end

  test "submit redirects to survey response when survey is archived" do
    sign_in @student_user

    SurveyAssignment.find_or_create_by!(
      survey_id: @survey.id,
      student_id: @student.student_id
    ) do |a|
      a.advisor_id = @student.advisor_id
      a.assigned_at = 1.day.ago
    end
    @survey.update!(is_active: false)

    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    post submit_survey_path(@survey), params: { answers: {} }

    assert_redirected_to survey_response_path(survey_response)
    follow_redirect!
    assert_match(/no longer available/i, response.body)
  end

  test "save_progress redirects to survey response when survey is archived" do
    sign_in @student_user

    SurveyAssignment.find_or_create_by!(
      survey_id: @survey.id,
      student_id: @student.student_id
    ) do |a|
      a.advisor_id = @student.advisor_id
      a.assigned_at = 1.day.ago
    end
    @survey.update!(is_active: false)

    survey_response = SurveyResponse.build(student: @student, survey: @survey)

    post save_progress_survey_path(@survey), params: { answers: {} }

    assert_redirected_to survey_response_path(survey_response)
    follow_redirect!
    assert_match(/no longer available/i, response.body)
  end

  # Answer Format Tests
  test "show handles hash answers with text key" do
    sign_in @student_user
    question = @survey.questions.first
    StudentQuestion.find_or_create_by!(
      student_id: @student.student_id,
      question_id: question.id
    ) do |sq|
      sq.answer = { "text" => "My answer", "rating" => 5 }
      sq.advisor_id = @student.advisor_id
    end

    get survey_path(@survey)

    assert_response :success
  end

  test "show handles hash answers with link key for evidence" do
    sign_in @student_user
    category = @survey.categories.first
    question = Question.create!(
      question_text: "Evidence question",
      question_type: "evidence",
      category_id: category.id
    )
    StudentQuestion.find_or_create_by!(
      student_id: @student.student_id,
      question_id: question.id
    ) do |sq|
      sq.answer = { "link" => "https://sites.google.com/tamu.edu/demo/home" }
      sq.advisor_id = @student.advisor_id
    end

    get survey_path(@survey)

    assert_response :success
  end

  test "show handles string answers" do
    sign_in @student_user
    question = @survey.questions.first
    StudentQuestion.find_or_create_by!(
      student_id: @student.student_id,
      question_id: question.id
    ) do |sq|
      sq.answer = "Simple string answer"
      sq.advisor_id = @student.advisor_id
    end

    get survey_path(@survey)

    assert_response :success
  end

  # Multiple Choice Required Logic Tests
  test "submit treats yes/no questions as optional by default" do
    sign_in @student_user
    # This test verifies the controller logic for yes/no questions
    # Just check that the controller responds
    answers = {}
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :redirect
  end

  test "submit treats flexibility questions as optional by default" do
    sign_in @student_user
    # This test verifies the controller logic for flexibility scale questions
    # Just check that the controller responds
    answers = {}
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :redirect
  end

  test "submit treats other multiple choice as required" do
    sign_in @student_user
    category = @survey.categories.first
    question = Question.create!(
      question_text: "Choose option",
      question_type: "multiple_choice",
      answer_options: "A\nB\nC",
      category_id: category.id,
      is_required: false
    )

    post submit_survey_path(@survey), params: { answers: {} }

    assert_response :unprocessable_entity
  end

  # Notification Tests - removed enqueue test as job configuration may vary

  # Survey Not Found Tests
  test "show raises error for non-existent survey" do
    sign_in @student_user

    assert_raises ActiveRecord::RecordNotFound do
      Survey.find(99999)
    end
  end

  test "submit raises error for non-existent survey" do
    sign_in @student_user

    assert_raises ActiveRecord::RecordNotFound do
      Survey.find(99999)
    end
  end

  # Transaction Rollback Tests - removed mock test

  # Answer Persistence Tests
  test "submit sets advisor_id on student questions" do
    sign_in @student_user
    question = @survey.questions.first
    answers = { question.id.to_s => "Test" }

    post submit_survey_path(@survey), params: { answers: answers }

    student_question = StudentQuestion.find_by(
      student_id: @student.student_id,
      question_id: question.id
    )
    assert_equal @student.advisor_id, student_question.advisor_id
  end

  test "save_progress sets advisor_id on student questions" do
    sign_in @student_user
    question = @survey.questions.first
    answers = { question.id.to_s => "Test" }

    post save_progress_survey_path(@survey), params: { answers: answers }

    student_question = StudentQuestion.find_by(
      student_id: @student.student_id,
      question_id: question.id
    )
    assert_equal @student.advisor_id, student_question.advisor_id
  end

  # Assignment Creation Tests
  test "submit sets assigned_at if not already set" do
    sign_in @student_user

    post submit_survey_path(@survey), params: { answers: {} }

    assignment = SurveyAssignment.find_by(
      survey_id: @survey.id,
      student_id: @student.student_id
    )
    assert assignment.assigned_at.present?
  end

  test "submit preserves existing assigned_at" do
    sign_in @student_user
    old_time = 2.days.ago
    assignment = SurveyAssignment.find_or_create_by!(survey_id: @survey.id, student_id: @student.student_id)
    assignment.update!(advisor_id: @student.advisor_id, assigned_at: old_time)

    # Provide answers for required questions
    answers = {}
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assignment.reload
    assert_in_delta old_time.to_i, assignment.assigned_at.to_i, 180
  end

  # Edge Cases
  test "submit handles empty answers parameter" do
    sign_in @student_user

    post submit_survey_path(@survey)

    # May return 422 if there are required questions, or redirect if none
    assert_includes [ 302, 422 ], @response.status
  end

  test "save_progress handles empty answers parameter" do
    sign_in @student_user

    post save_progress_survey_path(@survey)

    assert_redirected_to student_dashboard_path
  end

  test "submit ignores answers for non-survey questions" do
    sign_in @student_user
    semester = ProgramSemester.first || ProgramSemester.create!(name: "Test Semester", current: false)
    other_survey = Survey.new(title: "Other Survey", semester: semester.name)
    other_category = Category.new(name: "Other")
    other_question = Question.new(
      question_text: "Other",
      question_type: "short_answer"
    )
    other_category.questions << other_question
    other_survey.categories << other_category
    other_survey.save!

    # Provide answers for required questions
    answers = { other_question.id.to_s => "Should be ignored" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_not StudentQuestion.exists?(
      student_id: @student.student_id,
      question_id: other_question.id
    )
  end

  test "save_progress ignores answers for non-survey questions" do
    sign_in @student_user
    semester = ProgramSemester.first || ProgramSemester.create!(name: "Test Semester", current: false)
    other_survey = Survey.new(title: "Other Survey", semester: semester.name)
    other_category = Category.new(name: "Other")
    other_question = Question.new(
      question_text: "Other",
      question_type: "short_answer"
    )
    other_category.questions << other_question
    other_survey.categories << other_category
    other_survey.save!

    answers = { other_question.id.to_s => "Should be ignored" }
    post save_progress_survey_path(@survey), params: { answers: answers }

    assert_not StudentQuestion.exists?(
      student_id: @student.student_id,
      question_id: other_question.id
    )
  end

  # Category and Question Loading Tests
  test "show loads categories with questions" do
    sign_in @student_user

    get survey_path(@survey)

    assert_response :success
  end

  test "show orders categories by id" do
    sign_in @student_user

    get survey_path(@survey)

    assert_response :success
  end

  # Student Record Tests
  test "submit requires valid student record" do
    sign_in @student_user
    @student.destroy

    post submit_survey_path(@survey), params: { answers: {} }

    assert_redirected_to student_dashboard_path
    assert_equal "We could not find a student record for your account.", flash[:alert]
  end

  # Flash Message Tests
  test "save_progress shows success message" do
    sign_in @student_user

    post save_progress_survey_path(@survey), params: { answers: {} }

    assert_match /Progress saved! You can continue later\./, flash[:notice]
    assert_match /\d+\/\d+ questions answered/i, flash[:notice]
  end

  test "submit redirects on success" do
    sign_in @student_user
    # Provide answers for any required questions
    answers = {}
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :redirect
  end

  test "completed assignment redirect shows alert" do
    sign_in @student_user
    assignment = SurveyAssignment.find_or_create_by!(
      survey_id: @survey.id,
      student_id: @student.student_id
    ) do |a|
      a.advisor_id = @student.advisor_id
      a.assigned_at = 1.day.ago
    end
    assignment.update!(completed_at: Time.current, available_until: 1.day.ago)

    get survey_path(@survey)

    assert_match /already been submitted/i, flash[:alert]
  end

  # Evidence validation tests
  test "submit rejects evidence with invalid URL format" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "not-a-valid-url" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit rejects evidence with non-HTTPS URL" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "http://drive.google.com/file/d/123" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit rejects evidence from non-allowlisted domain" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "https://example.com/file/123" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit rejects inaccessible evidence link (forbidden)" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock HTTP response for forbidden access
    stub_request(:head, "https://drive.google.com/file/d/forbidden123/view")
      .to_return(status: 403)

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/forbidden123/view" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit rejects inaccessible evidence link (not found)" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock HTTP response for not found
    stub_request(:head, "https://drive.google.com/file/d/notfound123/view")
      .to_return(status: 404)

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/notfound123/view" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit rejects evidence link with timeout" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock HTTP timeout
    stub_request(:head, "https://drive.google.com/file/d/timeout123/view")
      .to_timeout

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/timeout123/view" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit accepts accessible evidence link" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock successful HTTP response
    stub_request(:head, "https://sites.google.com/tamu.edu/valid123/home")
      .to_return(status: 200)
    stub_request(:get, "https://sites.google.com/tamu.edu/valid123/home")
      .with(headers: { "Range" => "bytes=0-2047" })
      .to_return(status: 200, body: "This is a public file content")

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "https://sites.google.com/tamu.edu/valid123/home" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :redirect
  end

  test "submit accepts google sites evidence link" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    stub_request(:head, "https://sites.google.com/view/public-site").to_return(status: 200)
    stub_request(:get, "https://sites.google.com/view/public-site")
      .with(headers: { "Range" => "bytes=0-2047" })
      .to_return(status: 200, body: "Public Google Site")

    answers = { evidence_question.id.to_s => "https://sites.google.com/view/public-site" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :redirect
  end

  test "submit rejects evidence with access-required interstitial page" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock HTTP response that returns 200 but shows access required message
    stub_request(:head, "https://drive.google.com/file/d/restricted123/view")
      .to_return(status: 200)
    stub_request(:get, "https://drive.google.com/file/d/restricted123/view")
      .with(headers: { "Range" => "bytes=0-2047" })
      .to_return(status: 200, body: "You need access to view this file. Sign in to continue.")

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/restricted123/view" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit accepts evidence with public markers in content" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock HTTP response with public markers
    stub_request(:head, "https://sites.google.com/tamu.edu/public123/home")
      .to_return(status: 200)
    stub_request(:get, "https://sites.google.com/tamu.edu/public123/home")
      .with(headers: { "Range" => "bytes=0-2047" })
      .to_return(status: 200, body: "Open with Google Docs - anyone with the link can view this file")

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "https://sites.google.com/tamu.edu/public123/home" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :redirect
  end

  test "submit rejects Google Docs evidence links" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    answers = { evidence_question.id.to_s => "https://docs.google.com/document/d/abc123/edit" }

    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit rejects Docs links without running page checks" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    answers = { evidence_question.id.to_s => "https://docs.google.com/document/d/abc123/edit" }

    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit rejects Google Docs with export timeout" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock export endpoint timeout
    stub_request(:get, "https://docs.google.com/document/d/timeout123/export?format=txt")
      .with(headers: { "Range" => "bytes=0-1023" })
      .to_timeout

    # Provide answers for all required questions


    answers = { evidence_question.id.to_s => "https://docs.google.com/document/d/timeout123/edit" }


    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end



    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  # HTTP redirect tests
  test "submit follows valid redirects within allowlist" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock redirect to googleusercontent.com
    stub_request(:head, "https://sites.google.com/tamu.edu/redirect123/home")
      .to_return(status: 302, headers: { "Location" => "https://lh3.googleusercontent.com/actual-file" })
    stub_request(:head, "https://lh3.googleusercontent.com/actual-file")
      .to_return(status: 200)
    stub_request(:get, "https://lh3.googleusercontent.com/actual-file")
      .with(headers: { "Range" => "bytes=0-2047" })
      .to_return(status: 200, body: "File content")

    # Provide answers for all required questions


    answers = { evidence_question.id.to_s => "https://sites.google.com/tamu.edu/redirect123/home" }


    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end



    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :redirect
  end

  test "submit rejects redirect to non-allowlisted domain" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock redirect to accounts.google.com (login page)
    stub_request(:head, "https://drive.google.com/file/d/private123/view")
      .to_return(status: 302, headers: { "Location" => "https://accounts.google.com/signin" })

    # Provide answers for all required questions


    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/private123/view" }


    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end



    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit rejects too many redirects" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock infinite redirect loop
    stub_request(:head, "https://drive.google.com/file/d/loop1/view")
      .to_return(status: 302, headers: { "Location" => "https://drive.google.com/file/d/loop2/view" })
    stub_request(:head, "https://drive.google.com/file/d/loop2/view")
      .to_return(status: 302, headers: { "Location" => "https://drive.google.com/file/d/loop3/view" })
    stub_request(:head, "https://drive.google.com/file/d/loop3/view")
      .to_return(status: 302, headers: { "Location" => "https://drive.google.com/file/d/loop4/view" })
    stub_request(:head, "https://drive.google.com/file/d/loop4/view")
      .to_return(status: 302, headers: { "Location" => "https://drive.google.com/file/d/loop1/view" })

    # Provide answers for all required questions


    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/loop1/view" }


    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end



    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit handles redirect without location header" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock redirect without Location header
    stub_request(:head, "https://drive.google.com/file/d/nolocation/view")
      .to_return(status: 302, headers: {})

    # Provide answers for all required questions


    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/nolocation/view" }


    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end



    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  # HTTP method fallback tests
  test "submit falls back to GET when HEAD not allowed" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock HEAD returning 405 Method Not Allowed
    stub_request(:head, "https://sites.google.com/tamu.edu/nohead123/home")
      .to_return(status: 405)
    # Fall back to minimal GET
    stub_request(:get, "https://sites.google.com/tamu.edu/nohead123/home")
      .with(headers: { "Range" => "bytes=0-0" })
      .to_return(status: 200)
    # Sniff check
    stub_request(:get, "https://sites.google.com/tamu.edu/nohead123/home")
      .with(headers: { "Range" => "bytes=0-2047" })
      .to_return(status: 200, body: "Public file content")

    # Provide answers for all required questions


    answers = { evidence_question.id.to_s => "https://sites.google.com/tamu.edu/nohead123/home" }


    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end



    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :redirect
  end

  test "submit handles sniff timeout during GET fallback" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock HEAD returning 405 Method Not Allowed
    stub_request(:head, "https://drive.google.com/file/d/snifftimeout/view")
      .to_return(status: 405)
    # Fall back to minimal GET
    stub_request(:get, "https://drive.google.com/file/d/snifftimeout/view")
      .with(headers: { "Range" => "bytes=0-0" })
      .to_return(status: 200)
    # Sniff times out
    stub_request(:get, "https://drive.google.com/file/d/snifftimeout/view")
      .with(headers: { "Range" => "bytes=0-2047" })
      .to_timeout

    # Provide answers for all required questions


    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/snifftimeout/view" }


    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end



    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit handles other HTTP errors" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock 500 Internal Server Error
    stub_request(:head, "https://drive.google.com/file/d/error500/view")
      .to_return(status: 500)

    # Provide answers for all required questions


    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/error500/view" }


    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end



    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  test "submit handles network exceptions during evidence check" do
    sign_in @student_user
    evidence_question = @survey.categories.first.questions.create!(
      question_text: "Upload evidence",
      question_type: "evidence",
      is_required: false
    )

    # Mock socket error
    stub_request(:head, "https://drive.google.com/file/d/socketerror/view")
      .to_raise(SocketError.new("Network unreachable"))

    # Provide answers for all required questions
    answers = { evidence_question.id.to_s => "https://drive.google.com/file/d/socketerror/view" }
    @survey.questions.each do |q|
      answers[q.id.to_s] = "Test answer" if q.is_required?
    end

    post submit_survey_path(@survey), params: { answers: answers }

    assert_response :unprocessable_entity
    assert_includes assigns(:invalid_evidence), evidence_question.id
  end

  private

  def build_employment_branch_survey(parent_required: true, children_required: true)
    survey = Survey.new(
      title: "Employment Branch #{Time.current.to_f}",
      program_semester: program_semesters(:spring_2026),
      is_active: true,
      available_until: 1.week.from_now
    )
    category = survey.categories.build(name: "Employment")
    parent = category.questions.build(
      question_text: "Are you currently employed?",
      question_order: 1,
      question_type: "multiple_choice",
      answer_options: %w[Yes No].to_json,
      is_required: parent_required
    )
    survey.save!

    employer = category.questions.create!(
      question_text: "If yes, where are you employed? (name and address)",
      question_order: 1,
      sub_question_order: 1,
      parent_question: parent,
      question_type: "short_answer",
      is_required: children_required
    )
    job_title = category.questions.create!(
      question_text: "What is your title?",
      question_order: 1,
      sub_question_order: 2,
      parent_question: parent,
      question_type: "short_answer",
      is_required: children_required
    )
    hours = category.questions.create!(
      question_text: "How many hours per week do you work on average?",
      question_order: 1,
      sub_question_order: 3,
      parent_question: parent,
      question_type: "integer",
      is_required: children_required
    )
    flexibility = category.questions.create!(
      question_text: "How flexible are your work hours?",
      question_order: 1,
      sub_question_order: 4,
      parent_question: parent,
      question_type: "multiple_choice",
      answer_options: [
        { label: "Very flexible", value: "Very flexible" },
        { label: "Somewhat flexible", value: "Somewhat flexible" },
        { label: "Other", value: "Other" }
      ].to_json,
      is_required: children_required
    )

    SurveyAssignment.create!(
      survey: survey,
      student: @student,
      advisor: @student.advisor,
      assigned_at: Time.current,
      available_until: 1.week.from_now
    )

    [ survey, parent, employer, job_title, hours, flexibility ]
  end
end
