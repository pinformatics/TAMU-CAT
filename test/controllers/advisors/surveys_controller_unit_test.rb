require "test_helper"

class Advisors::SurveysControllerUnitTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers

  tests Advisors::SurveysController

  setup do
    @request.env["devise.mapping"] = Devise.mappings[:user]
    sign_in users(:advisor)
  end

  test "legacy index redirects to shared survey assignments" do
    with_routing do |set|
      set.draw do
        get "assignments/surveys", to: "assignments/surveys#index", as: :assignments_surveys
        namespace :advisors do
          get "surveys", to: "surveys#index"
        end
      end
      @routes = set

      get :index

      assert_redirected_to assignments_surveys_path
    end
  end

  test "legacy show redirects to shared survey assignment detail" do
    survey = surveys(:fall_2025)

    with_routing do |set|
      set.draw do
        get "assignments/surveys/:id", to: "assignments/surveys#show", as: :assignments_survey
        namespace :advisors do
          get "surveys/:id", to: "surveys#show"
        end
      end
      @routes = set

      get :show, params: { id: survey.id }

      assert_redirected_to assignments_survey_path(survey)
    end
  end
end
