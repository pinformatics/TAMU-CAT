require "test_helper"
require "securerandom"

module Reports
  class DataAggregatorAdvisorScoresTest < ActiveSupport::TestCase
    setup do
      @admin = users(:admin)
      @student = students(:student)
      @advisor = advisors(:advisor)
      SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)

      @competency_name = Reports::DataAggregator::COMPETENCY_TITLES.first
      @domain_name = Reports::DataAggregator::REPORT_DOMAINS.first

      @student_question, @advisor_question = create_competency_questions(@competency_name, @domain_name)
      @category = @student_question.category
      @survey = @category.survey
      @student.update!(program_year: 2026) if @student.program_year.blank?
      ensure_completed_assignment(student: @student, survey: @survey)
    end

    teardown do
      SiteSetting.set_course_competency_rule!(CourseCompetencyRule::DEFAULT_RULE)
    end

    test "competency detail includes advisor averages" do
      create_student_response(score: "4.0")
      create_advisor_feedback(score: 5.0)

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      item = aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }

      assert item, "Expected competency detail to include #{@competency_name}"
      assert_in_delta 4.0, item[:student_average], 0.001
      assert_in_delta 5.0, item[:advisor_average], 0.001
    end

    test "competency detail includes course averages" do
      create_student_response(score: "4.0")
      create_course_rating(level: 3.0, competency_title: @competency_name)

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      item = aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }

      assert item, "Expected competency detail to include #{@competency_name}"
      assert_in_delta 3.0, item[:course_average], 0.001
    end

    test "competency detail includes course percent meeting target" do
      create_target_level(level: 4)
      create_course_rating(level: 4.0, competency_title: @competency_name)

      aggregator = Reports::DataAggregator.new(user: @admin, params: { student_id: @student.student_id })
      item = aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }

      assert item, "Expected competency detail to include #{@competency_name}"
      assert_in_delta 100.0, item[:course_target_percent], 0.001
    end

    test "domain summary reflects advisor averages" do
      create_student_response(score: "3.5")
      create_advisor_feedback(score: 4.5)

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      domain_entry = aggregator.competency_summary.find { |entry| entry[:name] == @domain_name }

      assert domain_entry, "Expected competency summary to include #{@domain_name}"
      assert_in_delta 3.5, domain_entry[:student_average], 0.001
      assert_in_delta 4.5, domain_entry[:advisor_average], 0.001
    end

    test "domain summary reflects course averages" do
      create_student_response(score: "3.5")
      create_course_rating(level: 4.0, competency_title: @competency_name)

      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      domain_entry = aggregator.competency_summary.find { |entry| entry[:name] == @domain_name }

      assert domain_entry, "Expected competency summary to include #{@domain_name}"
      assert_in_delta 4.0, domain_entry[:course_average], 0.001
    end

    test "course averages follow global course competency rule" do
      create_course_rating(level: 2.0, competency_title: @competency_name)
      create_course_rating(level: 3.0, competency_title: @competency_name)

      SiteSetting.set_course_competency_rule!("avg")
      avg_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      avg_item = avg_aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }
      assert_in_delta 2.5, avg_item[:course_average], 0.001

      SiteSetting.set_course_competency_rule!("ceil_avg")
      ceil_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      ceil_item = ceil_aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }
      assert_equal 3, ceil_item[:course_average]

      SiteSetting.set_course_competency_rule!("floor_avg")
      floor_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      floor_item = floor_aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }
      assert_equal 2, floor_item[:course_average]
    end

    test "course averages follow max and min for multi-score competency history" do
      [ 3.0, 4.0, 1.0, 2.0, 1.0 ].each do |level|
        create_course_rating(level: level, competency_title: @competency_name)
      end

      SiteSetting.set_course_competency_rule!("max")
      max_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      max_item = max_aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }
      assert_in_delta 4.0, max_item[:course_average], 0.001

      SiteSetting.set_course_competency_rule!("min")
      min_aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      min_item = min_aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }
      assert_in_delta 1.0, min_item[:course_average], 0.001
    end

    test "course averages include only reportable ratings across batches" do
      create_course_rating(level: 2.0, competency_title: @competency_name)
      create_course_rating(level: 4.0, competency_title: @competency_name)
      create_course_rating(level: 5.0, competency_title: @competency_name, batch_summary: { "dry_run" => true })
      create_course_rating(level: 1.0, competency_title: @competency_name, batch_status: "rolled_back")

      SiteSetting.set_course_competency_rule!("avg")
      aggregator = Reports::DataAggregator.new(user: @admin, params: {})
      item = aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }

      assert_in_delta 3.0, item[:course_average], 0.001
    end

    test "course averages are scoped to the selected import semester" do
      create_course_rating(level: 2.0, competency_title: @competency_name, semester: program_semesters(:fall_2025))
      create_course_rating(level: 4.0, competency_title: @competency_name, semester: program_semesters(:spring_2025))
      create_course_rating(level: 5.0, competency_title: @competency_name, semester: nil)

      aggregator = Reports::DataAggregator.new(user: @admin, params: { semester: "Fall 2025" })
      item = aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }

      assert item, "Expected competency detail to include #{@competency_name}"
      assert_in_delta 2.0, item[:course_average], 0.001
      assert_equal "Fall 2025", aggregator.export_payload.dig(:filters, :semester)
    end

    test "course target comparisons use the rating semester target for the student cohort" do
      create_target_level(level: 2, semester: program_semesters(:fall_2025))
      create_target_level(level: 5, semester: program_semesters(:spring_2025))
      create_course_rating(level: 4.0, competency_title: @competency_name, semester: program_semesters(:spring_2025))

      aggregator = Reports::DataAggregator.new(
        user: @admin,
        params: { student_id: @student.student_id }
      )
      item = aggregator.competency_detail[:items].find { |entry| entry[:name] == @competency_name }

      assert item, "Expected competency detail to include #{@competency_name}"
      assert_in_delta 0.0, item[:course_target_percent], 0.001
    end

    test "domain summary reflects course percent meeting target" do
      create_student_response(score: "4.0")
      create_target_level(level: 4)
      create_course_rating(level: 4.0, competency_title: @competency_name)

      aggregator = Reports::DataAggregator.new(user: @admin, params: { student_id: @student.student_id })
      domain_entry = aggregator.competency_summary.find { |entry| entry[:name] == @domain_name }

      assert domain_entry, "Expected competency summary to include #{@domain_name}"
      assert_in_delta 100.0, domain_entry[:course_target_percent], 0.001
    end

    test "export payload includes raw survey advisor and course evidence rows" do
      create_student_response(score: "4.0")
      create_advisor_feedback(score: 5.0)
      create_course_evidence(raw_grade: 95.0, assessed_level: 4, target_level: 3)

      aggregator = Reports::DataAggregator.new(user: @admin, params: { student_id: @student.student_id })
      raw_data = aggregator.export_payload[:raw_data]

      survey_row = raw_data[:survey_responses].find { |row| row[:competency] == @competency_name }
      assert_equal @student.student_id, survey_row[:student_id]
      assert_equal 4.0, survey_row[:score]
      assert_equal "Student User", survey_row[:student_name]

      advisor_row = raw_data[:advisor_ratings].find { |row| row[:competency] == @competency_name }
      assert_equal @advisor.advisor_id, advisor_row[:advisor_id]
      assert_equal "Advisor User", advisor_row[:advisor]
      assert_equal 5.0, advisor_row[:score]

      course_row = raw_data[:course_evidence].find { |row| row[:course] == "PHPM-601" }
      assert_equal "Canvas Result", course_row[:assignment]
      assert_equal BigDecimal("95.0"), course_row[:raw_grade]
      assert_equal 4, course_row[:assessed_level]
      assert_equal 3, course_row[:course_target_level]
      assert_equal "Met", course_row[:target_status]
    end

    private

    def create_competency_questions(competency_name, domain_name)
      survey = Survey.create!(
        title: "Advisor Avg Survey #{SecureRandom.hex(4)}",
        semester: "Fall 2025",
        categories_attributes: [
          {
            name: domain_name,
            description: "Test domain",
            questions_attributes: [
              {
                question_text: competency_name,
                question_order: 1,
                question_type: "short_answer",
                is_required: true,
                has_evidence_field: false
              },
              {
                question_text: "#{competency_name} Reflection",
                question_order: 2,
                question_type: "short_answer",
                is_required: true,
                has_evidence_field: false
              }
            ]
          }
        ]
      )

      category = survey.categories.first
      questions = category.questions.order(:question_order)
      [ questions.first, questions.second ]
    end

    def create_student_response(score:)
      StudentQuestion.create!(
        student_id: @student.student_id,
        question: @student_question,
        response_value: score,
        advisor_id: nil
      )
    end

    def create_advisor_feedback(score:)
      Feedback.create!(
        student_id: @student.student_id,
        advisor_id: @advisor.advisor_id,
        question: @advisor_question,
        category: @category,
        survey: @survey,
        average_score: score
      )
    end

    def create_course_rating(level:, competency_title:, batch_status: "completed", batch_summary: { "dry_run" => false }, semester: nil)
      batch = GradeImportBatch.create!(
        uploaded_by: @admin,
        program_semester: semester,
        status: batch_status,
        summary: batch_summary
      )

      GradeCompetencyRating.create!(
        grade_import_batch: batch,
        student: @student,
        competency_title: competency_title,
        aggregated_level: level,
        aggregation_rule: "max",
        evidence_count: 1
      )
    end

    def create_course_evidence(raw_grade:, assessed_level:, target_level:)
      batch = GradeImportBatch.create!(
        uploaded_by: @admin,
        program_semester: @survey.program_semester,
        status: "completed",
        summary: { "dry_run" => false }
      )
      file = batch.grade_import_files.create!(
        file_name: "Outcomes-26S-PHPM-601.csv",
        file_checksum: SecureRandom.hex(16),
        status: "processed"
      )

      batch.grade_competency_evidences.create!(
        grade_import_file: file,
        student: @student,
        competency_title: @competency_name,
        course_code: "PHPM-601",
        assignment_name: "Canvas Result",
        raw_grade: raw_grade,
        mapped_level: assessed_level,
        course_target_level: target_level,
        source_key: SecureRandom.uuid,
        import_fingerprint: SecureRandom.uuid
      )
    end

    def create_target_level(level:, semester: @survey.program_semester)
      CompetencyTargetLevel.create!(
        program_semester: semester,
        track: @student[:track],
        program_year: @student.program_year,
        competency_title: @competency_name,
        target_level: level
      )
    end

    def ensure_completed_assignment(student:, survey:)
      assignment = SurveyAssignment.find_or_initialize_by(
        survey: survey,
        student: student
      )
      assignment.advisor_id ||= student.advisor&.advisor_id
      assignment.assigned_at ||= Time.current - 2.weeks
      assignment.save!
      assignment.update!(completed_at: assignment.completed_at || Time.current - 1.week)
    end
  end
end
