require "test_helper"

class StudentTest < ActiveSupport::TestCase
  test "delegates name to user" do
    student = students(:student)
    assert_equal "Student User", student.name
  end

  test "requires unique uin" do
    duplicate = Student.new(student_id: 99, advisor: advisors(:advisor), uin: "123456789", track: "Residential")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:uin], "has already been taken"
  end

    test "uin must be exactly 9 digits" do
      student = students(:student)
      student.major = "Public Health"
      student.track = "Residential"

      student.uin = "123"
      assert_not student.valid?(:profile_completion)
      assert_includes student.errors[:uin], "must be exactly 9 digits"

      student.uin = "1234567890"
      assert_not student.valid?(:profile_completion)
      assert_includes student.errors[:uin], "must be exactly 9 digits"
    end

    test "uin normalizes to digits" do
      student = students(:student)
      student.major = "Public Health"
      student.track = "Residential"
      student.program_year = 2026

      student.uin = "123-456-789"
      assert student.valid?(:profile_completion)
      assert_equal "123456789", student.uin
    end

    test "program_year must be between 2026 and 3000" do
      student = students(:student)
      student.major = "Public Health"
      student.track = "Residential"
      student.uin = "123456789"

      student.program_year = 2025
      assert_not student.valid?(:profile_completion)

      student.program_year = 2026
      assert student.valid?(:profile_completion)
    end

    test "lifecycle helpers and labels cover active graduated archived and inactive states" do
      student = students(:student)

      assert_equal "current", Student.normalize_lifecycle_filter(nil)
      assert_equal "current", Student.normalize_lifecycle_filter("unknown")
      assert_equal "graduated", Student.normalize_lifecycle_filter(" Graduated ")
      assert student.profile_complete? == (student.user.name.present? && student.uin.present? && student.major.present? && student.track_key.present? && student.program_year.present?)
      assert student.current_record?
      assert_equal "Active", student.lifecycle_label

      student.graduate!(at: Time.current)
      assert student.graduated?
      assert_equal "Graduated", student.lifecycle_label

      student.archive!(archived_by: users(:admin), reason: "Test archive", at: Time.current)
      assert student.archived?
      assert_equal "Archived", student.lifecycle_label

      student.reactivate!
      assert student.current_record?

      student.mark_inactive!
      assert_equal "Inactive", student.lifecycle_label

      student.withdraw!
      assert_equal "Withdrawn", student.lifecycle_label
    end

    test "track writer keeps canonical values and class_of aliases program_year" do
      student = students(:student)

      student[:track] = nil
      student.track = "Residential"
      assert_equal "residential", student[:track]
      assert_equal "Residential", student.track

      student.track = "custom track"
      assert_equal "custom track", student[:track]
      assert_equal "Custom Track", student.track

      student.class_of = 2028
      assert_equal 2028, student.program_year
      assert_equal 2028, student.class_of
    end

    test "profile and lifecycle helpers cover incomplete and status fallbacks" do
      student = students(:student)
      student.major = nil
      refute student.profile_complete?

      assert_equal "active", Student.normalize_lifecycle_filter("", default: "active")
      assert_equal "all", Student.normalize_lifecycle_filter("all")
      assert Student.lifecycle_filter_options.any? { |label, value| label == "All students" && value == "all" }

      student.status = nil
      student.archived_at = nil
      student.graduated_at = nil
      assert_equal "Active", student.lifecycle_label
    end

    test "save persists changed delegated user fields" do
      student = students(:student)
      student.name = "Updated Student Name"

      student.save!

      assert_equal "Updated Student Name", student.reload.user.name
    ensure
      student&.user&.update!(name: "Student User")
    end

    test "callback helpers rescue assignment and reconciliation failures" do
      student = students(:student)

      SurveyAssignments::AutoAssigner.stub(:call, ->(*) { raise StandardError, "assignment failed" }) do
        assert_nothing_raised { student.send(:auto_assign_track_survey) }
      end

      GradeImports::PendingRowReconciler.stub(:call, ->(*) { raise StandardError, "reconcile failed" }) do
        assert_nothing_raised { student.send(:reconcile_pending_grade_import_rows) }
      end

      StudentAdvisorAssignment.stub(:record_advisor_change!, ->(*) { raise StandardError, "history failed" }) do
        assert_nothing_raised { student.send(:sync_advisor_assignment_history) }
        assert_nil student.advisor_assignment_actor
      end
    end
end
