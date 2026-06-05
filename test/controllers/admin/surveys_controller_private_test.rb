require "test_helper"

class Admin::SurveysControllerPrivateTest < ActionController::TestCase
  tests Admin::SurveysController

  setup do
    @admin = users(:admin)
    @survey = surveys(:fall_2025)
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in @admin
    @controller.instance_variable_set(:@survey, @survey)
  end

  test "semester grouping sorts named semesters and unscheduled fallbacks" do
    spring = OpenStruct.new(
      title: "Spring grouping survey",
      semester: "Spring 2026",
      program_semester: nil,
      updated_at: Time.current
    )
    unscheduled = OpenStruct.new(
      title: "Unscheduled grouping survey",
      semester: "",
      program_semester: nil,
      updated_at: nil
    )
    grouped = @controller.send(:surveys_grouped_by_semester, [ @survey, spring, unscheduled ])

    assert_equal "Spring 2026", grouped.first.first
    assert_includes grouped.map(&:first), "Unscheduled"
    assert_equal [ -2026, -1, "Spring 2026" ], @controller.send(:semester_group_sort_key, "Spring 2026", spring)
    assert_equal [ 0, "No Date" ], @controller.send(:semester_group_sort_key, "No Date", nil)
  end

  test "default semester calendar fallback covers seasons" do
    ProgramSemester.stub(:current_name, nil) do
      travel_to Date.new(2026, 2, 1) do
        assert_equal "Spring 2026", @controller.send(:calculated_semester_from_calendar)
      end
      travel_to Date.new(2026, 6, 1) do
        assert_equal "Summer 2026", @controller.send(:calculated_semester_from_calendar)
      end
      travel_to Date.new(2026, 10, 1) do
        assert_equal "Fall 2026", @controller.send(:calculated_semester_from_calendar)
      end
    end
  end

  test "survey change formatting covers blank time boolean and invalid time values" do
    assert_equal "not set", @controller.send(:survey_change_value, :title, "")
    assert_equal "active", @controller.send(:survey_change_value, :is_active, "1")
    assert_equal "archived", @controller.send(:survey_change_value, :is_active, "0")
    assert_equal "not-a-time", @controller.send(:survey_change_value, :available_until, "not-a-time")
    assert_equal "Open date", @controller.send(:survey_change_label, :available_from)
    assert_equal "Custom field", @controller.send(:survey_change_label, :custom_field)

    snapshot = @controller.send(:survey_snapshot, @survey)
    changed = snapshot.merge(title: "Changed title", is_active: false, categories: [ { name: "Only", question_count: 99 } ])
    summary = @controller.send(:change_summary, snapshot, changed, [ "executive" ])

    assert_includes summary, "Title changed"
    assert_includes summary, "Is active changed"
    assert_includes summary, "Tracks updated"
    assert_includes summary, "Category or question structure updated"
    assert_equal "No question or structure changes were detected.", @controller.send(:change_summary, snapshot, snapshot, snapshot[:tracks])
  end

  test "selected tracks and copy params normalize submitted values" do
    @controller.params = ActionController::Parameters.new(
      survey: { track_list: [ "Residential", "", "executive", "Residential" ] },
      survey_copy: { target_program_semester_id: program_semesters(:spring_2026).id.to_s }
    )

    assert_equal [ "Residential", "Executive" ], @controller.send(:selected_tracks)
    assert_equal program_semesters(:spring_2026).id.to_s, @controller.send(:copy_survey_params)[:target_program_semester_id]

    @controller.params = ActionController::Parameters.new
    assert_equal [], @controller.send(:selected_tracks)
    assert_nil @controller.send(:copy_survey_params)[:target_program_semester_id]
  end

  test "prepare copy options defaults to first semester when none selected" do
    @controller.params = ActionController::Parameters.new

    @controller.send(:prepare_copy_options)

    target_semesters = @controller.instance_variable_get(:@copy_target_semesters)
    assert target_semesters.none? { |semester| semester.id == @survey.program_semester_id }
    assert_equal target_semesters.first&.id, @controller.instance_variable_get(:@target_program_semester_id)
  end

  test "scrub stale section attributes keeps valid and new entries only" do
    section = @survey.sections.create!(title: "Existing section", position: 1)
    params = ActionController::Parameters.new(
      sections_attributes: {
        "0" => { id: section.id, title: "Keep" },
        "1" => { id: 999_999, title: "Drop stale" },
        "2" => { title: "New section" },
        "3" => nil,
        "4" => "not-a-hash"
      }
    )
    params.permit!

    @controller.send(:scrub_stale_section_attributes!, params)
    scrubbed = params[:sections_attributes]

    assert_includes scrubbed.keys, "0"
    assert_includes scrubbed.keys, "2"
    refute_includes scrubbed.keys, "1"
    refute_includes scrubbed.keys, "3"
    refute_includes scrubbed.keys, "4"

    no_sections = ActionController::Parameters.new
    assert_nil @controller.send(:scrub_stale_section_attributes!, no_sections)
  end

  test "section form state resolves existing pending and generated uids" do
    persisted_section = @survey.sections.create!(title: "Persisted section", position: 1)
    category_with_section = @survey.categories.create!(name: "Section linked", section: persisted_section)
    category_with_id = @survey.categories.create!(name: "ID linked")
    category_with_id.update_column(:survey_section_id, persisted_section.id)

    @controller.send(:ensure_section_form_state, @survey)

    assert_equal "section-#{persisted_section.id}", persisted_section.form_uid
    assert_equal "section-#{persisted_section.id}", category_with_section.section_form_uid
    assert_equal "section-#{persisted_section.id}", category_with_id.section_form_uid
    assert_nil @controller.send(:section_form_uid_for, nil)

    new_section = @survey.sections.build(title: "New unsaved section")
    assert_match(/\Asection-temp-/, @controller.send(:section_form_uid_for, new_section))
  end

  test "resolve and persist category section links handles pending sections" do
    survey = Survey.new(title: "Pending section survey", creator: @admin, semester: "Fall 2026")
    pending_section = survey.sections.build(title: "Pending Section", form_uid: "section-temp-a", position: 1)
    category = survey.categories.build(
      name: "Linked Category",
      section_form_uid: "section-temp-a",
      questions_attributes: {
        "0" => { question_text: "Question", question_type: "short_answer", question_order: 1 }
      }
    )

    @controller.send(:resolve_category_sections, survey)
    assert_equal [ [ category, pending_section ] ], @controller.send(:pending_category_section_links)

    survey.save!
    @controller.send(:persist_category_section_links)

    assert_equal pending_section.id, category.reload.survey_section_id
    assert_empty @controller.send(:pending_category_section_links)
  end

  test "build default structure adds categories and missing questions" do
    survey = Survey.new(title: "Default structure")
    @controller.send(:build_default_structure, survey)

    assert_equal 1, survey.categories.size
    assert_equal 1, survey.categories.first.questions.size

    existing = Survey.new(title: "Existing structure")
    category = existing.categories.build(name: "Empty category")
    @controller.send(:build_default_structure, existing)

    assert_equal 1, category.questions.size
    assert_equal "New question", category.questions.first.question_text
  end

  test "purge incomplete assignments removes only incomplete assignments and clears version links" do
    survey = Survey.new(title: "Purge assignment survey", creator: @admin, semester: "Fall 2026", program_semester: program_semesters(:fall_2025))
    survey.categories.build(name: "Category").questions.build(question_text: "Question", question_type: "short_answer", question_order: 1)
    survey.save!
    incomplete = SurveyAssignment.create!(
      survey: survey,
      student: students(:student),
      advisor: advisors(:advisor),
      assigned_at: Time.current
    )
    completed = SurveyAssignment.create!(
      survey: survey,
      student: students(:other_student),
      advisor: advisors(:other_advisor),
      assigned_at: Time.current,
      completed_at: Time.current
    )
    version = SurveyResponseVersion.create!(
      survey: survey,
      student: students(:student),
      survey_assignment: incomplete,
      event: "submitted",
      answers: {}
    )

    assert_equal 1, @controller.send(:purge_incomplete_assignments!, survey)
    refute SurveyAssignment.exists?(incomplete.id)
    assert SurveyAssignment.exists?(completed.id)
    assert_nil version.reload.survey_assignment_id
    assert_equal 0, @controller.send(:purge_incomplete_assignments!, survey)
  end

  test "sync competency targets mirrors sets and deletes levels by track" do
    @survey.assign_tracks!([ "Residential" ])
    category = @survey.categories.first
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    question = category.questions.create!(
      question_text: competency_title,
      question_type: "short_answer",
      question_order: category.questions.maximum(:question_order).to_i + 1,
      program_target_level: 4
    )

    @controller.send(:sync_competency_targets_from_questions!, survey: nil, tracks: [ "residential" ])
    @controller.send(:sync_competency_targets_from_questions!, survey: @survey, tracks: [ "", nil ])
    @controller.send(:sync_competency_targets_from_questions!, survey: @survey, tracks: [ "Residential" ])

    target = CompetencyTargetLevel.find_by!(
      program_semester_id: @survey.program_semester_id,
      track: "Residential",
      class_of: nil,
      competency_title: competency_title
    )
    assert_equal 4, target.target_level

    question.update!(program_target_level: nil)
    @controller.send(:sync_competency_targets_from_questions!, survey: @survey, tracks: [ "Residential" ])

    refute CompetencyTargetLevel.exists?(target.id)
  end

  test "survey params supporting data and copy options cover optional branches" do
    category = @survey.categories.first
    question = category.questions.first || category.questions.create!(question_text: "Question", question_type: "short_answer", question_order: 1)

    @controller.params = ActionController::Parameters.new(
      survey: {
        title: "Updated survey",
        track_list: [ "Residential" ],
        categories_attributes: {
          "0" => {
            id: category.id,
            name: category.name,
            questions_attributes: {
              "0" => {
                id: question.id,
                question_text: question.question_text,
                has_feedback: "1",
                program_target_level: "4",
                parent_question_id: "",
                sub_question_order: "1"
              }
            }
          }
        }
      },
      survey_copy: { target_program_semester_id: program_semesters(:spring_2026).id.to_s }
    )

    permitted = @controller.send(:survey_params)
    question_params = permitted.dig(:categories_attributes, "0", :questions_attributes, "0")

    refute_includes permitted.keys, "track_list"
    assert_equal "4", question_params[:program_target_level]
    assert_equal "1", question_params[:has_feedback]
    assert_equal program_semesters(:spring_2026).id.to_s, @controller.send(:copy_survey_params)[:target_program_semester_id]

    @controller.send(:prepare_supporting_data)
    assert @controller.instance_variable_get(:@available_tracks).any?
    assert @controller.instance_variable_get(:@question_types).any?
    assert @controller.instance_variable_get(:@program_semester_options).any?

    @controller.send(:prepare_copy_options)
    assert_equal program_semesters(:spring_2026).id.to_s, @controller.instance_variable_get(:@target_program_semester_id)
  end

  test "sync competency targets falls back to survey tracks and skips empty inputs" do
    survey = Survey.new(
      title: "Target fallback survey",
      creator: @admin,
      semester: "Fall 2026",
      program_semester: program_semesters(:spring_2026)
    )
    category = survey.categories.build(name: "Targets")
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.second
    category.questions.build(
      question_text: competency_title,
      question_type: "dropdown",
      question_order: 1,
      answer_options: %w[1 2 3 4 5].to_json,
      program_target_level: 5
    )
    survey.save!
    survey.assign_tracks!([ "Executive" ])

    @controller.send(:sync_competency_targets_from_questions!, survey: survey, tracks: [])
    assert_equal 5, CompetencyTargetLevel.find_by!(
      program_semester_id: survey.program_semester_id,
      track: "Executive",
      competency_title: competency_title
    ).target_level

    blank_track_survey = Survey.new(title: "No tracks", creator: @admin, semester: "Fall 2026")
    blank_category = blank_track_survey.categories.build(name: "No competency questions")
    blank_category.questions.build(question_text: "General question", question_type: "short_answer", question_order: 1)
    blank_track_survey.save!
    assert_nil @controller.send(:sync_competency_targets_from_questions!, survey: blank_track_survey, tracks: [])
  end

  test "section form helpers cover blank existing pending and skipped records" do
    assert_nil @controller.send(:ensure_section_form_state, nil)
    assert_nil @controller.send(:resolve_category_sections, nil)
    assert_nil @controller.send(:section_form_uid_for, nil)

    survey = Survey.new(title: "Section branch survey")
    existing_section = survey.sections.build(title: "Existing", form_uid: "custom-section")
    category_with_uid = survey.categories.build(name: "Already linked", section_form_uid: "already-set")
    category_with_section = survey.categories.build(name: "Has section", section: existing_section)
    category_with_id = survey.categories.build(name: "Has section id")
    category_with_id.survey_section_id = 55

    @controller.send(:ensure_section_form_state, survey)

    assert_equal "already-set", category_with_uid.section_form_uid
    assert_equal "custom-section", category_with_section.section_form_uid
    assert_equal "section-55", category_with_id.section_form_uid

    pending_section = survey.sections.build(title: "Pending", form_uid: "pending-section")
    skipped_section = survey.sections.build(title: "Destroy", form_uid: "destroy-section")
    skipped_section.mark_for_destruction
    linked_category = survey.categories.build(name: "Pending link", section_form_uid: "pending-section")
    skipped_category = survey.categories.build(name: "Skipped link", section_form_uid: "destroy-section")

    @controller.send(:resolve_category_sections, survey)

    assert_includes @controller.send(:pending_category_section_links), [ linked_category, pending_section ]
    refute @controller.send(:pending_category_section_links).any? { |category, _section| category == skipped_category }

    @controller.send(:pending_category_section_links) << [ Category.new(name: "Unsaved"), SurveySection.new(title: "Unsaved") ]
    assert_nothing_raised { @controller.send(:persist_category_section_links) }
    assert_empty @controller.send(:pending_category_section_links)
  end
end
