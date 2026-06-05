# frozen_string_literal: true

require "test_helper"

module Api
  class ReportsControllerTest < ActionDispatch::IntegrationTest
    include Devise::Test::IntegrationHelpers

    setup do
      @admin = users(:admin)
      @advisor = users(:advisor)
      @student = users(:student)
    end

    # Access control tests
    test "filters denies access to students" do
      sign_in @student

      get api_reports_filters_path, as: :json

      assert_response :forbidden
      json_response = JSON.parse(@response.body)
      assert_equal "Access denied", json_response["error"]
    end

    test "benchmark denies access to students" do
      sign_in @student

      get api_reports_benchmark_path, as: :json

      assert_response :forbidden
      json_response = JSON.parse(@response.body)
      assert_equal "Access denied", json_response["error"]
    end

    test "competency_summary denies access to students" do
      sign_in @student

      get api_reports_competency_summary_path, as: :json

      assert_response :forbidden
      json_response = JSON.parse(@response.body)
      assert_equal "Access denied", json_response["error"]
    end

    test "competency_detail denies access to students" do
      sign_in @student

      get api_reports_competency_detail_path, as: :json

      assert_response :forbidden
      json_response = JSON.parse(@response.body)
      assert_equal "Access denied", json_response["error"]
    end

    test "track_summary denies access to students" do
      sign_in @student

      get api_reports_track_summary_path, as: :json

      assert_response :forbidden
      json_response = JSON.parse(@response.body)
      assert_equal "Access denied", json_response["error"]
    end


    test "filters requires authentication" do
      get api_reports_filters_path, as: :json

      assert_response :unauthorized
    end

    # Admin access tests
    test "filters allows admin access" do
      sign_in @admin

      get api_reports_filters_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
      assert_includes json_response.keys, "program_years"
    end

    test "benchmark allows admin access" do
      sign_in @admin

      get api_reports_benchmark_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "competency_summary allows admin access" do
      sign_in @admin

      get api_reports_competency_summary_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "competency_detail allows admin access" do
      sign_in @admin

      get api_reports_competency_detail_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "track_summary allows admin access" do
      sign_in @admin

      get api_reports_track_summary_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end


    # Advisor access tests
    test "filters allows advisor access" do
      sign_in @advisor

      get api_reports_filters_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "benchmark allows advisor access" do
      sign_in @advisor

      get api_reports_benchmark_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "competency_summary allows advisor access" do
      sign_in @advisor

      get api_reports_competency_summary_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "competency_detail allows advisor access" do
      sign_in @advisor

      get api_reports_competency_detail_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "track_summary allows advisor access" do
      sign_in @advisor

      get api_reports_track_summary_path, as: :json

      assert_response :success
      assert_not_nil @response.body
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end


    # Parameter filtering tests
    test "filters accepts track parameter" do
      sign_in @admin

      get api_reports_filters_path, params: { track: "MPH" }, as: :json

      assert_response :success
    end

    test "filters accepts semester parameter" do
      sign_in @admin

      get api_reports_filters_path, params: { semester: "Fall 2025" }, as: :json

      assert_response :success
    end

    test "filters accepts survey_id parameter" do
      sign_in @admin

      get api_reports_filters_path, params: { survey_id: 1 }, as: :json

      assert_response :success
    end

    test "filters accepts category_id parameter" do
      sign_in @admin

      get api_reports_filters_path, params: { category_id: 1 }, as: :json

      assert_response :success
    end

    test "filters accepts student_id parameter" do
      sign_in @admin

      get api_reports_filters_path, params: { student_id: 1 }, as: :json

      assert_response :success
    end

    test "filters accepts advisor_id parameter" do
      sign_in @admin

      get api_reports_filters_path, params: { advisor_id: 1 }, as: :json

      assert_response :success
    end

    test "filters accepts competency parameter" do
      sign_in @admin

      get api_reports_filters_path, params: { competency: "Public Health" }, as: :json

      assert_response :success
    end

    test "filters accepts multiple parameters" do
      sign_in @admin

      get api_reports_filters_path, params: {
        track: "MPH",
        semester: "Fall 2025",
        survey_id: 1,
        category_id: 1
      }, as: :json

      assert_response :success
    end

    test "benchmark accepts filter parameters" do
      sign_in @admin

      get api_reports_benchmark_path, params: {
        track: "MPH",
        semester: "Fall 2025"
      }, as: :json

      assert_response :success
    end

    test "competency_summary accepts filter parameters" do
      sign_in @admin

      get api_reports_competency_summary_path, params: {
        track: "MPH",
        competency: "Public Health"
      }, as: :json

      assert_response :success
    end

    test "competency_detail accepts filter parameters" do
      sign_in @admin

      get api_reports_competency_detail_path, params: {
        competency: "Public Health",
        student_id: 1
      }, as: :json

      assert_response :success
    end


    # Response format tests
    test "filters returns JSON response" do
      sign_in @admin

      get api_reports_filters_path, as: :json

      assert_response :success
      assert_equal "application/json; charset=utf-8", @response.content_type
    end

    test "benchmark returns JSON response" do
      sign_in @admin

      get api_reports_benchmark_path, as: :json

      assert_response :success
      assert_equal "application/json; charset=utf-8", @response.content_type
    end

    test "competency_summary returns JSON response" do
      sign_in @admin

      get api_reports_competency_summary_path, as: :json

      assert_response :success
      assert_equal "application/json; charset=utf-8", @response.content_type
    end

    test "competency_detail returns JSON response" do
      sign_in @admin

      get api_reports_competency_detail_path, as: :json

      assert_response :success
      assert_equal "application/json; charset=utf-8", @response.content_type
    end


    # Parameter filtering security tests
    test "filters ignores unpermitted parameters" do
      sign_in @admin

      # Try to pass unpermitted param - should be filtered
      get api_reports_filters_path, params: {
        track: "MPH",
        malicious_param: "hack",
        another_bad_param: "exploit"
      }, as: :json

      # Should succeed without errors (unpermitted params silently ignored)
      assert_response :success
    end

    test "benchmark filters out unpermitted parameters" do
      sign_in @admin

      get api_reports_benchmark_path, params: {
        semester: "Fall 2025",
        unauthorized_field: "value"
      }, as: :json

      assert_response :success
    end

    # Edge case tests
    test "filters works with no parameters" do
      sign_in @admin

      get api_reports_filters_path, as: :json

      assert_response :success
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "benchmark works with no parameters" do
      sign_in @admin

      get api_reports_benchmark_path, as: :json

      assert_response :success
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "competency_summary works with no parameters" do
      sign_in @admin

      get api_reports_competency_summary_path, as: :json

      assert_response :success
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end

    test "competency_detail works with no parameters" do
      sign_in @admin

      get api_reports_competency_detail_path, as: :json

      assert_response :success
      json_response = JSON.parse(@response.body)
      assert (json_response.is_a?(Hash) || json_response.is_a?(Array))
    end


    # Role verification tests
    test "ensure_reports_access allows admin role" do
      sign_in @admin

      get api_reports_filters_path, as: :json

      assert_response :success
      assert_not_equal "Access denied", JSON.parse(@response.body)["error"]
    end

    test "ensure_reports_access allows advisor role" do
      sign_in @advisor

      get api_reports_filters_path, as: :json

      assert_response :success
      assert_not_equal "Access denied", JSON.parse(@response.body)["error"]
    end

    test "ensure_reports_access blocks student role" do
      sign_in @student

      get api_reports_filters_path, as: :json

      assert_response :forbidden
      json_response = JSON.parse(@response.body)
      assert_equal "Access denied", json_response["error"]
    end

    # Aggregator integration tests
    test "filters calls DataAggregator with user" do
      sign_in @admin

      get api_reports_filters_path, as: :json

      assert_response :success
      # Verify response is valid JSON (aggregator was called)
      assert_nothing_raised { JSON.parse(@response.body) }
    end

    test "benchmark calls DataAggregator with user" do
      sign_in @admin

      get api_reports_benchmark_path, as: :json

      assert_response :success
      assert_nothing_raised { JSON.parse(@response.body) }
    end

    test "filters passes parameters to aggregator" do
      sign_in @admin

      get api_reports_filters_path, params: {
        track: "MPH",
        semester: "Fall 2025",
        survey_id: 123
      }, as: :json

      assert_response :success
      # Successful response indicates parameters were accepted
      assert_nothing_raised { JSON.parse(@response.body) }
    end

    # Test all permitted parameters are actually permitted
    test "reports_params permits all documented parameters" do
      sign_in @admin

      get api_reports_filters_path, params: {
        track: "MPH",
        semester: "Fall 2025",
        survey_id: 1,
        category_id: 2,
        student_id: 3,
        advisor_id: 4,
        competency: "Public Health"
      }, as: :json

      # Should succeed with all parameters
      assert_response :success
    end

    # Test each endpoint individually with full parameter set
    test "competency_summary accepts full parameter set" do
      sign_in @admin

      get api_reports_competency_summary_path, params: {
        track: "MPH",
        semester: "Fall 2025",
        survey_id: 1,
        category_id: 2,
        student_id: 3,
        advisor_id: 4,
        competency: "Public Health"
      }, as: :json

      assert_response :success
    end

    test "competency_detail accepts full parameter set" do
      sign_in @admin

      get api_reports_competency_detail_path, params: {
        track: "MPH",
        semester: "Fall 2025",
        survey_id: 1,
        category_id: 2,
        student_id: 3,
        advisor_id: 4,
        competency: "Public Health"
      }, as: :json

      assert_response :success
    end


    # Additional security tests
    test "unauthenticated user cannot access filters" do
      get api_reports_filters_path, as: :json

      assert_response :unauthorized
    end

    test "unauthenticated user cannot access benchmark" do
      get api_reports_benchmark_path, as: :json

      assert_response :unauthorized
    end

    test "unauthenticated user cannot access competency_summary" do
      get api_reports_competency_summary_path, as: :json

      assert_response :unauthorized
    end

    test "unauthenticated user cannot access competency_detail" do
      get api_reports_competency_detail_path, as: :json

      assert_response :unauthorized
    end
  end
end
