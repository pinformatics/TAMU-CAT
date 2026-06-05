# frozen_string_literal: true

require "test_helper"

module SurveyAssignments
  class AutoAssignerTest < ActiveSupport::TestCase
    setup do
      @student = students(:student)
      @student.survey_assignments.destroy_all

      SurveyOffering.delete_all

      ProgramSemester.update_all(current: false)
      program_semesters(:fall_2025).update!(current: true)

      # Keep two executive offerings eligible under the current-semester filter.
      surveys(:spring_2025).update_column(:program_semester_id, program_semesters(:fall_2025).id)

      SurveyOffering.create!(
        survey: surveys(:fall_2025),
        track: "Residential",
        class_of: 2026,
        stage: "midpoint",
        portfolio_due_date: surveys(:fall_2025).available_until,
        available_until: surveys(:fall_2025).available_until
      )
      SurveyOffering.create!(
        survey: surveys(:fall_2025_executive),
        track: "Executive",
        class_of: 2026,
        stage: "midpoint",
        portfolio_due_date: surveys(:fall_2025_executive).available_until,
        available_until: surveys(:fall_2025_executive).available_until
      )

      SurveyOffering.create!(
        survey: surveys(:spring_2025),
        track: "Executive",
        class_of: 2026,
        stage: "final",
        portfolio_due_date: surveys(:spring_2025).available_until,
        available_until: surveys(:spring_2025).available_until
      )
    end

    test "skips assignment when track is blank" do
      @student.update_columns(track: nil)

      assert_no_difference -> { SurveyAssignment.count } do
        AutoAssigner.call(student: @student)
      end
    end

    test "skips safely when student is nil" do
      assert_nothing_raised do
        AutoAssigner.call(student: nil, track: "Residential", class_of: 2026)
      end
    end

    test "skips assignment when program_year is blank" do
      @student.update_columns(track: "Residential", program_year: nil)

      assert_no_difference -> { SurveyAssignment.count } do
        AutoAssigner.call(student: @student)
      end
    end

    test "assigns surveys matching the student's track" do
      @student.update_columns(track: "Residential", program_year: 2026)

      assert_difference -> { @student.survey_assignments.count }, 1 do
        AutoAssigner.call(student: @student)
      end

      assignment = @student.survey_assignments.find_by(survey: surveys(:fall_2025))
      assert_not_nil assignment
      assert_equal @student.advisor_id, assignment.advisor_id
      assert_not_nil assignment.assigned_at
      assert_equal surveys(:fall_2025).available_until.to_date, assignment.available_until.to_date
      refute_includes @student.survey_assignments.pluck(:survey_id), surveys(:spring_2025).id
    end

    test "legacy program_year argument assigns when student class year is blank" do
      @student.update_columns(track: nil, program_year: nil)

      assert_difference -> { @student.survey_assignments.count }, 1 do
        AutoAssigner.call(student: @student, track: "Residential", program_year: 2026)
      end
    end

    test "manual assignment keeps custom availability dates during reconciliation" do
      @student.update_columns(track: "Residential", program_year: 2026)
      custom_from = 3.days.ago
      custom_until = 30.days.from_now
      manual = SurveyAssignment.create!(
        student: @student,
        survey: surveys(:fall_2025),
        assigned_at: 1.day.ago,
        manual: true,
        available_from: custom_from,
        available_until: custom_until
      )

      AutoAssigner.call(student: @student)

      manual.reload
      assert_in_delta custom_from.to_i, manual.available_from.to_i, 2
      assert_in_delta custom_until.to_i, manual.available_until.to_i, 2
    end

    test "auto-assigns offerings even when portfolio deadline is blank" do
      SurveyOffering.create!(
        survey: surveys(:fall_2025),
        track: "Residential",
        class_of: 2027,
        stage: "initial",
        portfolio_due_date: nil,
        available_until: nil
      )

      @student.update_columns(track: "Residential", program_year: 2027)

      assert_difference -> { @student.survey_assignments.count }, 1 do
        AutoAssigner.call(student: @student)
      end

      assignment = @student.survey_assignments.find_by(survey: surveys(:fall_2025))
      assert_not_nil assignment
      assert_nil assignment.available_until
    end

    test "replaces assignments when the track changes" do
      @student.update_columns(track: "Residential", program_year: 2026)
      AutoAssigner.call(student: @student)

      @student.update_columns(track: "Executive")
      AutoAssigner.call(student: @student)

      assert_equal [ surveys(:fall_2025_executive).id, surveys(:spring_2025).id ].sort, @student.survey_assignments.pluck(:survey_id).sort
    end

    test "keeps completed assignments when the track changes" do
      @student.update_columns(track: "Residential", program_year: 2026)
      AutoAssigner.call(student: @student)

      assignment = @student.survey_assignments.find_by!(survey: surveys(:fall_2025))
      completion_time = 2.days.ago.change(usec: 0)
      assignment.update!(completed_at: completion_time)

      @student.update_columns(track: "Executive")
      AutoAssigner.call(student: @student)

      assignment.reload
      assert_equal completion_time, assignment.completed_at

      survey_ids = @student.survey_assignments.pluck(:survey_id)
      assert_includes survey_ids, surveys(:fall_2025).id
      assert_includes survey_ids, surveys(:fall_2025_executive).id
      assert_includes survey_ids, surveys(:spring_2025).id
    end

    test "does not remove manual assignments during reconciliation" do
      @student.update_columns(track: "Residential", program_year: 2026)

      manual_survey = surveys(:spring_2025) # Executive offering; not in Residential offerings
      SurveyAssignment.create!(student: @student, survey: manual_survey, assigned_at: Time.current, manual: true)

      AutoAssigner.call(student: @student)

      assert @student.survey_assignments.exists?(survey_id: manual_survey.id)
    end

    test "assigns all matching offerings for the student" do
      @student.update_columns(track: "Executive", program_year: 2026)
      AutoAssigner.call(student: @student)

      survey_ids = @student.survey_assignments.pluck(:survey_id)
      assert_includes survey_ids, surveys(:fall_2025_executive).id
      assert_includes survey_ids, surveys(:spring_2025).id
    end

    test "fallback assignment follows RMHA schedule by class year" do
      SurveyOffering.delete_all
      ProgramSemester.update_all(current: false)
      program_semesters(:spring_2026).update!(current: true)

      @student.update_columns(track: "Residential", program_year: 2026)

      assert_difference -> { @student.survey_assignments.count }, 2 do
        AutoAssigner.call(student: @student)
      end

      survey_ids = @student.survey_assignments.pluck(:survey_id)
      assert_includes survey_ids, surveys(:rmha_midpoint_spring_2026).id
      assert_includes survey_ids, surveys(:rmha_final_spring_2026).id
      refute_includes survey_ids, surveys(:rmha_initial_spring_2026).id

      @student.survey_assignments.destroy_all
      @student.update_columns(track: "Residential", program_year: 2027)

      assert_difference -> { @student.survey_assignments.count }, 1 do
        AutoAssigner.call(student: @student)
      end

      survey_ids = @student.survey_assignments.pluck(:survey_id)
      assert_equal [ surveys(:rmha_initial_spring_2026).id ], survey_ids
    end

    test "fallback assignment uses ordered last semester when no semester is marked current" do
      SurveyOffering.delete_all
      ProgramSemester.update_all(current: false)
      @student.update_columns(track: "Executive", program_year: 2026)

      assert_difference -> { @student.survey_assignments.count }, 2 do
        AutoAssigner.call(student: @student)
      end

      assert_includes @student.survey_assignments.pluck(:survey_id), surveys(:fall_2025_executive).id
    end

    test "fallback assignment follows EMHA schedule by class year" do
      SurveyOffering.delete_all
      ProgramSemester.update_all(current: false)
      program_semesters(:spring_2026).update!(current: true)

      @student.update_columns(track: "Executive", program_year: 2027)

      assert_difference -> { @student.survey_assignments.count }, 1 do
        AutoAssigner.call(student: @student)
      end

      survey_ids = @student.survey_assignments.pluck(:survey_id)
      assert_equal [ surveys(:emha_midpoint_spring_2026).id ], survey_ids

      @student.survey_assignments.destroy_all
      @student.update_columns(track: "Executive", program_year: 2026)

      assert_difference -> { @student.survey_assignments.count }, 1 do
        AutoAssigner.call(student: @student)
      end

      survey_ids = @student.survey_assignments.pluck(:survey_id)
      assert_equal [ surveys(:emha_final_spring_2026).id ], survey_ids
    end

    test "scheduled title and year helpers cover blank and unknown contexts" do
      assigner = AutoAssigner.new(student: @student, track: "Unknown", class_of: 2026)

      assert_equal [], assigner.send(:scheduled_titles_for, track: "", class_of: 2026)
      assert_equal [], assigner.send(:scheduled_titles_for, track: "Residential", class_of: "")
      assert_equal [], assigner.send(:scheduled_titles_for, track: "Unknown", class_of: 2026)

      ProgramSemester.stub(:current, OpenStruct.new(name: "No year here")) do
        assert_nil assigner.send(:current_program_year)
        assert_equal [], assigner.send(:scheduled_titles_for, track: "Residential", class_of: 2026)
      end
    end

    test "fallback survey lookup returns none when no current or ordered semester exists" do
      SurveyOffering.delete_all
      assigner = AutoAssigner.new(student: @student, track: "Residential", class_of: 2026)

      ProgramSemester.stub(:current, nil) do
        ProgramSemester.stub(:ordered, []) do
          assert_empty assigner.send(:surveys_for_track)
        end
      end
    end

    test "offering lookup supports student objects without assignment groups" do
      student_without_group = Struct.new(:track_key, :program_year).new("Residential", 2026)
      assigner = AutoAssigner.new(student: student_without_group, track: "Residential", class_of: 2026)
      fall_survey = self.surveys(:fall_2025)

      surveys, active_ids, available_from, available_until = assigner.send(:surveys_for_student)

      assert_includes surveys, fall_survey
      assert_includes active_ids, fall_survey.id
      assert_equal({ fall_survey.id => nil }, available_from.slice(fall_survey.id))
      assert_equal fall_survey.available_until.to_i, available_until[fall_survey.id].to_i
    end

    test "initializer falls back through student values and legacy program year argument" do
      @student.update_columns(track: "Residential", program_year: nil)

      from_student = AutoAssigner.new(student: @student)
      assert_equal @student.track_key, from_student.send(:track)
      assert_nil from_student.send(:class_of)

      from_legacy_argument = AutoAssigner.new(student: @student, track: "Executive", program_year: 2027)
      assert_equal "Executive", from_legacy_argument.send(:track)
      assert_equal 2027, from_legacy_argument.send(:class_of)
    end
  end
end
