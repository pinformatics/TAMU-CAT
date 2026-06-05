require "test_helper"

class SurveyTest < ActiveSupport::TestCase
  test "active scope returns active surveys" do
    active = Survey.where(is_active: true).to_a
    assert active.present?
    assert_equal active.sort_by(&:id), Survey.active.order(:id).to_a
  end

  test "survey has questions association and questions can be ordered" do
    survey = surveys(:fall_2025)
    assert_respond_to survey, :questions
    ordered = survey.questions.ordered.to_a
    assert_kind_of Array, ordered
  end
  test "valid fixture" do
    assert surveys(:fall_2025).valid?
  end

  test "requires title" do
    survey = Survey.new(semester: "Fall 2025")
    assert_not survey.valid?
    assert_includes survey.errors[:title], "can't be blank"
  end

  test "requires semester" do
    survey = Survey.new(title: "Test Survey")
    assert_not survey.valid?
    assert_includes survey.errors[:program_semester], "must exist"
  end

  test "rejects duplicate title within the same semester" do
    existing = surveys(:fall_2025)
    survey = build_survey(
      title: "  #{existing.title.upcase}  ",
      semester: "  #{existing.semester.downcase}  "
    )

    assert_not survey.valid?
    assert_includes survey.errors[:title], "already exists for this semester"
  end

  test "allows same title across different semesters" do
    existing = surveys(:fall_2025)
    survey = build_survey(title: existing.title, semester: "Spring 2035")

    assert survey.valid?
  end

  test "strips surrounding whitespace before validation" do
    survey = build_survey(title: "  Sample Survey  ", semester: "  Fall 2035  ")

    assert survey.valid?
    assert_equal "Sample Survey", survey.title
    assert_equal "Fall 2035", survey.semester
  end

  test "changing survey due date updates inherited assignment deadlines but preserves custom ones" do
    survey = build_survey(title: "Due Sync Survey", semester: "Fall 2036")
    survey.available_until = Time.zone.local(2036, 10, 1, 12, 0)
    survey.save!

    inherited_assignment = SurveyAssignment.create!(
      survey: survey,
      student: students(:student),
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: survey.available_until
    )

    custom_deadline = Time.zone.local(2036, 10, 20, 17, 0)
    custom_assignment = SurveyAssignment.create!(
      survey: survey,
      student: students(:other_student),
      advisor: advisors(:other_advisor),
      assigned_at: Time.current,
      available_until: custom_deadline
    )

    completed_inherited_assignment = SurveyAssignment.create!(
      survey: survey,
      student: students(:completed_student),
      advisor: advisors(:other_advisor),
      assigned_at: Time.current,
      completed_at: 1.day.ago,
      available_until: survey.available_until
    )

    new_survey_deadline = Time.zone.local(2036, 11, 15, 9, 30)
    survey.update!(available_until: new_survey_deadline)

    assert_equal new_survey_deadline.to_i, inherited_assignment.reload.available_until.to_i
    assert_equal new_survey_deadline.to_i, completed_inherited_assignment.reload.available_until.to_i
    assert_equal custom_deadline.to_i, custom_assignment.reload.available_until.to_i
  end

  test "removing survey due date clears inherited assignment deadlines" do
    survey = build_survey(title: "Due Removal Survey", semester: "Spring 2037")
    survey.available_until = Time.zone.local(2037, 3, 20, 8, 0)
    survey.save!

    inherited_assignment = SurveyAssignment.create!(
      survey: survey,
      student: students(:student),
      advisor: advisors(:advisor),
      assigned_at: Time.current,
      available_until: survey.available_until
    )

    custom_deadline = Time.zone.local(2037, 4, 10, 8, 0)
    custom_assignment = SurveyAssignment.create!(
      survey: survey,
      student: students(:other_student),
      advisor: advisors(:other_advisor),
      assigned_at: Time.current,
      available_until: custom_deadline
    )

    completed_inherited_assignment = SurveyAssignment.create!(
      survey: survey,
      student: students(:completed_student),
      advisor: advisors(:other_advisor),
      assigned_at: Time.current,
      completed_at: Time.current,
      available_until: survey.available_until
    )

    survey.update!(available_until: nil)

    assert_nil inherited_assignment.reload.available_until
    assert_nil completed_inherited_assignment.reload.available_until
    assert_equal custom_deadline.to_i, custom_assignment.reload.available_until.to_i
  end

  test "category and availability validations cover destroyed questions and reversed windows" do
    survey = build_survey(title: "Destroyed Question Survey", semester: "Fall 2038")
    survey.categories.first.questions.first.mark_for_destruction

    refute survey.valid?
    assert_includes survey.errors[:base], "Each category must include at least one question"

    survey = build_survey(title: "Reversed Window Survey", semester: "Spring 2039")
    survey.available_from = Time.zone.local(2039, 3, 1, 12, 0)
    survey.available_until = Time.zone.local(2039, 2, 1, 12, 0)

    refute survey.valid?
    assert_includes survey.errors[:available_until], "must be after Available from"
  end

  test "track normalization handles aliases non strings and long custom labels" do
    survey = surveys(:fall_2025)
    long_label = "x" * 300

    normalized = survey.send(:normalize_track_values, [ " RMHA ", [ 123, "", nil, long_label ] ])

    assert_includes normalized, "Residential"
    assert_includes normalized, "123"
    assert_includes normalized, long_label[0..254]
    refute_includes normalized, ""
  end

  test "duplicate title diagnostic falls back when semester association is unavailable" do
    existing = surveys(:fall_2025)
    survey = Survey.new(title: existing.title, program_semester_id: existing.program_semester_id, is_active: true)
    category = survey.categories.build(name: "Basics")
    category.questions.build(
      question_text: "Describe your progress",
      question_type: "short_answer",
      question_order: 1
    )
    survey.singleton_class.define_method(:program_semester) { nil }

    refute survey.valid?
    assert_match(/this semester/, survey.errors[:base].join(" "))
  ensure
    survey&.singleton_class&.send(:remove_method, :program_semester) if survey&.singleton_class&.method_defined?(:program_semester)
  end

  private

  def build_survey(attrs = {})
    Survey.new({ title: "Unique", semester: "Fall 2099", is_active: true }.merge(attrs)).tap do |survey|
      category = survey.categories.build(name: "Basics")
      category.questions.build(
        question_text: "Describe your progress",
        question_type: "short_answer",
        question_order: 1
      )
    end
  end
end
