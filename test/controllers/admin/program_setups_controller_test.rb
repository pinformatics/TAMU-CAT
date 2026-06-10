require "test_helper"

class Admin::ProgramSetupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    sign_in @admin
  end

  test "shows program setup with back button in brand header" do
    get admin_program_setup_path(tab: "tracks")

    assert_response :success
    assert_select ".c-stats-grid", count: 0
    assert_select ".c-card.c-card--brand" do
      assert_select "a[href=?]", admin_dashboard_path
    end
  end

  test "workspace option cards use the same visible layout" do
    get admin_program_setup_path(tab: "years")

    assert_response :success
    assert_select "nav[aria-label='Program setup tabs'] .c-status-badge", count: 0
    assert_select "nav[aria-label='Program setup tabs'] a[aria-current='page']", text: /Cohorts/
  end

  test "track tab hides internal metadata on the surface while keeping position editable" do
    ProgramTrack.create!(key: "visible-test", name: "Visible Test", position: 30, active: true)

    get admin_program_setup_path(tab: "track")

    assert_response :success
    assert_select ".c-pill", text: /Key/, count: 0
    assert_select ".c-pill", text: /Position/, count: 0
    assert_select ".c-setup-list__body", text: /Key/, count: 0
    assert_select ".c-setup-list__body", text: /Position/, count: 0
    assert_select "input[name='program_track[position]']"
  end

  test "setup item lists do not show metadata chips on the surface" do
    Major.create!(name: "Chip Test Major")
    ProgramYear.create!(value: 2090, position: 90, active: true)

    %w[majors years semesters].each do |tab|
      get admin_program_setup_path(tab: tab)

      assert_response :success
      assert_select ".c-setup-list .c-pill", count: 0
      assert_select ".c-setup-list__body", text: /Position/, count: 0
      assert_select ".c-setup-list__body", text: /Key/, count: 0
      if tab == "years"
        assert_select ".c-setup-list[data-program-setup-sortable='true']"
        assert_select ".c-setup-list__body", text: /Class of 2090/
        assert_select "input[name='program_year[position]']"
      end
    end
  end

  test "structure modals use formatted form layout" do
    ProgramTrack.create!(key: "modal-test", name: "Modal Test", position: 30, active: true)

    get admin_program_setup_path(tab: "tracks")

    assert_response :success
    assert_select ".c-modal.c-modal--form"
    assert_select ".c-modal__subtitle", text: /Update the display name/
    assert_select ".c-modal-form__grid"
    assert_select ".c-modal-actions"
    assert_select ".c-modal-danger-zone", text: /Delete track/

    ProgramSemester.find_or_create_by!(name: "Spring 2028") { |semester| semester.current = false }

    get admin_program_setup_path(tab: "semesters")

    assert_response :success
    assert_select ".c-modal-action-zone", count: 0
    assert_select "input[name='program_semester[current]']"
    assert_select ".c-table__title", text: "Set as current semester"
  end

  test "target tab uses target-context language and omits noisy commit parameter" do
    semester = program_semesters(:fall_2025)

    get admin_program_setup_path(tab: "targets", program_semester_id: semester.id, track: "Residential", class_of: 2026)

    assert_response :success
    assert_includes response.body, "1. Target context"
    assert_includes response.body, "Load Targets"
    assert_includes response.body, "Class of 2026"
    assert_includes response.body, "2. Program target coverage"
    assert_includes response.body, "3. Edit targets"
    assert_includes response.body, "End-of-program target"
    assert_includes response.body, "Change Context"
    refute_includes response.body, "Apply Filters"
    refute_includes response.body, "All classes"
    refute_includes response.body, 'name="commit"'
  end

  test "target cohort selector uses configured program years even without students" do
    ProgramYear.create!(value: 2028, position: 30, active: true)

    get admin_program_setup_path(tab: "targets")

    assert_response :success
    assert_includes response.body, "Class of 2028"
  end

  test "course target tab shows configured targets with edit modal fields" do
    semester = program_semesters(:fall_2025)
    competency = create_test_competency!("Course Target UI")
    offering = CourseOffering.find_or_create_from_code!(
      "PHPM-633-700",
      program_semester: semester,
      source_name: "Health Law and Ethics"
    )
    offering.course.update!(title: "Health Law and Ethics")
    CourseCompetencyTarget.create!(course_offering: offering, competency: competency, target_level: 4)

    get admin_program_setup_path(tab: "course_targets", course_target_program_semester_id: semester.id)

    assert_response :success
    assert_select "nav[aria-label='Program setup tabs'] a[aria-current='page']", text: "Course Targets"
    assert_includes response.body, "Set course-level competency targets"
    assert_includes response.body, "PHPM-633-700"
    assert_includes response.body, "Health Law and Ethics"
    assert_includes response.body, "Course Target UI"
    assert_select "button[data-open-modal]", text: "Edit"
    assert_select "input[name='course_competency_target[course_code]'][value='PHPM-633-700']"
    assert_select "input[name='course_competency_target[course_title]'][value='Health Law and Ethics']"
    assert_select "select[name='course_competency_target[competency_id]']"
    assert_select "select[name='course_competency_target[target_level]']"
  end

  test "course target tab shows migration warning instead of crashing when table is missing" do
    connection = ActiveRecord::Base.connection
    original_data_source_exists = connection.method(:data_source_exists?)

    connection.stub(:data_source_exists?, ->(table_name) {
      table_name.to_s == "course_competency_targets" ? false : original_data_source_exists.call(table_name)
    }) do
      get admin_program_setup_path(tab: "course_targets")
    end

    assert_response :success
    assert_includes response.body, "Course target setup is waiting on the V6 database migration"
    refute_includes response.body, "Save course target"
  end

  test "admin can create and update course competency targets" do
    semester = program_semesters(:fall_2025)
    competency = create_test_competency!("Course Target CRUD")

    assert_difference "CourseCompetencyTarget.count", 1 do
      post admin_course_competency_targets_path, params: {
        course_competency_target: {
          program_semester_id: semester.id,
          course_code: "PHPM-634-700",
          course_title: "Health Finance",
          competency_id: competency.id,
          target_level: "3"
        }
      }
    end

    target = CourseCompetencyTarget.order(:created_at).last
    assert_redirected_to admin_program_setup_path(tab: "course_targets", course_target_program_semester_id: semester.id)
    assert_equal "PHPM-634-700", target.course_code
    assert_equal "Health Finance", target.course_title
    assert_equal 3, target.target_level

    patch admin_course_competency_target_path(target), params: {
      course_competency_target: {
        program_semester_id: semester.id,
        course_code: "PHPM-634-700",
        course_title: "Health Care Finance",
        competency_id: competency.id,
        target_level: "5"
      }
    }

    assert_redirected_to admin_program_setup_path(tab: "course_targets", course_target_program_semester_id: semester.id)
    assert_equal "Health Care Finance", target.reload.course_title
    assert_equal 5, target.target_level
  end

  test "course target create rejects invalid course code" do
    semester = program_semesters(:fall_2025)
    competency = create_test_competency!("Course Target Invalid Code")

    assert_no_difference "CourseCompetencyTarget.count" do
      post admin_course_competency_targets_path, params: {
        course_competency_target: {
          program_semester_id: semester.id,
          course_code: "not a course",
          course_title: "Bad Course",
          competency_id: competency.id,
          target_level: "3"
        }
      }
    end

    assert_redirected_to admin_program_setup_path(tab: "course_targets", course_target_program_semester_id: semester.id)
    assert_match(/course code/i, flash[:alert].to_s)
  end

  test "admin can delete course competency targets" do
    semester = program_semesters(:fall_2025)
    competency = create_test_competency!("Course Target Delete")
    offering = CourseOffering.find_or_create_from_code!("PHPM-635-700", program_semester: semester)
    target = CourseCompetencyTarget.create!(course_offering: offering, competency: competency, target_level: 4)

    assert_difference "CourseCompetencyTarget.count", -1 do
      delete admin_course_competency_target_path(target)
    end

    assert_redirected_to admin_program_setup_path(tab: "course_targets", course_target_program_semester_id: semester.id)
    assert_match(/removed/i, flash[:notice].to_s)
  end

  test "semester tab honors chronological program semester ordering" do
    ProgramSemester.find_or_create_by!(name: "Fall 2026") { |semester| semester.current = false }

    get admin_program_setup_path(tab: "semesters")

    assert_response :success
    assert_select ".c-setup-list .c-table__title" do |elements|
      names = elements.map { |element| element.text.strip }
      expected = [ "Spring 2025", "Fall 2025", "Spring 2026", "Fall 2026" ]
      assert_equal expected, names.select { |name| expected.include?(name) }
    end
  end

  test "legacy target helpers map old program year and class values" do
    controller = Admin::ProgramSetupsController.new

    assert_equal [ 2026, 2 ], controller.send(:legacy_program_year_candidates, 2026)
    assert_equal [ 2027, 1 ], controller.send(:legacy_program_year_candidates, 2027)
    assert_equal [ 2030 ], controller.send(:legacy_program_year_candidates, 2030)
    assert_equal [ 2 ], controller.send(:legacy_class_of_candidates, 2026)
    assert_equal [ 1 ], controller.send(:legacy_class_of_candidates, 2027)
    assert_equal [], controller.send(:legacy_class_of_candidates, 2030)
    assert_includes controller.send(:legacy_program_year_order_sql, 2026), "CASE program_year"
    assert_equal "program_year = 2030 DESC", controller.send(:legacy_program_year_order_sql, 2030)
  end

  private

  def create_test_competency!(title)
    domain = Domain.find_or_create_by!(name: "Test Domain") do |record|
      record.position = 100
    end
    Competency.find_or_create_by!(title: title) do |record|
      record.domain = domain
      record.position = 100
    end
  end
end
