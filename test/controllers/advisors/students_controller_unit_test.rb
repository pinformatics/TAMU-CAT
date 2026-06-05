require "test_helper"

class Advisors::StudentsControllerUnitTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers

  tests Advisors::StudentsController

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in users(:advisor)
  end

  test "index redirects to student records" do
    with_routing do |set|
      set.draw do
        get "survey_records", to: "student_records#index", as: :survey_records
        namespace :advisors do
          get "students", to: "students#index"
        end
      end
      @routes = set

      get :index
      assert_redirected_to survey_records_path
    end
  end

  test "advisor_scope? is true for advisors" do
    assert_equal true, @controller.send(:advisor_scope?)
  end

  test "advisor_scope? is false for admins" do
    sign_out :user
    sign_in users(:admin)

    assert_equal false, @controller.send(:advisor_scope?)
  end

  test "update redirects back with model errors when update fails" do
    student = students(:student)
    student.errors.add(:track, "is invalid")

    student.stub(:update, false) do
      Student.stub(:find, student) do
        patch :update, params: { id: student.student_id, student: { track: "executive" } }
      end
    end

    assert_redirected_to advisors_student_path(student)
    assert_match(/is invalid/i, flash[:alert].to_s)
  end

  test "student_params permits track" do
    @controller.params = ActionController::Parameters.new(student: { track: "executive" })
    permitted = @controller.send(:student_params)
    assert_equal({ "track" => "executive" }, permitted.to_h)
  end
end
