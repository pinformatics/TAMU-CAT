require "test_helper"

class CompositeReportGeneratorTest < ActiveSupport::TestCase
  setup do
    @student = students(:student)
    @survey = surveys(:fall_2025)
    @survey_response = SurveyResponse.build(student: @student, survey: @survey)
  end

  test "composite report omits advisor rating column when no advisor ratings exist" do
    html = render_competency_report_html

    assert_no_match(/<th>\s*Advisor Rating\s*<\/th>/, html)
  end

  test "composite report keeps advisor rating column when advisor ratings exist" do
    html = render_competency_report_html(advisor_score: 4)

    assert_match(/<th>\s*Advisor Rating\s*<\/th>/, html)
    assert_includes html, ">4<"
  end

  test "composite report renders polished report shell and handling language" do
    html = render_competency_report_html

    assert_includes html, "Survey Response Report"
    assert_includes html, "Student-level competency record"
    assert_includes html, "FERPA"
    assert_includes html, "class=\"report-facts\""
    assert_includes html, "class=\"pdf-stat-row\""
    assert_no_match(/pdf-stat-label\">\s*Answered\s*</, html)
    assert_no_match(/\d+%\s+complete/, html)
    assert_includes html, "Required"
  end

  test "result cleanup runs once" do
    calls = 0
    result = CompositeReportGenerator::Result.new(path: "file.pdf", cached: true, size_bytes: 10, cleanup: -> { calls += 1 })

    assert_equal true, result.cached?
    result.cleanup!
    result.cleanup!

    assert_equal 1, calls
  end

  test "render without cache writes result and cleanup removes tempfile" do
    generator = CompositeReportGenerator.new(survey_response: @survey_response, cache: false)
    tempfile = Tempfile.new([ "composite-test", ".pdf" ])
    tempfile.binmode
    tempfile.write("%PDF payload")
    tempfile.flush

    generator.stub(:render_html, "<html></html>") do
      generator.stub(:build_pdf_file, tempfile) do
        result = generator.send(:render_without_cache)
        path = result.path
        assert_equal false, result.cached?
        assert_equal tempfile.path, path
        assert_operator result.size_bytes, :positive?
        result.cleanup!
        assert_equal false, File.exist?(path)
      end
    end
  end

  test "render raises missing dependency directly and wraps other failures" do
    generator = CompositeReportGenerator.new(survey_response: @survey_response, cache: false)

    generator.stub(:ensure_dependency!, -> { raise CompositeReportGenerator::MissingDependency, "missing" }) do
      assert_raises(CompositeReportGenerator::MissingDependency) { generator.render }
    end

    generator.stub(:ensure_dependency!, true) do
      generator.stub(:render_without_cache, nil) do
        error = assert_raises(CompositeReportGenerator::GenerationError) { generator.render }
        assert_includes error.message, "Composite PDF generation failed"
      end
    end
  end

  test "feedback scope and summaries respect viewer mode submitted advisors and empty scores" do
    category = categories(:clinical_skills)
    submitted_advisor = @student.advisor
    other_advisor = advisors(:other_advisor)
    submitted_feedback = Feedback.create!(
      student_id: @student.student_id,
      advisor_id: submitted_advisor.advisor_id,
      category_id: category.id,
      survey_id: @survey.id,
      average_score: 4,
      comments: "Submitted"
    )
    Feedback.create!(
      student_id: @student.student_id,
      advisor_id: other_advisor.advisor_id,
      category_id: category.id,
      survey_id: @survey.id,
      average_score: nil,
      comments: "Draft"
    )

    advisor_feedback_submissions(:submitted_feedback).update!(submitted_at: Time.current)

    student_generator = CompositeReportGenerator.new(survey_response: @survey_response, viewer_mode: :student)
    student_feedback = student_generator.send(:feedback_records)
    assert_includes student_feedback.map(&:id), submitted_feedback.id
    assert student_feedback.all? { |feedback| feedback.advisor_id == submitted_advisor.advisor_id }
    assert_operator student_generator.send(:feedback_summary)[:total_entries], :>=, 1
    assert_not_nil student_generator.send(:feedback_summary)[:average_score]

    staff_generator = CompositeReportGenerator.new(survey_response: @survey_response, viewer_mode: :staff)
    assert_operator staff_generator.send(:feedback_records).size, :>=, 2
    assert_equal [ category.id ], staff_generator.send(:feedbacks_by_category).keys
  end

  test "evidence history respects configured positive and zero limits" do
    generator = CompositeReportGenerator.new(survey_response: @survey_response)
    history = { 1 => [ :a, :b, :c, :d, :e, :f ] }

    @survey_response.stub(:evidence_history_by_category, history) do
      assert_equal 5, generator.send(:evidence_history_by_category)[1].size
    end
  end

  test "cache fingerprint handles nil and present timestamps deterministically" do
    generator = CompositeReportGenerator.new(survey_response: @survey_response)
    response = OpenStruct.new(updated_at: nil, created_at: Time.zone.local(2026, 1, 1))
    feedback = OpenStruct.new(id: 44, updated_at: Time.zone.local(2026, 1, 2), created_at: nil)
    student = OpenStruct.new(updated_at: nil, user: nil)
    survey = OpenStruct.new(id: @survey.id, updated_at: nil)
    advisor = OpenStruct.new(advisor_id: 12, updated_at: nil, user: OpenStruct.new(updated_at: Time.zone.local(2026, 1, 3)))

    generator.stub(:question_responses, [ response ]) do
      generator.stub(:feedback_records, [ feedback ]) do
        generator.stub(:student, student) do
          generator.stub(:survey, survey) do
            generator.stub(:advisor, advisor) do
              first = generator.cache_fingerprint
              second = generator.cache_fingerprint

              assert_equal first, second
              assert_match(/\A[0-9a-f]{64}\z/, first)
            end
          end
        end
      end
    end
  end

  test "render with cache raises when cache does not produce an existing file" do
    generator = CompositeReportGenerator.new(survey_response: @survey_response)

    generator.stub(:cache_fingerprint, "fingerprint") do
      CompositeReportCache.stub(:fetch, nil) do
        assert_raises(CompositeReportGenerator::GenerationError) do
          generator.send(:render_with_cache)
        end
      end
    end
  end

  test "render wraps unexpected failures with logged generation error" do
    logger = Class.new do
      attr_reader :messages

      def initialize = @messages = []
      def error(message) = @messages << message
    end.new
    generator = CompositeReportGenerator.new(survey_response: @survey_response, cache: false, logger: logger)

    generator.stub(:ensure_dependency!, true) do
      generator.stub(:render_without_cache, -> { raise RuntimeError, "render failed" }) do
        error = assert_raises(CompositeReportGenerator::GenerationError) { generator.render }

        assert_equal "render failed", error.message
        assert_match(/generation failed/, logger.messages.join("\n"))
      end
    end
  end

  private

  def render_competency_report_html(advisor_score: nil)
    student = students(:student)
    survey = Survey.create!(
      title: "Composite PDF Advisor Rating #{SecureRandom.hex(4)}",
      program_semester: program_semesters(:fall_2025),
      is_active: true,
      categories_attributes: [
        {
          name: "Competency Ratings",
          questions_attributes: [
            {
              question_text: "Communication",
              question_order: 1,
              question_type: "dropdown",
              is_required: false,
              answer_options: [
                [ "Foundational (1)", "1" ],
                [ "Developing (2)", "2" ],
                [ "Proficient (3)", "3" ],
                [ "Advanced (4)", "4" ],
                [ "Expert (5)", "5" ]
              ].to_json,
              program_target_level: 3
            }
          ]
        }
      ]
    )
    section = SurveySection.create!(
      survey: survey,
      title: SurveySection::MHA_COMPETENCY_SECTION_TITLE,
      position: 0
    )
    category = survey.categories.first
    category.update!(section: section)
    question = category.questions.first

    response = StudentQuestion.new(
      student_id: student.student_id,
      advisor_id: student.advisor_id,
      question_id: question.id
    )
    response.answer = "3"
    response.save!(validate: false)

    if advisor_score.present?
      Feedback.create!(
        student_id: student.student_id,
        advisor_id: student.advisor_id,
        category_id: category.id,
        survey_id: survey.id,
        question_id: question.id,
        average_score: advisor_score,
        comments: "Historical advisor rating"
      )
    end

    survey_response = SurveyResponse.build(student: student, survey: survey)
    CompositeReportGenerator.new(survey_response: survey_response, cache: false).send(:render_html)
  end
end
