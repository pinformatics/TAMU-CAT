require "test_helper"

class AdvisorAttentionListTest < ActiveSupport::TestCase
  setup do
    @student = students(:student)
    @student.update!(advisor_id: advisors(:advisor).advisor_id)
    @semester = program_semesters(:fall_2025)
  end

  test "returns students with incomplete assignments and sorts by priority" do
    survey = surveys(:fall_2025)
    SurveyAssignment.where(student: @student, survey: survey).delete_all
    SurveyAssignment.create!(student: @student, survey: survey, assigned_at: Time.current, completed_at: nil)

    rows = AdvisorAttentionList.new(students: [ @student ], semester: @semester.name).call
    row = rows.first

    assert_equal 1, rows.size
    assert_equal @student.student_id, row[:student_id]
    assert_equal @student.user.email, row[:email]
    assert_equal @semester.name, row[:semester]
    assert_equal 1, row[:missing_survey_count]
    assert_equal 1, row[:priority]
    assert_equal({ semester: @semester.name }, row[:detail_path_params])
  end

  test "returns students below target even without missing assignments" do
    SurveyAssignment.where(student: @student).update_all(completed_at: Time.current)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first

    CompetencyTargetLevel.create!(
      program_semester: @semester,
      track: @student.track,
      class_of: @student.program_year,
      competency_title: competency_title,
      target_level: 4
    )

    batch = GradeImportBatch.create!(
      uploaded_by: users(:admin),
      program_semester: @semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    GradeCompetencyRating.create!(
      grade_import_batch: batch,
      student: @student,
      competency_title: competency_title,
      aggregated_level: 2,
      aggregation_rule: "max",
      evidence_count: 1
    )

    rows = AdvisorAttentionList.new(students: [ @student ], semester: @semester.name).call
    below_target = rows.first[:below_target_competencies].first

    assert_equal 1, rows.size
    assert_equal competency_title, below_target[:title]
    assert_equal 2.0, below_target[:course_rating]
    assert_equal 4, below_target[:target]
    assert_equal 1, rows.first[:priority]
  end

  test "omits students without missing surveys or below target competencies" do
    SurveyAssignment.where(student: @student).update_all(completed_at: Time.current)

    rows = AdvisorAttentionList.new(students: [ @student ], semester: @semester.name).call

    assert_empty rows
  end
end
