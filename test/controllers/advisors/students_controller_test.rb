require "test_helper"

class Advisors::StudentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @advisor_user = users(:advisor)
    @student = students(:student)
  end

  test "show renders the student details" do
    sign_in @advisor_user

    get advisors_student_path(@student)
    assert_response :success
    assert_select "body", /#{@student.user.name}/
  end

  test "update changes track with valid input" do
    sign_in @advisor_user

    I18n.stub(:l, ->(*) { raise I18n::MissingTranslationData.new(:en, :time) }) do
      patch advisors_student_path(@student), params: { student: { track: "executive" } }
    end

    assert_redirected_to advisors_student_path(@student)
    assert_equal "executive", @student.reload.track_key
    assert_equal "Executive", @student.track
    assert_match "Track changed", flash[:notice]
  ensure
    @student.update!(track: "residential")
  end

  test "update rejects invalid track values" do
    sign_in @advisor_user

    patch advisors_student_path(@student), params: { student: { track: "" } }
    assert_redirected_to survey_records_path
    assert_match "We could not change the track", flash[:alert]
  end

  test "update handles missing student" do
    sign_in @advisor_user

    patch advisors_student_path("missing"), params: { student: { track: "executive" } }
    assert_redirected_to survey_records_path
    assert_equal "Student not found.", flash[:alert]
  end

  test "non-advisors are redirected away" do
    sign_in users(:student)

    get advisors_student_path(@student)
    assert_redirected_to dashboard_path
    assert_equal ApplicationController::ADVISOR_ONLY_MESSAGE, flash[:alert]
  end
end
