require "test_helper"

class Admin::SurveysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin_user = users(:admin)
    @advisor_user = users(:advisor)
    @student_user = users(:student)
    @survey = surveys(:fall_2025)
    sign_in @admin_user
  end

  # === Authentication & Authorization ===

  test "requires admin role for index" do
    sign_out @admin_user
    sign_in @advisor_user

    get admin_surveys_path
    assert_redirected_to dashboard_path
  end

  test "requires admin role for new" do
    sign_out @admin_user
    sign_in @student_user

    get new_admin_survey_path
    assert_redirected_to dashboard_path
  end

  test "requires admin role for create" do
    sign_out @admin_user
    sign_in @advisor_user

    assert_no_difference "Survey.count" do
      post admin_surveys_path, params: { survey: { title: "Test", semester: "Fall 2026" } }
    end
    assert_redirected_to dashboard_path
  end

  test "requires admin role for edit" do
    sign_out @admin_user
    sign_in @advisor_user

    get edit_admin_survey_path(@survey)
    assert_redirected_to dashboard_path
  end

  test "edit form uses modal confirmation before saving" do
    get edit_admin_survey_path(@survey)

    assert_response :success
    assert_select "form[data-controller~='modal-confirm'][data-action*='submit->modal-confirm#submit']"
    assert_select "form[data-modal-confirm-title-value='Save survey changes?']"
    assert_select "form[data-modal-confirm-cancel-label-value='Go back to editing']"
  end

  test "requires admin role for update" do
    sign_out @admin_user
    sign_in @advisor_user

    patch admin_survey_path(@survey), params: { survey: { title: "Changed" } }
    assert_redirected_to dashboard_path

    @survey.reload
    refute_equal "Changed", @survey.title
  end

  test "requires admin role for destroy" do
    sign_out @admin_user
    sign_in @advisor_user

    assert_no_difference "Survey.count" do
      delete admin_survey_path(@survey)
    end
    assert_redirected_to dashboard_path
  end

  test "requires admin role for archive" do
    sign_out @admin_user
    sign_in @advisor_user

    patch archive_admin_survey_path(@survey)
    assert_redirected_to dashboard_path

    @survey.reload
    assert @survey.is_active?
  end

  test "requires admin role for activate" do
    sign_out @admin_user
    sign_in @advisor_user

    @survey.update!(is_active: false)

    patch activate_admin_survey_path(@survey)
    assert_redirected_to dashboard_path

    @survey.reload
    refute @survey.is_active?
  end

  test "requires admin role for preview" do
    sign_out @admin_user
    sign_in @advisor_user

    get preview_admin_survey_path(@survey)
    assert_redirected_to dashboard_path
  end

  test "requires admin role for copy" do
    sign_out @admin_user
    sign_in @advisor_user

    get copy_admin_survey_path(@survey)
    assert_redirected_to dashboard_path
  end

  test "requires admin role for copy_to_semester" do
    sign_out @admin_user
    sign_in @advisor_user

    assert_no_difference "Survey.count" do
      post copy_to_semester_admin_survey_path(@survey), params: {
        survey_copy: { target_program_semester_id: program_semesters(:spring_2026).id }
      }
    end

    assert_redirected_to dashboard_path
  end

  test "updating survey available_until updates existing assignments without re-running auto assignment" do
    assignment = survey_assignments(:residential_assignment)
    assert_equal @survey.id, assignment.survey_id
    assignment.update!(available_until: @survey.available_until)

    new_available_until = 10.days.from_now.to_date

    assert_no_enqueued_jobs only: ReconcileSurveyAssignmentsJob do
      patch admin_survey_path(@survey), params: { survey: { available_until: new_available_until.to_s } }
    end

    assert_redirected_to admin_surveys_path

    assignment.reload
    assert_equal new_available_until, assignment.available_until.to_date
  end

  test "updating survey available_until does not override individual assignment deadlines" do
    assignment = survey_assignments(:residential_assignment)
    assert_equal @survey.id, assignment.survey_id

    individual_deadline = 5.days.from_now.change(hour: 12, min: 0, sec: 0)
    assignment.update!(available_until: individual_deadline)

    new_available_until = 20.days.from_now.change(hour: 23, min: 59, sec: 0)

    assert_no_enqueued_jobs only: ReconcileSurveyAssignmentsJob do
      patch admin_survey_path(@survey), params: { survey: { available_until: new_available_until.to_s } }
    end

    assert_redirected_to admin_surveys_path

    assignment.reload
    assert_equal individual_deadline.to_i, assignment.available_until.to_i
  end

  test "updating survey available_until with force_deadline_for_everyone clears individual assignment deadlines" do
    assignment = survey_assignments(:residential_assignment)
    assert_equal @survey.id, assignment.survey_id

    individual_deadline = 5.days.from_now.change(hour: 12, min: 0, sec: 0)
    assignment.update!(available_until: individual_deadline)

    new_available_until = 20.days.from_now.change(hour: 23, min: 59, sec: 0)

    assert_no_enqueued_jobs only: ReconcileSurveyAssignmentsJob do
      patch admin_survey_path(@survey), params: {
        force_deadline_for_everyone: "1",
        survey: { available_until: new_available_until.to_s }
      }
    end

    assert_redirected_to admin_surveys_path
    assert_equal "Survey updated successfully. Personal assignment deadlines were cleared so everyone now follows the survey deadline, including completed responses.", flash[:notice]

    assignment.reload
    assert_nil assignment.available_until
    assert_equal new_available_until.to_i, assignment.effective_available_until.to_i
  end

  test "force_deadline_for_everyone clears individual assignment deadlines even when survey deadline is unchanged" do
    assignment = survey_assignments(:residential_assignment)
    assert_equal @survey.id, assignment.survey_id

    unchanged_available_until = @survey.available_until
    individual_deadline = 5.days.from_now.change(hour: 12, min: 0, sec: 0)
    assignment.update!(available_until: individual_deadline)

    assert_no_enqueued_jobs only: ReconcileSurveyAssignmentsJob do
      patch admin_survey_path(@survey), params: {
        force_deadline_for_everyone: "1",
        survey: { available_until: unchanged_available_until.to_s }
      }
    end

    assert_redirected_to admin_surveys_path

    assignment.reload
    assert_nil assignment.available_until
    assert_equal unchanged_available_until.to_i, assignment.effective_available_until.to_i
  end

  test "updating survey available_until updates inherited assignment when old deadline matches by date" do
    assignment = survey_assignments(:residential_assignment)
    assert_equal @survey.id, assignment.survey_id

    previous_deadline = Time.zone.local(2035, 3, 10, 23, 59)
    @survey.update!(available_until: previous_deadline)
    assignment.update!(available_until: Time.zone.local(2035, 3, 10, 9, 0))

    new_available_until = Time.zone.local(2035, 3, 30, 23, 59)

    assert_no_enqueued_jobs only: ReconcileSurveyAssignmentsJob do
      patch admin_survey_path(@survey), params: { survey: { available_until: new_available_until.to_s } }
    end

    assert_redirected_to admin_surveys_path

    assignment.reload
    assert_equal new_available_until.to_i, assignment.available_until.to_i
  end

  test "updating survey available_from updates inherited assignment when old start matches by date" do
    assignment = survey_assignments(:residential_assignment)
    assert_equal @survey.id, assignment.survey_id

    previous_available_from = Time.zone.local(2035, 3, 10, 8, 0)
    @survey.update!(available_from: previous_available_from, available_until: previous_available_from + 30.days)
    assignment.update!(available_from: Time.zone.local(2035, 3, 10, 9, 30))

    new_available_from = Time.zone.local(2035, 3, 30, 10, 15)

    patch admin_survey_path(@survey), params: { survey: { available_from: new_available_from.to_s } }

    assert_redirected_to admin_surveys_path
    assert_equal new_available_from.to_i, assignment.reload.available_from.to_i
  end

  test "updating survey available_until propagates to offerings when offerings exist" do
    offering = SurveyOffering.create!(
      survey: @survey,
      track: "Residential",
      class_of: 2026,
      stage: "final",
      available_from: 5.days.ago,
      available_until: 10.days.from_now,
      portfolio_due_date: 10.days.from_now,
      active: true
    )

    new_available_until = 20.days.from_now.change(hour: 23, min: 59, sec: 0)

    assert_no_enqueued_jobs only: ReconcileSurveyAssignmentsJob do
      patch admin_survey_path(@survey), params: { survey: { available_until: new_available_until.to_s } }
    end

    assert_redirected_to admin_surveys_path

    offering.reload
    assert_equal new_available_until.to_i, offering.available_until.to_i
    assert_equal new_available_until.to_i, offering.portfolio_due_date.to_i
  end

  test "updating survey available_until with offerings updates inherited assignment deadline by date match" do
    previous_deadline = Time.zone.local(2036, 3, 20, 11, 5)
    @survey.update!(available_until: previous_deadline)

    assignment = survey_assignments(:residential_assignment)
    assignment.update!(available_until: Time.zone.local(2036, 3, 20, 11, 3), completed_at: nil)

    SurveyOffering.create!(
      survey: @survey,
      track: "Residential",
      class_of: students(:student).program_year,
      stage: "final",
      available_from: 5.days.ago,
      available_until: previous_deadline,
      portfolio_due_date: previous_deadline,
      active: true
    )

    new_available_until = Time.zone.local(2036, 3, 20, 11, 9)

    patch admin_survey_path(@survey), params: { survey: { available_until: new_available_until.to_s } }

    assert_redirected_to admin_surveys_path
    assert_equal new_available_until.to_i, assignment.reload.available_until.to_i
  end

  test "updating survey available_from with offerings updates inherited assignment start by date match" do
    previous_available_from = Time.zone.local(2036, 3, 20, 9, 0)
    @survey.update!(available_from: previous_available_from, available_until: previous_available_from + 30.days)

    assignment = survey_assignments(:residential_assignment)
    assignment.update!(available_from: Time.zone.local(2036, 3, 20, 8, 45), completed_at: nil)

    SurveyOffering.create!(
      survey: @survey,
      track: "Residential",
      class_of: students(:student).program_year,
      stage: "final",
      available_from: previous_available_from,
      available_until: previous_available_from + 30.days,
      portfolio_due_date: previous_available_from + 30.days,
      active: true
    )

    new_available_from = Time.zone.local(2036, 3, 20, 11, 13)

    patch admin_survey_path(@survey), params: { survey: { available_from: new_available_from.to_s } }

    assert_redirected_to admin_surveys_path
    assert_equal new_available_from.to_i, assignment.reload.available_from.to_i
  end

  test "setting deadline after archive and reactivate does not recreate removed pending assignments" do
    assignment = survey_assignments(:residential_assignment)
    survey = assignment.survey
    student_id = assignment.student_id

    patch archive_admin_survey_path(survey)
    assert_redirected_to admin_surveys_path
    assert_not SurveyAssignment.exists?(id: assignment.id)

    patch activate_admin_survey_path(survey)
    assert_redirected_to admin_surveys_path
    assert survey.reload.is_active?
    assert_not SurveyAssignment.exists?(survey_id: survey.id, student_id: student_id)

    new_available_until = 14.days.from_now.to_date
    assert_no_enqueued_jobs only: ReconcileSurveyAssignmentsJob do
      patch admin_survey_path(survey), params: { survey: { available_until: new_available_until.to_s } }
    end

    assert_redirected_to admin_surveys_path
    assert_not SurveyAssignment.exists?(survey_id: survey.id, student_id: student_id)
  end

  test "update can edit review meeting dates on survey offerings" do
    offering = SurveyOffering.create!(
      survey: @survey,
      track: "Residential",
      class_of: 2026,
      stage: "final",
      review_meetings_start: Date.new(2026, 3, 21),
      review_meetings_end: Date.new(2026, 4, 17),
      active: true
    )

    patch admin_survey_path(@survey), params: {
      survey: {
        offerings_attributes: {
          "0" => {
            id: offering.id,
            review_meetings_start: "2026-03-22",
            review_meetings_end: "2026-04-18"
          }
        }
      }
    }

    assert_redirected_to admin_surveys_path

    offering.reload
    assert_equal Date.new(2026, 3, 22), offering.review_meetings_start
    assert_equal Date.new(2026, 4, 18), offering.review_meetings_end
  end

  test "warns when target levels change for surveys with submitted students" do
    completed_assignment = survey_assignments(:completed_residential_assignment)
    assert_equal @survey.id, completed_assignment.survey_id
    assert completed_assignment.completed_at?

    question = questions(:fall_q1)
    category = categories(:clinical_skills)
    assert_equal @survey.id, category.survey_id
    assert_equal category.id, question.category_id

    patch admin_survey_path(@survey), params: {
      survey: {
        categories_attributes: {
          "0" => {
            id: category.id,
            questions_attributes: {
              "0" => { id: question.id, program_target_level: "3" }
            }
          }
        }
      }
    }

    assert_redirected_to admin_surveys_path
    assert flash[:warning].present?
    assert_match(/Target levels changed/i, flash[:warning].to_s)
  end

  test "does not warn when target levels change but no one has submitted" do
    SurveyAssignment.where(survey_id: @survey.id).update_all(completed_at: nil)

    question = questions(:fall_q1)
    category = categories(:clinical_skills)

    patch admin_survey_path(@survey), params: {
      survey: {
        categories_attributes: {
          "0" => {
            id: category.id,
            questions_attributes: {
              "0" => { id: question.id, program_target_level: "4" }
            }
          }
        }
      }
    }

    assert_redirected_to admin_surveys_path
    assert flash[:warning].blank?
  end

  test "updating one question target level does not change sibling question target level" do
    category = categories(:clinical_skills)
    primary_question = questions(:fall_q1)
    sibling_question = category.questions.create!(
      question_text: "Sibling target-level question",
      question_type: "short_answer",
      question_order: category.questions.maximum(:question_order).to_i + 1,
      program_target_level: 2
    )

    patch admin_survey_path(@survey), params: {
      survey: {
        categories_attributes: {
          "0" => {
            id: category.id,
            questions_attributes: {
              "0" => { id: primary_question.id, program_target_level: "5" },
              "1" => { id: sibling_question.id, program_target_level: sibling_question.program_target_level.to_s }
            }
          }
        }
      }
    }

    assert_redirected_to admin_surveys_path

    primary_question.reload
    sibling_question.reload

    assert_equal 5, primary_question.program_target_level
    assert_equal 2, sibling_question.program_target_level
  end

  test "autosave update logs nested payload counts in development" do
    category = categories(:clinical_skills)
    question = questions(:fall_q1)
    section = @survey.sections.create!(title: "Autosave section", position: 1)
    env = ActiveSupport::StringInquirer.new("development")

    Rails.stub(:env, env) do
      assert_no_enqueued_jobs only: ReconcileSurveyAssignmentsJob do
        patch admin_survey_path(@survey), params: {
          autosave: "1",
          survey: {
            title: @survey.title,
            sections_attributes: {
              "0" => {
                id: section.id,
                title: section.title,
                position: section.position,
                form_uid: "section-#{section.id}"
              }
            },
            categories_attributes: {
              "0" => {
                id: category.id,
                name: category.name,
                section_form_uid: "section-#{section.id}",
                questions_attributes: {
                  "0" => {
                    id: question.id,
                    question_text: question.question_text,
                    question_type: question.question_type,
                    question_order: question.question_order
                  }
                }
              }
            }
          }
        }
      end
    end

    assert_redirected_to admin_surveys_path
    assert_equal section.id, category.reload.survey_section_id
  end

  test "autosave update re-renders edit with validation errors in development" do
    env = ActiveSupport::StringInquirer.new("development")

    Rails.stub(:env, env) do
      patch admin_survey_path(@survey), params: {
        autosave: "1",
        survey: { title: "" }
      }
    end

    assert_response :unprocessable_entity
    assert_select "form"
  end

  test "updating competency question target level mirrors to competency target levels" do
    @survey.assign_tracks!([ "Residential" ])

    category = categories(:clinical_skills)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    question = category.questions.create!(
      question_text: competency_title,
      question_type: "short_answer",
      question_order: category.questions.maximum(:question_order).to_i + 1,
      program_target_level: 2
    )

    patch admin_survey_path(@survey), params: {
      survey: {
        categories_attributes: {
          "0" => {
            id: category.id,
            questions_attributes: {
              "0" => { id: question.id, program_target_level: "4" }
            }
          }
        }
      }
    }

    assert_redirected_to admin_surveys_path

    mirrored = CompetencyTargetLevel.find_by(
      program_semester_id: @survey.program_semester_id,
      track: "Residential",
      class_of: nil,
      competency_title: competency_title
    )

    assert_not_nil mirrored
    assert_equal 4, mirrored.target_level
  end

  test "update can add a section when new section position submits blank" do
    assert_difference "SurveySection.count", 1 do
      patch admin_survey_path(@survey), params: {
        survey: {
          sections_attributes: {
            "0" => {
              title: "New section",
              description: "",
              position: "",
              form_uid: "section-temp-test"
            }
          }
        }
      }
    end

    assert_redirected_to admin_surveys_path

    @survey.reload
    new_section = @survey.sections.find_by(title: "New section")
    assert new_section.present?
    assert new_section.position.is_a?(Integer)
  end

  test "update can add a new category with a question and preview shows it" do
    category_name = "Added category"
    question_text = "Added question text"

    assert_difference [ "Category.count", "Question.count" ], 1 do
      patch admin_survey_path(@survey), params: {
        survey: {
          categories_attributes: {
            "0" => {
              name: category_name,
              description: "",
              section_form_uid: "",
              questions_attributes: {
                "0" => {
                  question_text: question_text,
                  question_type: "short_answer",
                  question_order: 1,
                  is_required: false,
                  has_evidence_field: false
                }
              }
            }
          }
        }
      }
    end

    assert_redirected_to admin_surveys_path

    get preview_admin_survey_path(@survey)
    assert_response :success
    assert_includes response.body, category_name
    assert_includes response.body, question_text
  end

  test "update can add a new section and assign a new category to it; preview shows both" do
    section_uid = "section-temp-test-123"
    section_title = "Added section"
    category_name = "Added category in section"
    question_text = "Added question in section"

    assert_difference [ "SurveySection.count", "Category.count", "Question.count" ], 1 do
      patch admin_survey_path(@survey), params: {
        survey: {
          sections_attributes: {
            "0" => {
              title: section_title,
              description: "",
              position: "",
              form_uid: section_uid
            }
          },
          categories_attributes: {
            "0" => {
              name: category_name,
              description: "",
              section_form_uid: section_uid,
              questions_attributes: {
                "0" => {
                  question_text: question_text,
                  question_type: "short_answer",
                  question_order: 1,
                  is_required: false,
                  has_evidence_field: false
                }
              }
            }
          }
        }
      }
    end

    assert_redirected_to admin_surveys_path

    get preview_admin_survey_path(@survey)
    assert_response :success
    assert_includes response.body, section_title
    assert_includes response.body, category_name
    assert_includes response.body, question_text
  end

  # === Index Action ===

  test "index displays surveys successfully" do
    get admin_surveys_path
    assert_response :success
  end

  test "index opens copy workflow in an inline modal" do
    get admin_surveys_path

    assert_response :success
    assert_select "a[href=?][data-open-modal=?][data-turbo='false']", copy_admin_survey_path(@survey), "copy-survey-modal-#{@survey.id}", text: "Copy"
    assert_select "div#copy-survey-modal-#{@survey.id} form[action=?]", copy_to_semester_admin_survey_path(@survey)
    assert_select "div#copy-survey-modal-#{@survey.id} form[data-turbo='false']"
    assert_select "div#copy-survey-modal-#{@survey.id} select[name='survey_copy[target_program_semester_id]']"
  end

  test "index with search query" do
    get admin_surveys_path, params: { q: "Fall" }
    assert_response :success
  end

  test "index with track filter" do
    @survey.assign_tracks!([ "Residential" ])

    get admin_surveys_path, params: { track: "Residential" }
    assert_response :success
  end

  test "index with unassigned track filter" do
    @survey.assign_tracks!([])

    get admin_surveys_path, params: { track: "__unassigned" }
    assert_response :success
  end

  test "index with sort parameter" do
    get admin_surveys_path, params: { sort: "title", direction: "asc" }
    assert_response :success
  end

  test "index with invalid sort defaults gracefully" do
    get admin_surveys_path, params: { sort: "invalid_column" }
    assert_response :success
  end

  test "index shows available and due date columns for active surveys" do
    available_from = Time.zone.local(2036, 3, 1, 9, 0)
    available_until = Time.zone.local(2036, 3, 31, 23, 59)
    @survey.update!(available_from: available_from, available_until: available_until)

    get admin_surveys_path
    assert_response :success

    assert_includes response.body, "Available Date"
    assert_includes response.body, "Due Date"
    assert_includes response.body, "March 1, 2036"
    assert_includes response.body, "March 31, 2036"
  end

  test "index shows no due date label for archived surveys" do
    @survey.update!(is_active: false, available_until: nil)

    get admin_surveys_path
    assert_response :success
    assert_includes response.body, "No due date"
  end

  test "index with desc direction" do
    get admin_surveys_path, params: { direction: "desc" }
    assert_response :success
  end

  test "index sorts by question_count" do
    get admin_surveys_path, params: { sort: "question_count", direction: "desc" }
    assert_response :success
  end

  test "index sorts by category_count" do
    get admin_surveys_path, params: { sort: "category_count", direction: "asc" }
    assert_response :success
  end

  test "search handles special characters" do
    get admin_surveys_path, params: { q: "Fall & Spring" }
    assert_response :success
  end

  test "search is case insensitive" do
    get admin_surveys_path, params: { q: "FALL" }
    assert_response :success
  end

  test "search matches title, semester, and description" do
    @survey.update!(description: "Unique search term xyz123")

    get admin_surveys_path, params: { q: "xyz123" }
    assert_response :success
  end

  # === New Action ===

  test "new renders form successfully" do
    get new_admin_survey_path
    assert_response :success
  end

  test "new with current program semester" do
    ProgramSemester.find_by(current: true)&.update(name: "Spring 2027")

    get new_admin_survey_path
    assert_response :success
  end

  test "new with no current program semester falls back to calculated" do
    ProgramSemester.destroy_all

    get new_admin_survey_path
    assert_response :success
  end

  # === Create Action ===

  test "creates survey with tracks and logs change" do
    params = {
      survey: {
        title: "Capstone Survey",
        description: "Capstone overview",
        semester: "Fall 2026",
        is_active: true,
        track_list: [ "Residential" ],
        categories_attributes: {
          "0" => {
            name: "Leadership",
            description: "Leadership competencies",
            questions_attributes: {
              "0" => {
                question_text: "Describe your leadership style",
                question_type: "short_answer",
                question_order: 1,
                is_required: true,
                has_evidence_field: false,
                answer_options: ""
              }
            }
          }
        }
      }
    }

    assert_difference [ "Survey.count", "SurveyTrackAssignment.count", "SurveyChangeLog.count" ] do
      post admin_surveys_path, params: params
    end

    assert_redirected_to admin_surveys_path

    survey = Survey.order(:created_at).last
    assert_equal "Capstone Survey", survey.title
    assert_equal [ "Residential" ], survey.track_list
    assert_equal 1, survey.categories.count
    assert_equal 1, survey.questions.count

    log = SurveyChangeLog.order(:created_at).last
    assert_equal "create", log.action
    assert_equal survey, log.survey
    assert_equal @admin_user, log.admin
    assert_equal "Survey created with 1 track(s)", log.description
  end

  test "create with multiple tracks" do
    params = {
      survey: {
        title: "Multi-track Survey",
        semester: "Fall 2026",
        track_list: [ "Residential", "Executive" ],
        categories_attributes: {
          "0" => {
            name: "Category",
            questions_attributes: {
              "0" => { question_text: "Q1", question_type: "short_answer", question_order: 1 }
            }
          }
        }
      }
    }

    assert_difference "Survey.count" do
      post admin_surveys_path, params: params
    end

    survey = Survey.order(:created_at).last
    assert_equal [ "Executive", "Residential" ], survey.track_list.sort
  end

  test "create sets creator to current admin" do
    params = {
      survey: {
        title: "Creator Test",
        semester: "Fall 2026",
        categories_attributes: {
          "0" => {
            name: "Cat",
            questions_attributes: {
              "0" => { question_text: "Q", question_type: "short_answer", question_order: 1 }
            }
          }
        }
      }
    }

    post admin_surveys_path, params: params

    survey = Survey.order(:created_at).last
    assert_equal @admin_user, survey.creator
  end

  test "create allows tooltip text" do
    params = {
      survey: {
        title: "Tooltip Survey",
        semester: "Fall 2026",
        categories_attributes: {
          "0" => {
            name: "Leadership",
            questions_attributes: {
              "0" => {
                question_text: "Describe a recent win",
                question_type: "short_answer",
                question_order: 1,
                tooltip_text: "Connect your answer to STAR outcomes."
              }
            }
          }
        }
      }
    }

    assert_difference "Survey.count", 1 do
      post admin_surveys_path, params: params
    end

    survey = Survey.order(:created_at).last
    tooltip = survey.questions.first.tooltip_text
    assert_equal "Connect your answer to STAR outcomes.", tooltip
  end

  test "create supports sections with category assignments" do
    section_uid = "section-temp-test"
    params = {
      survey: {
        title: "Sectioned Survey",
        semester: "Fall 2026",
        sections_attributes: {
          "0" => {
            title: "Student Experience",
            description: "Covers advising touchpoints",
            position: 0,
            form_uid: section_uid
          }
        },
        categories_attributes: {
          "0" => {
            name: "Touchpoints",
            description: "Advising interactions",
            section_form_uid: section_uid,
            questions_attributes: {
              "0" => {
                question_text: "List recent meetings",
                question_type: "short_answer",
                question_order: 1
              }
            }
          }
        }
      }
    }

    assert_difference [ "Survey.count", "SurveySection.count" ], 1 do
      post admin_surveys_path, params: params
    end

    survey = Survey.order(:created_at).last
    section = survey.sections.first
    category = survey.categories.first

    assert_equal "Student Experience", section.title
    assert_equal section, category.section
  end

  test "create with invalid params renders new with errors" do
    params = {
      survey: {
        title: "",
        semester: "Fall 2026"
      }
    }

    assert_no_difference "Survey.count" do
      post admin_surveys_path, params: params
    end

    assert_response :unprocessable_entity
  end

  test "create with nested categories and questions" do
    params = {
      survey: {
        title: "Nested Survey",
        semester: "Fall 2026",
        categories_attributes: {
          "0" => {
            name: "Cat1",
            questions_attributes: {
              "0" => { question_text: "Q1", question_type: "short_answer", question_order: 1 },
              "1" => { question_text: "Q2", question_type: "evidence", question_order: 2 }
            }
          },
          "1" => {
            name: "Cat2",
            questions_attributes: {
              "0" => { question_text: "Q3", question_type: "multiple_choice", question_order: 1, answer_options: "Yes\nNo" }
            }
          }
        }
      }
    }

    assert_difference "Survey.count" do
      post admin_surveys_path, params: params
    end

    survey = Survey.order(:created_at).last
    assert_equal 2, survey.categories.count
    assert_equal 3, survey.questions.count
  end

  test "create without categories fails validation" do
    params = {
      survey: {
        title: "No Categories",
        semester: "Fall 2026",
        categories_attributes: {}
      }
    }

    assert_no_difference "Survey.count" do
      post admin_surveys_path, params: params
    end

    assert_response :unprocessable_entity
  end

  # === Edit Action ===

  test "edit renders form successfully" do
    get edit_admin_survey_path(@survey)
    assert_response :success
  end

  test "edit with survey that has no categories builds default" do
    # Create survey with at least one category to pass validation
    survey = Survey.new(title: "Empty Survey", semester: "Fall 2026", creator: @admin_user)
    category = survey.categories.build(name: "Initial Category")
    category.questions.build(question_text: "Q", question_type: "short_answer", question_order: 1)
    survey.save!

    # Remove categories to test the build_default_structure behavior
    survey.categories.destroy_all

    get edit_admin_survey_path(survey)
    assert_response :success
  end

  # === Update Action ===

  test "updates survey and records change summary" do
    survey = surveys(:fall_2025)

    assert_difference "SurveyChangeLog.count" do
      patch admin_survey_path(survey), params: {
        survey: {
          title: "Updated Survey Title",
          description: "Updated details",
          track_list: [ "Executive" ]
        }
      }
    end

    assert_redirected_to admin_surveys_path

    survey.reload
    assert_equal "Updated Survey Title", survey.title
    assert_equal [ "Executive" ], survey.track_list

    log = SurveyChangeLog.order(:created_at).last
    assert_equal "update", log.action
    assert_equal survey, log.survey
    assert_equal @admin_user, log.admin
    assert_includes log.description, "Tracks updated to Executive"
    assert_includes log.description, "Title changed from"
  end

  test "update with semester change" do
    assert_difference "SurveyChangeLog.count" do
      patch admin_survey_path(@survey), params: {
        survey: { semester: "Spring 2027" }
      }
    end

    @survey.reload
    assert_equal "Spring 2027", @survey.semester

    log = SurveyChangeLog.order(:created_at).last
    assert_includes log.description, "Semester changed from"
  end

  test "update allows reassigning categories to new sections" do
    category = @survey.categories.first
    existing_section = @survey.sections.create!(title: "Existing", description: "", position: 0)
    section_uid = "section-#{existing_section.id}"
    new_section_uid = "section-temp-xyz"

    patch admin_survey_path(@survey), params: {
      survey: {
        title: @survey.title,
        sections_attributes: {
          "0" => {
            id: existing_section.id,
            title: existing_section.title,
            description: existing_section.description,
            position: existing_section.position,
            form_uid: section_uid
          },
          "1" => {
            title: "Advisor Touchpoints",
            description: "",
            position: existing_section.position + 1,
            form_uid: new_section_uid
          }
        },
        categories_attributes: {
          "0" => {
            id: category.id,
            name: category.name,
            description: category.description,
            section_form_uid: new_section_uid
          }
        }
      }
    }

    assert_redirected_to admin_surveys_path

    category.reload
    assert_equal "Advisor Touchpoints", category.section.title
  end

  test "update allows editing tooltip text" do
    category = @survey.categories.first
    question = category.questions.first

    patch admin_survey_path(@survey), params: {
      survey: {
        categories_attributes: {
          "0" => {
            id: category.id,
            questions_attributes: {
              "0" => {
                id: question.id,
                tooltip_text: "Use concise bullet points"
              }
            }
          }
        }
      }
    }

    assert_redirected_to admin_surveys_path

    question.reload
    assert_equal "Use concise bullet points", question.tooltip_text
  end

  test "update with description change" do
    assert_difference "SurveyChangeLog.count" do
      patch admin_survey_path(@survey), params: {
        survey: { description: "New description text" }
      }
    end

    @survey.reload
    assert_equal "New description text", @survey.description

    log = SurveyChangeLog.order(:created_at).last
    assert_includes log.description, "Description changed from"
  end

  test "update with is_active change" do
    @survey.update!(is_active: true)

    assert_difference "SurveyChangeLog.count" do
      patch admin_survey_path(@survey), params: {
        survey: { is_active: false }
      }
    end

    @survey.reload
    refute @survey.is_active?

    log = SurveyChangeLog.order(:created_at).last
    assert_includes log.description, "Is active changed from"
  end

  test "update persists competency display settings" do
    patch admin_survey_path(@survey), params: {
      survey: {
        show_course_competencies_with_survey: "1",
        advisor_numeric_feedback_enabled: "1"
      }
    }

    assert_redirected_to admin_surveys_path
    @survey.reload
    assert @survey.show_course_competencies_with_survey?
    assert @survey.advisor_numeric_feedback_enabled?
  end

  test "update can add new category" do
    original_count = @survey.categories.count

    patch admin_survey_path(@survey), params: {
      survey: {
        categories_attributes: {
          "0" => {
            id: @survey.categories.first.id,
            name: @survey.categories.first.name
          },
          "1" => {
            name: "New Category",
            questions_attributes: {
              "0" => { question_text: "New Q", question_type: "short_answer", question_order: 1 }
            }
          }
        }
      }
    }

    @survey.reload
    assert_equal original_count + 1, @survey.categories.count
  end

  test "update can remove category" do
    category = @survey.categories.create!(name: "To Remove")
    category.questions.create!(question_text: "Q", question_type: "short_answer", question_order: 1)

    original_count = @survey.categories.count

    patch admin_survey_path(@survey), params: {
      survey: {
        categories_attributes: {
          "0" => {
            id: category.id,
            _destroy: "1"
          }
        }
      }
    }

    @survey.reload
    assert_equal original_count - 1, @survey.categories.count
  end

  test "update with invalid params renders edit with errors" do
    patch admin_survey_path(@survey), params: {
      survey: { title: "" }
    }

    assert_response :unprocessable_entity

    @survey.reload
    refute_equal "", @survey.title
  end

  # === Copy Action ===

  test "copy renders target semester form" do
    get copy_admin_survey_path(@survey)

    assert_response :success
    assert_select "h1", "Copy Survey"
    assert_select "select[name='survey_copy[target_program_semester_id]']"
    assert_includes response.body, "No students will be assigned"
  end

  test "copy_to_semester copies survey definition without assigning students" do
    target_semester = program_semesters(:spring_2026)
    section = @survey.sections.create!(title: "Competency Block", description: "Self-assessment prompts", position: 0)
    category = @survey.categories.first
    category.update!(section: section)
    parent_question = category.questions.first
    parent_question.update!(
      tooltip_text: "Use your best evidence.",
      has_feedback: true,
      program_target_level: 3,
      is_required: true,
      answer_options: [
        { label: "Yes", value: "Yes" },
        { label: "No", value: "No" },
        { label: "Other - please describe", value: "Other", requires_text: true }
      ].to_json,
      configuration: { "prompt_format" => "rich_text", "integer_min" => "1", "integer_max" => "5" }
    )

    if Question.sub_question_columns_supported?
      category.questions.create!(
        question_text: "Describe the evidence behind that rating",
        question_type: "short_answer",
        question_order: parent_question.question_order,
        parent_question: parent_question,
        sub_question_order: 1,
        is_required: true
      )
    end

    @survey.create_legend!(title: "Rating guide", body: "Use the program competency scale.")
    @survey.offerings.create!(
      track: "Residential",
      class_of: 2027,
      stage: "initial",
      assignment_group: "A",
      available_from: 3.days.from_now,
      available_until: 30.days.from_now,
      review_meetings_start: Date.current + 10.days,
      review_meetings_end: Date.current + 20.days,
      portfolio_due_date: 30.days.from_now
    )

    source_section_count = @survey.sections.count
    source_category_count = @survey.categories.count
    source_question_count = @survey.questions.count
    source_offering_count = @survey.offerings.count

    assert_difference "Survey.count", 1 do
      assert_difference "SurveySection.count", source_section_count do
        assert_difference "Category.count", source_category_count do
          assert_difference "Question.count", source_question_count do
            assert_difference "SurveyLegend.count", 1 do
              assert_difference "SurveyOffering.count", source_offering_count do
                assert_difference "SurveyChangeLog.count", 1 do
                  assert_no_difference "SurveyAssignment.count" do
                    post copy_to_semester_admin_survey_path(@survey), params: {
                      survey_copy: { target_program_semester_id: target_semester.id }
                    }
                  end
                end
              end
            end
          end
        end
      end
    end

    copied_survey = Survey.find_by!(title: @survey.title, program_semester: target_semester)
    assert_redirected_to edit_admin_survey_path(copied_survey)
    assert_equal @admin_user, copied_survey.creator
    assert_equal @survey.description, copied_survey.description
    assert_equal @survey.track_list.sort, copied_survey.track_list.sort
    assert_empty copied_survey.survey_assignments
    assert_equal source_section_count, copied_survey.sections.count
    assert_equal source_category_count, copied_survey.categories.count
    assert_equal source_question_count, copied_survey.questions.count
    assert_equal source_offering_count, copied_survey.offerings.count
    assert_equal "Rating guide", copied_survey.legend.title
    assert_equal "Use the program competency scale.", copied_survey.legend.body

    copied_category = copied_survey.categories.find_by!(name: category.name)
    assert_equal "Competency Block", copied_category.section.title

    copied_parent = copied_category.questions.find_by!(question_text: parent_question.question_text)
    assert_equal "Use your best evidence.", copied_parent.tooltip_text
    assert_equal 3, copied_parent.program_target_level
    assert_equal "rich_text", copied_parent.prompt_format
    assert copied_parent.is_required?
    assert_equal parent_question.answer_option_definitions, copied_parent.answer_option_definitions

    if Question.sub_question_columns_supported?
      copied_child = copied_category.questions.find_by!(question_text: "Describe the evidence behind that rating")
      assert_equal copied_parent.id, copied_child.parent_question_id
      assert_equal 1, copied_child.sub_question_order
      assert copied_child.is_required?
    end

    log = SurveyChangeLog.order(:created_at).last
    assert_equal "copy", log.action
    assert_equal copied_survey, log.survey
    assert_includes log.description, @survey.title
    assert_includes log.description, "without assigning students"
  end

  test "copy_to_semester rejects same semester" do
    assert_no_difference "Survey.count" do
      post copy_to_semester_admin_survey_path(@survey), params: {
        survey_copy: { target_program_semester_id: @survey.program_semester_id }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Choose a different semester"
  end

  # === Destroy Action ===

  test "destroy deletes survey and logs change" do
    survey = surveys(:spring_2025)

    # Logs change first, then destroys survey (change log remains via nullify)
    assert_difference "Survey.count", -1 do
      assert_difference "SurveyChangeLog.count", 1 do
        delete admin_survey_path(survey)
      end
    end

    assert_redirected_to admin_surveys_path

    log = SurveyChangeLog.order(:created_at).last
    assert_equal "delete", log.action
    assert_includes log.description, "Spring 2025"
  end

  test "destroy removes survey response versions before deleting" do
    survey = surveys(:spring_2025)
    assignment = SurveyAssignment.create!(
      survey: survey,
      student: students(:student),
      advisor: advisors(:advisor),
      assigned_at: Time.current
    )
    version = SurveyResponseVersion.create!(
      student: students(:student),
      survey: survey,
      survey_assignment: assignment,
      event: "submitted",
      answers: {}
    )

    assert_difference "Survey.count", -1 do
      assert_difference "SurveyResponseVersion.count", -1 do
        delete admin_survey_path(survey)
      end
    end

    assert_redirected_to admin_surveys_path
    assert_not SurveyResponseVersion.exists?(version.id)
  end

  # === Archive Action ===

  test "archives survey and preserves track assignments" do
    assert @survey.is_active?
    assert @survey.track_list.any?
    @survey.update!(available_until: 14.days.from_now)

    prior_assignment_count = SurveyTrackAssignment.count
    prior_tracks = @survey.track_list.sort

    assert_difference "SurveyChangeLog.count" do
      patch archive_admin_survey_path(@survey)
    end

    assert_redirected_to admin_surveys_path

    @survey.reload
    refute @survey.is_active?
    assert_nil @survey.available_until
    assert_equal prior_tracks, @survey.track_list.sort
    assert_equal prior_assignment_count, SurveyTrackAssignment.count
    assert_equal prior_tracks, SurveyTrackAssignment.where(survey: @survey).pluck(:track).sort

    log = SurveyChangeLog.order(:created_at).last
    assert_equal "archive", log.action
    assert_equal @survey, log.survey
  end

  test "archive survey that is already archived" do
    @survey.update!(is_active: false)

    patch archive_admin_survey_path(@survey)

    assert_redirected_to admin_surveys_path
    @survey.reload
    refute @survey.is_active?
  end

  test "archive removes incomplete assignments and preserves existing responses" do
    incomplete_assignment = survey_assignments(:residential_assignment)
    completed_assignment = survey_assignments(:completed_residential_assignment)
    question = questions(:fall_q1)
    @survey.update!(available_until: 20.days.from_now)

    assert_nil incomplete_assignment.completed_at
    assert_not_nil completed_assignment.completed_at
    assert StudentQuestion.exists?(student_id: incomplete_assignment.student_id, question_id: question.id)
    assert StudentQuestion.exists?(student_id: completed_assignment.student_id, question_id: question.id)

    patch archive_admin_survey_path(@survey)

    assert_redirected_to admin_surveys_path
    @survey.reload
    assert_nil @survey.available_until
    refute SurveyAssignment.exists?(incomplete_assignment.id)
    assert StudentQuestion.exists?(student_id: incomplete_assignment.student_id, question_id: question.id)
    assert SurveyAssignment.exists?(completed_assignment.id)
    assert_nil completed_assignment.reload.available_until
    assert StudentQuestion.exists?(student_id: completed_assignment.student_id, question_id: question.id)
  end

  # === Activate Action ===

  test "activates survey and logs change" do
    survey = surveys(:fall_2025)
    survey.update!(is_active: false)

    assert_difference "SurveyChangeLog.count" do
      patch activate_admin_survey_path(survey)
    end

    assert_redirected_to admin_surveys_path

    survey.reload
    assert survey.is_active?

    log = SurveyChangeLog.order(:created_at).last
    assert_equal "activate", log.action
    assert_equal survey, log.survey
  end

  test "activate survey that is already active" do
    @survey.update!(is_active: true)

    patch activate_admin_survey_path(@survey)

    assert_redirected_to admin_surveys_path
    @survey.reload
    assert @survey.is_active?
  end

  # === Preview Action ===

  test "preview renders successfully without logging" do
    assert_no_difference "SurveyChangeLog.count" do
      get preview_admin_survey_path(@survey)
    end

    assert_response :success
    assert_select "form[data-preview-survey-form='true'][data-survey-shared-submit='true']"
    assert_select "input[type='submit'][value='Submit Preview']"
    assert_includes response.body, "No responses are saved"
    assert_includes response.body, "installPreviewForms"
    assert_includes response.body, "installSurveySubmissionForms"
    assert_includes response.body, "Preview needs attention"
  end

  test "preview with categories and questions" do
    get preview_admin_survey_path(@survey)
    assert_response :success
  end

  test "preview with required questions" do
    question = @survey.questions.first
    question.update!(is_required: true)

    get preview_admin_survey_path(@survey)
    assert_response :success
  end

  test "preview with multiple choice questions" do
    category = @survey.categories.first || @survey.categories.create!(name: "Test")
    category.questions.create!(
      question_text: "Choose one",
      question_type: "multiple_choice",
      answer_options: "Yes\nNo",
      question_order: 1,
      is_required: false
    )

    get preview_admin_survey_path(@survey)
    assert_response :success
  end

  test "preview wires employment branch children for interactive reveal" do
    category = @survey.categories.first || @survey.categories.create!(name: "Employment")
    parent = category.questions.create!(
      question_text: "Are you currently employed?",
      question_type: "multiple_choice",
      answer_options: %w[Yes No].to_json,
      question_order: 900,
      is_required: true
    )
    child = category.questions.create!(
      question_text: "If yes, where are you employed? (name and address)",
      question_type: "short_answer",
      question_order: 900,
      parent_question: parent,
      sub_question_order: 1,
      is_required: true
    )

    get preview_admin_survey_path(@survey)

    assert_response :success
    assert_select "form[data-preview-survey-form='true'].survey-form"
    assert_select "article#question-block-#{parent.id}[data-branch-parent='true'][data-branch-parent-id='#{parent.id}'][data-branch-target-value='Yes'][data-preview-required='true']"
    assert_select "article#question-block-#{child.id}[data-branch-child-of='#{parent.id}'][data-preview-required='true'].hidden[aria-hidden='true']"
    assert_select "article#question-block-#{child.id} .u-danger", text: "*"
    assert_includes response.body, "TamuCatSurveyBehavior"
  end

  test "preview wires other text choice for interactive reveal" do
    category = @survey.categories.first || @survey.categories.create!(name: "Employment")
    parent = category.questions.create!(
      question_text: "Are you currently employed?",
      question_type: "multiple_choice",
      answer_options: %w[Yes No].to_json,
      question_order: 901,
      is_required: false
    )
    question = category.questions.create!(
      question_text: "How flexible are your work hours?",
      question_type: "dropdown",
      answer_options: [
        { label: "Very flexible", value: "very_flexible" },
        { label: "Other — Please describe the flexibility of your work schedule.", value: "other", requires_text: true }
      ].to_json,
      question_order: 901,
      parent_question: parent,
      sub_question_order: 1,
      is_required: false
    )

    get preview_admin_survey_path(@survey)

    assert_response :success
    assert_select "article#question-block-#{question.id}[data-branch-child-of='#{parent.id}'].hidden[aria-hidden='true']"
    assert_select "div[data-other-input-wrapper][data-other-for-question-id='#{question.id}'][data-other-choice-value='other'].hidden[aria-hidden='true']"
    assert_select "input[name='other_answers[#{question.id}]'][disabled]"
    assert_includes response.body, "syncOtherInputs"
  end

  test "preview wires reflection questions to assessment dropdown visibility" do
    category = @survey.categories.first || @survey.categories.create!(name: "Reflection")
    assessment = category.questions.create!(
      question_text: "Communication",
      question_type: "dropdown",
      answer_options: [ [ "Beginner (1)", "1" ], [ "Capable (3)", "3" ] ].to_json,
      question_order: 902,
      is_required: true
    )
    reflection = category.questions.create!(
      question_text: "Communication Reflection",
      question_type: "short_answer",
      question_order: 902,
      parent_question: assessment,
      sub_question_order: 1,
      is_required: false
    )

    get preview_admin_survey_path(@survey)

    assert_response :success
    assert_select "article#question-block-#{reflection.id}[data-reflection-question='true'][data-reflection-source-id='#{assessment.id}'][data-preview-required='false'].hidden[aria-hidden='true']"
    assert_select "article#question-block-#{reflection.id} .u-danger", text: "*", count: 0
    assert_includes response.body, "syncReflectionQuestions"
  end

  test "preview marks evidence questions for submit validation" do
    category = @survey.categories.first || @survey.categories.create!(name: "Evidence")
    evidence = category.questions.create!(
      question_text: "Portfolio evidence",
      question_type: "evidence",
      question_order: 903,
      is_required: true
    )

    get preview_admin_survey_path(@survey)

    assert_response :success
    assert_select "form[data-preview-survey-form='true'] article#question-block-#{evidence.id}[data-question-type='evidence'][data-preview-required='true']"
    assert_select "input[name='answers[#{evidence.id}]'][placeholder='https://sites.google.com/tamu.edu/...']"
    assert_includes response.body, "previewEvidenceError"
    assert_includes response.body, "/evidence/check_access"
    assert_includes response.body, "https://sites.google.com/"
  end

  test "preview with flexibility scale questions" do
    category = @survey.categories.first || @survey.categories.create!(name: "Test")
    category.questions.create!(
      question_text: "How flexible are you?",
      question_type: "multiple_choice",
      answer_options: "1\n2\n3\n4\n5",
      question_order: 1,
      is_required: false
    )

    get preview_admin_survey_path(@survey)
    assert_response :success
  end

  test "preview with track assignments" do
    @survey.assign_tracks!([ "Residential" ])

    get preview_admin_survey_path(@survey)
    assert_response :success
  end
end
