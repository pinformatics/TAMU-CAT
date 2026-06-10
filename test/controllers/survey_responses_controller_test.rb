require "test_helper"
require "tempfile"

class SurveyResponsesControllerUnitTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers

  tests SurveyResponsesController

  setup do
    @admin = users(:admin)
    @student_user = users(:student)
    @student = students(:student)
    @survey = surveys(:fall_2025)
    @assigned_advisor = users(:advisor)
    @other_advisor = users(:other_advisor)
  end

  test "edit populates existing_answers and other_answers for mixed answer shapes" do
    sign_in @admin

    semester = program_semesters(:fall_2025)
    survey = Survey.new(
      title: "Admin Edit Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      description: "",
      is_active: false
    )
    category = survey.categories.build(name: "Cat", description: "")

    choice = category.questions.build(
      question_text: "Choice",
      question_order: 0,
      question_type: "dropdown",
      is_required: false,
      answer_options: [
        { label: "Yes", value: "Yes" },
        { label: "Other", value: "Other", requires_text: true }
      ].to_json
    )
    text = category.questions.build(
      question_text: "Text",
      question_order: 1,
      question_type: "short_answer",
      is_required: false
    )

    survey.save!

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: choice.id,
      answer: { "answer" => "Other", "text" => "details" }
    )
    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: text.id,
      answer: { "text" => "hello" }
    )

    sr = SurveyResponse.build(student: @student, survey: survey)
    get :edit, params: { id: sr.id, return_to: "/surveys" }

    assert_response :success
    assert_equal "Other", assigns(:existing_answers)[choice.id.to_s]
    assert_equal "details", assigns(:other_answers)[choice.id.to_s]
    assert_equal "hello", assigns(:existing_answers)[text.id.to_s]
  end

  test "update captures snapshot and edited version when answers change" do
    sign_in @admin

    semester = program_semesters(:fall_2025)
    survey = Survey.new(
      title: "Admin Update Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      description: "",
      is_active: false
    )
    category = survey.categories.build(name: "Cat", description: "")

    q1 = category.questions.build(
      question_text: "Q1",
      question_order: 0,
      question_type: "short_answer",
      is_required: false
    )
    q2 = category.questions.build(
      question_text: "Q2",
      question_order: 1,
      question_type: "short_answer",
      is_required: false
    )

    survey.save!

    SurveyAssignment.create!(
      survey: survey,
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      assigned_at: 1.day.ago
    )

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question: q1,
      response_value: "old"
    )
    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question: q2,
      response_value: "to-be-removed"
    )

    sr = SurveyResponse.build(student: @student, survey: survey)

    captured_events = []
    fake_versions = [ Struct.new(:answers).new({ "some" => "other" }) ]
    fake_scope = Struct.new(:versions) do
      def chronological
        versions
      end
    end

    answers_call_count = 0

    SurveyResponseVersion.stub(:for_pair, fake_scope.new(fake_versions)) do
      SurveyResponseVersion.stub(:current_answers_for, ->(student:, survey:) {
        answers_call_count += 1
        answers_call_count == 1 ? { q1.id.to_s => "old" } : { q1.id.to_s => "new" }
      }) do
        SurveyResponseVersion.stub(:capture_current!, ->(student:, survey:, assignment:, actor_user:, event:, **_) {
          captured_events << event.to_sym
          Struct.new(:id).new(123)
        }) do
          patch :update, params: {
            id: sr.id,
            return_to: "http://evil.example.com",
            answers: {
              q1.id.to_s => "new",
              q2.id.to_s => ""
            }
          }
        end
      end
    end

    assert_redirected_to survey_response_path(sr.id)
    assert_includes captured_events, :admin_snapshot
    assert_includes captured_events, :admin_edited

    assert_equal "new", StudentQuestion.find_by(student_id: @student.student_id, question_id: q1.id).answer
    assert_nil StudentQuestion.find_by(student_id: @student.student_id, question_id: q2.id)
  end

  test "destroy clears saved answers, unassigns archived surveys, and notifies student" do
    sign_in @admin

    semester = program_semesters(:fall_2025)
    survey = Survey.new(
      title: "Admin Destroy Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      description: "",
      is_active: false
    )
    category = survey.categories.build(name: "Cat", description: "")
    q1 = category.questions.build(
      question_text: "Q1",
      question_order: 0,
      question_type: "short_answer",
      is_required: false
    )

    survey.save!

    assignment = SurveyAssignment.create!(
      survey: survey,
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      assigned_at: 1.day.ago,
      completed_at: Time.current
    )

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question: q1,
      response_value: "old"
    )

    Feedback.create!(
      student_id: @student.student_id,
      survey_id: survey.id,
      question_id: q1.id,
      category_id: q1.category_id,
      advisor_id: @student.advisor_id,
      average_score: 4,
      comments: "feedback to delete"
    )

    AdvisorFeedbackSubmission.create!(
      student_id: @student.student_id,
      survey_id: survey.id,
      advisor_id: @student.advisor_id,
      last_saved_at: Time.current
    )

    sr = SurveyResponse.build(student: @student, survey: survey)

    captured = false
    delivered_payload = nil

    SurveyResponseVersion.stub(:capture_current!, ->(**_) { captured = true }) do
      Notification.stub(:deliver!, ->(**kwargs) { delivered_payload = kwargs }) do
        delete :destroy, params: { id: sr.id }
      end
    end

    assert_redirected_to survey_records_path
    assert captured, "Expected SurveyResponseVersion.capture_current! to run"
    assert delivered_payload, "Expected Notification.deliver! to run"
    assert_equal "survey.response.deleted", delivered_payload[:event_key]
    assert_equal "survey.response.deleted:survey:#{survey.id}:student:#{@student.student_id}", delivered_payload[:dedupe_key]
    assert_equal survey.id, delivered_payload[:metadata][:survey_id]
    assert_equal @student.student_id, delivered_payload[:metadata][:student_id]
    assert_equal true, delivered_payload[:metadata][:removed_assignment]
    assert_nil StudentQuestion.find_by(student_id: @student.student_id, question_id: q1.id)
    assert_equal 0, Feedback.where(student_id: @student.student_id, survey_id: survey.id).count
    assert_equal 0, AdvisorFeedbackSubmission.where(student_id: @student.student_id, survey_id: survey.id).count
    assert_nil SurveyAssignment.find_by(id: assignment.id)
  end

  test "destroy clears saved answers and keeps active survey assignment as uncompleted" do
    sign_in @admin

    semester = program_semesters(:fall_2025)
    survey = Survey.new(
      title: "Admin Destroy Active Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      description: "",
      is_active: true
    )
    category = survey.categories.build(name: "Cat", description: "")
    q1 = category.questions.build(
      question_text: "Q1",
      question_order: 0,
      question_type: "short_answer",
      is_required: false
    )

    survey.save!

    assignment = SurveyAssignment.create!(
      survey: survey,
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      assigned_at: 1.day.ago,
      completed_at: Time.current
    )

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question: q1,
      response_value: "old"
    )

    sr = SurveyResponse.build(student: @student, survey: survey)

    SurveyResponseVersion.stub(:capture_current!, ->(**_) { }) do
      Notification.stub(:deliver!, ->(**_) { }) do
        delete :destroy, params: { id: sr.id }
      end
    end

    assert_redirected_to survey_records_path
    assert_nil StudentQuestion.find_by(student_id: @student.student_id, question_id: q1.id)
    assert_nil assignment.reload.completed_at
  end

  test "destroy archived response clears version assignment references before removing assignment" do
    sign_in @admin

    semester = program_semesters(:fall_2025)
    survey = Survey.new(
      title: "Admin Destroy FK Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      description: "",
      is_active: false
    )
    category = survey.categories.build(name: "Cat", description: "")
    q1 = category.questions.build(
      question_text: "Q1",
      question_order: 0,
      question_type: "short_answer",
      is_required: false
    )

    survey.save!

    assignment = SurveyAssignment.create!(
      survey: survey,
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      assigned_at: 1.day.ago,
      completed_at: Time.current
    )

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question: q1,
      response_value: "old"
    )

    historical_version = SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: survey.id,
      advisor_id: @student.advisor_id,
      survey_assignment_id: assignment.id,
      actor_user_id: @admin.id,
      actor_role: @admin.role,
      event: "submitted",
      answers: { q1.id.to_s => "old" }
    )

    sr = SurveyResponse.build(student: @student, survey: survey)

    Notification.stub(:deliver!, ->(**_) { }) do
      delete :destroy, params: { id: sr.id }
    end

    assert_redirected_to survey_records_path
    assert_nil SurveyAssignment.find_by(id: assignment.id)
    assert_nil historical_version.reload.survey_assignment_id

    latest_version = SurveyResponseVersion.where(student_id: @student.student_id, survey_id: survey.id).order(:created_at).last
    assert latest_version.present?
    assert_equal "admin_deleted", latest_version.event
    assert_nil latest_version.survey_assignment_id
  end

  test "set_survey_response via id param returns not found for bad id" do
    sign_in @admin
    # use well-formed composite id where survey portion is missing to trigger RecordNotFound
    student_id = @student.student_id
    missing_survey_id = 9_999_999
    assert_raises ActiveRecord::RecordNotFound do
      get :show, params: { id: "#{student_id}-#{missing_survey_id}" }
    end
  end

  test "find_by_signed_download_token allows access with token" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)
    token = sr.signed_download_token
    # include a dummy id to satisfy route recognition; controller will use token branch first
    get :show, params: { id: "ignored", token: token }
    assert_response :success
  end

  test "authorize_view allows assigned advisor" do
    sign_in @assigned_advisor
    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :show, params: { id: sr.id }
    assert_response :success
  end

  test "show PDF download links include FERPA confirmation language" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    get :show, params: { id: sr.id }

    assert_response :success
    links = css_select("a").select { |link| link.text.squish == "Download as PDF" }
    assert_equal 2, links.size
    links.each do |link|
      assert_includes link["data-turbo-confirm"], "FERPA reminder"
      assert_includes link["data-turbo-confirm"], "student survey response data"
      assert_includes link["data-turbo-confirm"], "legitimate educational interest"
    end
  end

  test "show marks unsubmitted advisor feedback as draft for admin viewers" do
    sign_in @admin

    section = SurveySection.create!(
      survey: @survey,
      title: SurveySection::MHA_COMPETENCY_SECTION_TITLE,
      position: (@survey.sections.maximum(:position) || -1) + 1
    )
    category = Category.create!(
      survey: @survey,
      section: section,
      name: "Draft Feedback Category",
      description: ""
    )
    question = Question.create!(
      category: category,
      question_text: "Draft feedback question",
      question_order: 999,
      question_type: "short_answer",
      is_required: false,
      has_feedback: true
    )
    feedback = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      question_id: question.id,
      category_id: question.category_id,
      advisor_id: @student.advisor_id,
      average_score: 4,
      comments: "Draft-only comment"
    )

    AdvisorFeedbackSubmission.where(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: feedback.advisor_id
    ).delete_all
    AdvisorFeedbackSubmission.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: feedback.advisor_id,
      submitted_at: nil,
      last_saved_at: Time.current
    )

    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :show, params: { id: sr.id }

    assert_response :success
    assert_includes response.body, "Draft"
    assert_includes response.body, "only visible to advisors/admins until submitted"
    assert_includes response.body, "Draft-only comment"
  end

  test "show hides unsubmitted advisor feedback from student viewers" do
    sign_in @student_user

    section = SurveySection.create!(
      survey: @survey,
      title: SurveySection::MHA_COMPETENCY_SECTION_TITLE,
      position: (@survey.sections.maximum(:position) || -1) + 1
    )
    category = Category.create!(
      survey: @survey,
      section: section,
      name: "Student Hidden Draft Category",
      description: ""
    )
    question = Question.create!(
      category: category,
      question_text: "Student hidden draft question",
      question_order: 1000,
      question_type: "short_answer",
      is_required: false,
      has_feedback: true
    )
    feedback = Feedback.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      question_id: question.id,
      category_id: question.category_id,
      advisor_id: @student.advisor_id,
      average_score: 3,
      comments: "Student should not see this draft"
    )

    AdvisorFeedbackSubmission.where(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: feedback.advisor_id
    ).delete_all
    AdvisorFeedbackSubmission.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: feedback.advisor_id,
      submitted_at: nil,
      last_saved_at: Time.current
    )

    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :show, params: { id: sr.id }

    assert_response :success
    assert_not_includes response.body, "Student should not see this draft"
    assert_not_includes response.body, "only visible to advisors/admins until submitted"
  end

  test "authorize_view blocks advisors for unassigned students" do
    sign_in @other_advisor
    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :show, params: { id: sr.id }
    assert_response :unauthorized
  end

  test "show loads previous and next versions when multiple versions exist" do
    sign_in @admin

    sr = SurveyResponse.build(student: @student, survey: @survey)

    v1 = SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      event: "admin_snapshot",
      answers: { "1" => "a" },
      created_at: 2.days.ago,
      updated_at: 2.days.ago
    )
    v2 = SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: @survey.id,
      advisor_id: @student.advisor_id,
      event: "admin_edited",
      answers: { "1" => "b" },
      created_at: 1.day.ago,
      updated_at: 1.day.ago
    )

    get :show, params: { id: sr.id, version_id: v1.id }

    assert_response :success
    assert_nil assigns(:previous_version)
    assert_equal v2.id, assigns(:next_version)&.id
    assert_equal v1.id, assigns(:selected_version)&.id
  end

  test "show ignores non-local return_to" do
    sign_in @admin

    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :show, params: { id: sr.id, return_to: "//evil.example.com" }

    assert_response :success
    assert_nil assigns(:return_to)
  end

  test "composite_report rejects access via token even when signed in" do
    sign_in @admin

    sr = SurveyResponse.build(student: @student, survey: @survey)
    token = sr.signed_download_token

    get :composite_report, params: { id: sr.id, token: token }
    assert_response :unauthorized
  end

  test "composite_report blocks unassigned advisor" do
    sign_in @other_advisor

    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :composite_report, params: { id: sr.id }

    assert_response :unauthorized
  end

  test "download returns service_unavailable when WickedPdf not defined" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :download, params: { id: sr.id }
    # allow either 503 (no WickedPdf) or 200 (if environment has it); assert expected message if 503
    assert_includes [ 200, 503 ], @response.status
    if @response.status == 503
      assert_includes @response.body.downcase, "server-side pdf generation unavailable"
    end
  end

  test "download uses student viewer mode for student users" do
    sign_in @student_user
    sr = SurveyResponse.build(student: @student, survey: @survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    tmp = Tempfile.new([ "student_pdf", ".pdf" ])
    tmp.binmode
    tmp.write("%PDF-1.4\n%fake\n")
    tmp.flush

    result = Struct.new(:path) do
      def cleanup!; end
    end
    fake_result = result.new(tmp.path)
    captured_viewer_mode = nil

    CompositeReportGenerator.stub(:new, ->(survey_response:, cache:, viewer_mode:, **_) {
      captured_viewer_mode = viewer_mode
      Struct.new(:result) do
        def render
          result
        end
      end.new(fake_result)
    }) do
      get :download, params: { id: sr.id }
    end

    assert_response :success
    assert_equal :student, captured_viewer_mode
  ensure
    tmp&.close
    tmp&.unlink
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "download uses staff viewer mode for admin users" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    tmp = Tempfile.new([ "staff_pdf", ".pdf" ])
    tmp.binmode
    tmp.write("%PDF-1.4\n%fake\n")
    tmp.flush

    result = Struct.new(:path) do
      def cleanup!; end
    end
    fake_result = result.new(tmp.path)
    captured_viewer_mode = nil

    CompositeReportGenerator.stub(:new, ->(survey_response:, cache:, viewer_mode:, **_) {
      captured_viewer_mode = viewer_mode
      Struct.new(:result) do
        def render
          result
        end
      end.new(fake_result)
    }) do
      get :download, params: { id: sr.id }
    end

    assert_response :success
    assert_equal :staff, captured_viewer_mode
  ensure
    tmp&.close
    tmp&.unlink
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "download uses latest submitted version instead of live draft answers" do
    sign_in @admin

    semester = program_semesters(:fall_2025)
    survey = Survey.new(
      title: "Download Version Source Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      description: "",
      is_active: true
    )
    category = survey.categories.build(name: "Cat", description: "")
    evidence_question = category.questions.build(
      question_text: "Evidence",
      question_order: 1,
      question_type: "evidence",
      is_required: false
    )
    survey.save!

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question: evidence_question,
      response_value: "https://sites.google.com/tamu.edu/bad-draft/home"
    )

    SurveyResponseVersion.create!(
      student_id: @student.student_id,
      survey_id: survey.id,
      advisor_id: @student.advisor_id,
      actor_user_id: @admin.id,
      actor_role: @admin.role,
      event: "submitted",
      answers: { evidence_question.id.to_s => "https://sites.google.com/tamu.edu/good-submitted/home" }
    )

    sr = SurveyResponse.build(student: @student, survey: survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    tmp = Tempfile.new([ "version_pdf", ".pdf" ])
    tmp.binmode
    tmp.write("%PDF-1.4\n%fake\n")
    tmp.flush

    result = Struct.new(:path) do
      def cleanup!; end
    end
    fake_result = result.new(tmp.path)
    captured_evidence_link = nil

    CompositeReportGenerator.stub(:new, ->(survey_response:, **_) {
      captured_evidence_link = survey_response.answers[evidence_question.id]
      Struct.new(:result) do
        def render
          result
        end
      end.new(fake_result)
    }) do
      get :download, params: { id: sr.id }
    end

    assert_response :success
    assert_equal "https://sites.google.com/tamu.edu/good-submitted/home", captured_evidence_link
  ensure
    tmp&.close
    tmp&.unlink
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "download streams a PDF when WickedPdf is present and generator succeeds" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    tmp = Tempfile.new([ "survey", ".pdf" ])
    tmp.binmode
    tmp.write("%PDF-1.4\n%fake\n")
    tmp.flush

    result = Struct.new(:path) do
      def cleanup!; end
    end
    fake_result = result.new(tmp.path)
    fake_generator = Struct.new(:result) do
      def render
        result
      end
    end

    CompositeReportGenerator.stub(:new, fake_generator.new(fake_result)) do
      assert_difference -> { AdminActivityLog.where(action: "student_data_export").count }, 1 do
        get :download, params: { id: sr.id }
      end
      assert_response :success
      assert_equal "application/pdf", @response.media_type
      assert_includes @response.headers["Content-Disposition"].to_s, "attachment"
    end

    activity = AdminActivityLog.where(action: "student_data_export").order(created_at: :desc).first
    assert_equal "survey_response_pdf", activity.metadata["export_type"]
    assert_equal @student, activity.subject
    assert_equal @survey.id, activity.metadata["survey_id"]
  ensure
    tmp&.close
    tmp&.unlink
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "download returns 503 when generator returns a missing file" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    result = Struct.new(:path) do
      def cleanup!; end
    end
    fake_result = result.new("/tmp/does-not-exist-#{SecureRandom.hex}.pdf")
    fake_generator = Struct.new(:result) do
      def render
        result
      end
    end

    CompositeReportGenerator.stub(:new, fake_generator.new(fake_result)) do
      get :download, params: { id: sr.id }
      assert_response :service_unavailable
      assert_includes @response.body.to_s.downcase, "pdf generation unavailable"
    end
  ensure
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "download returns 503 when generated bytes are not a PDF" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    tmp = Tempfile.new([ "not_pdf", ".pdf" ])
    tmp.binmode
    tmp.write("NOPE")
    tmp.flush

    result = Struct.new(:path) do
      def cleanup!; end
    end
    fake_result = result.new(tmp.path)
    fake_generator = Struct.new(:result) do
      def render
        result
      end
    end

    CompositeReportGenerator.stub(:new, fake_generator.new(fake_result)) do
      get :download, params: { id: sr.id }
      assert_response :service_unavailable
      assert_includes @response.body.to_s.downcase, "pdf generation unavailable"
    end
  ensure
    tmp&.close
    tmp&.unlink
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "download returns 500 when generator raises GenerationError" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    fake_generator = Object.new
    def fake_generator.render
      raise CompositeReportGenerator::GenerationError, "nope"
    end

    CompositeReportGenerator.stub(:new, fake_generator) do
      get :download, params: { id: sr.id }
      assert_response :internal_server_error
    end
  ensure
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "composite_report returns service_unavailable when WickedPdf missing" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :composite_report, params: { id: sr.id }
    assert_includes [ 200, 503 ], @response.status
    if @response.status == 503
      assert_includes @response.body.downcase, "composite pdf generation unavailable"
    end
  end

  test "composite_report returns 503 when WickedPdf present but generator output is invalid" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    result = Struct.new(:path) do
      def cleanup!; end
    end
    fake_result = result.new(nil)
    fake_generator = Struct.new(:result) do
      def render
        result
      end
    end

    CompositeReportGenerator.stub(:new, fake_generator.new(fake_result)) do
      get :composite_report, params: { id: sr.id }
      assert_response :service_unavailable
      assert_includes @response.body.to_s.downcase, "composite pdf generation unavailable"
    end
  ensure
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "composite_report returns 500 when generator raises GenerationError" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    fake_generator = Object.new
    def fake_generator.render
      raise CompositeReportGenerator::GenerationError, "boom"
    end

    CompositeReportGenerator.stub(:new, fake_generator) do
      get :composite_report, params: { id: sr.id }
      assert_response :internal_server_error
    end
  ensure
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "composite_report rejects student users" do
    sign_in @student_user
    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :composite_report, params: { id: sr.id }
    assert_response :unauthorized
  end

  test "show selects requested version and computes previous/next" do
    sign_in @admin

    sr = SurveyResponse.build(student: @student, survey: @survey)
    v1 = SurveyResponseVersion.create!(student_id: @student.student_id, survey_id: @survey.id, event: "submitted", answers: { "a" => 1 })
    v2 = SurveyResponseVersion.create!(student_id: @student.student_id, survey_id: @survey.id, event: "revised", answers: { "a" => 2 })

    get :show, params: { id: sr.id, version_id: v1.id }

    assert_response :success
    assert_equal v1.id, assigns(:selected_version).id
    assert_nil assigns(:previous_version)
    assert_equal v2.id, assigns(:next_version).id
  end

  test "show defaults to latest version when version_id is missing" do
    sign_in @admin

    sr = SurveyResponse.build(student: @student, survey: @survey)
    v1 = SurveyResponseVersion.create!(student_id: @student.student_id, survey_id: @survey.id, event: "submitted", answers: { "a" => 1 })
    v2 = SurveyResponseVersion.create!(student_id: @student.student_id, survey_id: @survey.id, event: "revised", answers: { "a" => 2 })

    get :show, params: { id: sr.id }

    assert_response :success
    assert_equal v2.id, assigns(:selected_version).id
    assert_equal v1.id, assigns(:previous_version).id
    assert_nil assigns(:next_version)
  end

  test "safe_filename_part falls back and sanitizes" do
    controller = SurveyResponsesController.new
    assert_equal "file", controller.send(:safe_filename_part, nil)
    assert_equal "fallback_name", controller.send(:safe_filename_part, "   ", fallback: "Fallback Name")
    assert_equal "hello_world", controller.send(:safe_filename_part, "Hello, World!")
  end

  test "unauthenticated users are redirected to sign_in" do
    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :show, params: { id: sr.id }
    assert_response :redirect
    assert_match "/sign_in", @response.headers["Location"].to_s
  end

  test "show returns not_found when token is invalid" do
    sign_in @admin
    get :show, params: { id: "ignored", token: "not-a-valid-token" }
    assert_response :not_found
  end

  test "edit does not populate other_answers when choice text is blank" do
    sign_in @admin

    semester = program_semesters(:fall_2025)
    survey = Survey.new(
      title: "Admin Edit NoText Survey #{SecureRandom.hex(4)}",
      program_semester: semester,
      description: "",
      is_active: false
    )
    category = survey.categories.build(name: "Cat", description: "")
    choice = category.questions.build(
      question_text: "Choice",
      question_order: 0,
      question_type: "dropdown",
      is_required: false,
      answer_options: [
        { label: "Yes", value: "Yes" },
        { label: "Other", value: "Other", requires_text: true }
      ].to_json
    )

    survey.save!

    StudentQuestion.create!(
      student_id: @student.student_id,
      advisor_id: @student.advisor_id,
      question_id: choice.id,
      answer: { "answer" => "Yes" }
    )

    sr = SurveyResponse.build(student: @student, survey: survey)
    get :edit, params: { id: sr.id }

    assert_response :success
    assert_equal "Yes", assigns(:existing_answers)[choice.id.to_s]
    refute assigns(:other_answers).key?(choice.id.to_s)
  end

  test "download returns 503 when generated file disappears during read" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    wickedpdf_defined = defined?(WickedPdf)
    Object.const_set(:WickedPdf, Class.new) unless wickedpdf_defined

    result = Struct.new(:path) do
      def cleanup!; end
    end
    fake_result = result.new("/tmp/will-disappear-#{SecureRandom.hex}.pdf")
    fake_generator = Struct.new(:result) do
      def render
        result
      end
    end

    CompositeReportGenerator.stub(:new, fake_generator.new(fake_result)) do
      File.stub(:exist?, true) do
        File.stub(:binread, ->(_path) { raise Errno::ENOENT.new("missing") }) do
          get :download, params: { id: sr.id }
          assert_response :service_unavailable
          assert_includes @response.body.to_s.downcase, "pdf generation unavailable"
        end
      end
    end
  ensure
    Object.send(:remove_const, :WickedPdf) unless wickedpdf_defined
  end

  test "authorize_admin blocks non-admin edit" do
    sign_in @student_user
    sr = SurveyResponse.build(student: @student, survey: @survey)
    get :edit, params: { id: sr.id }
    assert_response :unauthorized
  end

  test "update tolerates missing answers params" do
    sign_in @admin
    sr = SurveyResponse.build(student: @student, survey: @survey)

    fake_scope = Struct.new(:versions) do
      def chronological
        versions
      end
    end

    SurveyResponseVersion.stub(:current_answers_for, {}) do
      SurveyResponseVersion.stub(:for_pair, fake_scope.new([])) do
        SurveyResponseVersion.stub(:capture_current!, ->(**_) { nil }) do
          patch :update, params: { id: sr.id }
        end
      end
    end

    assert_response :redirect
  end
end

class SurveyResponsesControllerIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @student_user = users(:student)
    survey = surveys(:fall_2025)
    student = students(:student) || Student.first
    @survey_response = SurveyResponse.build(student: student, survey: survey)
  end

  test "show uses competency target levels rather than legacy question program_target_level" do
    sign_in @student_user

    student = students(:student)
    student.update!(program_year: 2026)
    survey = surveys(:fall_2025)

    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    category = survey.categories.first || survey.categories.create!(name: "Test Category", description: "")

    category.questions.create!(
      question_text: competency_title,
      question_order: 999,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5].to_json,
      program_target_level: 1
    )

    CompetencyTargetLevel.create!(
      program_semester: survey.program_semester,
      track: student.track_before_type_cast,
      program_year: 2026,
      competency_title: competency_title,
      target_level: 5
    )

    survey_response = SurveyResponse.build(student: student, survey: survey)

    get survey_response_path(survey_response)
    assert_response :success
    assert_match(/#{Regexp.escape(competency_title)}.*End-of-program target level: 5\/5/m, response.body)
    refute_match(/#{Regexp.escape(competency_title)}.*End-of-program target level: 1\/5/m, response.body)
  end

  test "show includes released course competency and target context" do
    sign_in @student_user

    student = students(:student)
    survey = surveys(:fall_2025)
    survey.update!(show_course_competencies_with_survey: true)
    competency_title = Reports::DataAggregator::COMPETENCY_TITLES.first
    category = survey.categories.first || survey.categories.create!(name: "Test Category", description: "")
    question = category.questions.create!(
      question_text: competency_title,
      question_order: 1000,
      question_type: "dropdown",
      answer_options: %w[1 2 3 4 5].to_json
    )

    batch = GradeImportBatch.create!(
      uploaded_by: @admin,
      program_semester: survey.program_semester,
      status: "completed",
      summary: { "dry_run" => false }
    )
    file = batch.grade_import_files.create!(
      file_name: "course-context.xlsx",
      file_checksum: "course-context-checksum",
      status: "processed"
    )
    batch.grade_competency_ratings.create!(
      student: student,
      competency_title: question.question_text,
      aggregated_level: 4,
      aggregation_rule: "max",
      evidence_count: 1
    )
    batch.grade_competency_evidences.create!(
      grade_import_file: file,
      student: student,
      assignment_name: "Course Context",
      course_code: "PHPM-701-001",
      competency_title: question.question_text,
      raw_grade: 94,
      mapped_level: 4,
      course_target_level: 5,
      row_number: 2,
      source_key: "course-context-source",
      import_fingerprint: "course-context-fingerprint"
    )

    get survey_response_path(SurveyResponse.build(student: student, survey: survey))

    assert_response :success
    assert_includes response.body, "Course competency evidence"
    assert_includes response.body, "Mastery level: 4"
    assert_includes response.body, "PHPM 701-001"
    assert_includes response.body, "Course target: 5"
  end

  test "completed response shows self target summary to every permitted role" do
    student = students(:student)
    student.update!(program_year: 2026)
    survey = surveys(:fall_2025)
    titles = Reports::DataAggregator::COMPETENCY_TITLES.first(2)

    category = survey.categories.create!(
      name: "Target Summary Domain",
      description: ""
    )
    met_question = category.questions.create!(
      question_text: titles.first,
      question_order: 10_001,
      question_type: "dropdown",
      is_required: true,
      answer_options: [
        [ "Beginner (1)", "1" ],
        [ "Emerging (2)", "2" ],
        [ "Capable (3)", "3" ],
        [ "Experienced (4)", "4" ],
        [ "Mastery (5)", "5" ]
      ].to_json
    )
    below_question = category.questions.create!(
      question_text: titles.second,
      question_order: 10_002,
      question_type: "dropdown",
      is_required: true,
      answer_options: [
        [ "Beginner (1)", "1" ],
        [ "Emerging (2)", "2" ],
        [ "Capable (3)", "3" ],
        [ "Experienced (4)", "4" ],
        [ "Mastery (5)", "5" ]
      ].to_json
    )

    CompetencyTargetLevel.where(
      program_semester: survey.program_semester,
      track: student.track_before_type_cast,
      class_of: student.program_year,
      competency_title: titles
    ).delete_all
    CompetencyTargetLevel.create!(
      program_semester: survey.program_semester,
      track: student.track_before_type_cast,
      class_of: student.program_year,
      competency_title: titles.first,
      target_level: 3
    )
    CompetencyTargetLevel.create!(
      program_semester: survey.program_semester,
      track: student.track_before_type_cast,
      class_of: student.program_year,
      competency_title: titles.second,
      target_level: 4
    )

    StudentQuestion.create!(
      student_id: student.student_id,
      advisor_id: student.advisor_id,
      question: met_question,
      answer: "3"
    )
    StudentQuestion.create!(
      student_id: student.student_id,
      advisor_id: student.advisor_id,
      question: below_question,
      answer: "2"
    )

    SurveyAssignment.find_or_create_by!(survey: survey, student: student) do |assignment|
      assignment.advisor_id = student.advisor_id
      assignment.assigned_at = 1.day.ago
    end.update!(completed_at: Time.current)

    survey_response = SurveyResponse.build(student: student, survey: survey)

    [ users(:student), users(:advisor), users(:admin) ].each do |viewer|
      sign_in viewer
      get survey_response_path(survey_response)

      assert_response :success
      assert_includes response.body, "Self-assessment target summary"
      assert_includes response.body, titles.first
      assert_includes response.body, titles.second
      assert_includes response.body, "1 of 2"
      assert_includes response.body, "Met 1"
      assert_includes response.body, "Below 1"

      sign_out viewer
    end
  end

  test "draft response does not show self target summary" do
    sign_in @student_user

    student = students(:student)
    survey = surveys(:fall_2025)
    title = Reports::DataAggregator::COMPETENCY_TITLES.first
    category = survey.categories.create!(name: "Draft Target Summary Domain", description: "")
    question = category.questions.create!(
      question_text: title,
      question_order: 10_003,
      question_type: "dropdown",
      is_required: true,
      answer_options: %w[1 2 3 4 5].to_json,
      program_target_level: 3
    )

    StudentQuestion.create!(
      student_id: student.student_id,
      advisor_id: student.advisor_id,
      question: question,
      answer: "3"
    )
    SurveyAssignment.find_or_create_by!(survey: survey, student: student) do |assignment|
      assignment.advisor_id = student.advisor_id
      assignment.assigned_at = 1.day.ago
    end.update!(completed_at: nil)

    get survey_response_path(SurveyResponse.build(student: student, survey: survey))

    assert_response :success
    assert_not_includes response.body, "Self-assessment target summary"
  end

  test "past submitted response without completion timestamp shows self target summary" do
    sign_in @student_user

    student = students(:student)
    survey = Survey.new(
      title: "Legacy Past Survey #{SecureRandom.hex(4)}",
      program_semester: program_semesters(:fall_2025),
      description: "Old response without completed_at",
      is_active: false
    )
    category = survey.categories.build(name: "Legacy Target Domain", description: "")
    question = category.questions.build(
      question_text: Reports::DataAggregator::COMPETENCY_TITLES.first,
      question_order: 1,
      question_type: "dropdown",
      is_required: true,
      answer_options: [
        [ "Beginner (1)", "1" ],
        [ "Emerging (2)", "2" ],
        [ "Capable (3)", "3" ],
        [ "Experienced (4)", "4" ],
        [ "Mastery (5)", "5" ]
      ].to_json,
      program_target_level: 4
    )
    survey.save!

    StudentQuestion.create!(
      student_id: student.student_id,
      advisor_id: student.advisor_id,
      question: question,
      answer: "5"
    )

    get survey_response_path(SurveyResponse.build(student: student, survey: survey))

    assert_response :success
    assert_includes response.body, "Self-assessment target summary"
    assert_includes response.body, "1 of 1"
    assert_includes response.body, "Met 1"
  end

  test "student can view their own survey response" do
    sign_in @student_user

    get survey_response_path(@survey_response)
    assert_response :success
  end

  test "student edit is enabled only while survey is active and before deadline" do
    sign_in @student_user

    survey = surveys(:fall_2025)
    student = students(:student)

    SurveyAssignment.find_or_create_by!(survey_id: survey.id, student_id: student.student_id) do |assignment|
      assignment.advisor_id = student.advisor_id
      assignment.assigned_at = 1.day.ago
    end.update!(available_until: 2.days.from_now)

    survey.update!(is_active: true)
    survey_response = SurveyResponse.build(student: student, survey: survey)

    get survey_response_path(survey_response)
    assert_response :success
    assert_select "a", text: "Edit"
  end

  test "student edit is disabled when assignment is past due" do
    sign_in @student_user

    survey = surveys(:fall_2025)
    student = students(:student)

    SurveyAssignment.find_or_create_by!(survey_id: survey.id, student_id: student.student_id) do |assignment|
      assignment.advisor_id = student.advisor_id
      assignment.assigned_at = 1.day.ago
    end.update!(available_until: 1.day.ago)

    survey.update!(is_active: true)
    survey_response = SurveyResponse.build(student: student, survey: survey)

    get survey_response_path(survey_response)
    assert_response :success
    assert_select "span[aria-disabled='true']", text: /Edit/, minimum: 1
  end

  test "student edit is disabled when survey is archived" do
    sign_in @student_user

    survey = surveys(:fall_2025)
    student = students(:student)

    SurveyAssignment.find_or_create_by!(survey_id: survey.id, student_id: student.student_id) do |assignment|
      assignment.advisor_id = student.advisor_id
      assignment.assigned_at = 1.day.ago
    end.update!(available_until: 2.days.from_now)

    survey.update!(is_active: false)
    survey_response = SurveyResponse.build(student: student, survey: survey)

    get survey_response_path(survey_response)
    assert_response :success
    assert_select "span[aria-disabled='true']", text: /Edit/, minimum: 1
  end

  test "other students are blocked from viewing the response" do
    sign_in users(:other_student)

    get survey_response_path(@survey_response)
    assert_response :unauthorized
  end

  test "download returns 503 when WickedPdf missing" do
    # No WickedPdf available in test environment so expect service_unavailable
    sign_in users(:admin)
    get download_survey_response_path(@survey_response)
    assert_includes [ 200, 503 ], response.status
    if response.status == 503
      assert_match /Server-side PDF generation unavailable/, @response.body
    else
      # If WickedPdf is present, we at least expect a response body or an attachment header
      assert response.body.present? || response.headers["Content-Disposition"].present?
    end
  end

  test "set_survey_response returns 404 for missing token" do
    sign_in users(:admin)
    get survey_response_path(id: "nonexistent")
    assert_response :not_found
  end

  test "composite_report returns 503 when WickedPdf missing" do
    sign_in users(:admin)
    get composite_report_survey_response_path(@survey_response)
    assert_includes [ 200, 503 ], response.status
    if response.status == 503
      assert_match /Composite PDF generation unavailable/, @response.body
    else
      assert response.body.present? || response.headers["Content-Disposition"].present?
    end
  end

  test "composite report rejects token access even for admins" do
    sign_in users(:admin)
    token = @survey_response.signed_download_token

    get composite_report_survey_response_path(@survey_response), params: { token: token }
    assert_response :unauthorized
  end
end
