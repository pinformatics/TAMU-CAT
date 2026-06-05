# frozen_string_literal: true

require "test_helper"

class EvidenceControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @student = users(:student)
    @valid_sites_url = "https://sites.google.com/tamu.edu/sample-site/home"
  end

  test "check_access requires authentication" do
    get evidence_check_access_path(url: @valid_sites_url), as: :json

    assert_response :unauthorized
  end

  test "check_access accepts valid google sites url format" do
    sign_in @student
    stub_request(:head, @valid_sites_url).to_return(status: 200)
    stub_request(:get, @valid_sites_url).to_return(status: 200, body: "Anyone with the link can view")

    get evidence_check_access_path(url: @valid_sites_url), as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal true, json_response["ok"]
    assert_equal true, json_response["accessible"]
    assert_equal 200, json_response["status"]
    assert_equal "ok", json_response["reason"]
  end

  test "check_access rejects google sites page that still requires access" do
    sign_in @student
    stub_request(:head, @valid_sites_url).to_return(status: 200)
    stub_request(:get, @valid_sites_url).to_return(status: 200, body: "You need access. Request access from the owner.")

    get evidence_check_access_path(url: @valid_sites_url), as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal false, json_response["ok"]
    assert_equal false, json_response["accessible"]
    assert_equal "forbidden", json_response["reason"]
  end

  test "check_access rejects google drive url format" do
    sign_in @student

    get evidence_check_access_path(url: "https://drive.google.com/file/d/123/view"), as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal false, json_response["ok"]
    assert_equal false, json_response["accessible"]
    assert_nil json_response["status"]
    assert_equal "invalid_url", json_response["reason"]
  end

  test "check_access rejects google docs url format" do
    sign_in @student

    get evidence_check_access_path(url: "https://docs.google.com/document/d/abc/edit"), as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal "invalid_url", json_response["reason"]
  end

  test "check_access rejects non-google url" do
    sign_in @student

    get evidence_check_access_path(url: "https://example.com/portfolio"), as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal "invalid_url", json_response["reason"]
  end

  test "check_access returns network_error when fetch fails for valid sites url" do
    sign_in @student
    stub_request(:head, @valid_sites_url).to_raise(StandardError.new("boom"))

    get evidence_check_access_path(url: @valid_sites_url), as: :json

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal false, json_response["ok"]
    assert_equal false, json_response["accessible"]
    assert_nil json_response["status"]
    assert_equal "network_error", json_response["reason"]
  end

  test "fetch_with_redirects follows redirects and falls back to GET" do
    controller = EvidenceController.new
    start_url = "https://sites.google.com/tamu.edu/start"
    redirected = "https://sites.google.com/tamu.edu/final"

    stub_request(:head, start_url).to_return(status: 302, headers: { "Location" => redirected })
    stub_request(:head, redirected).to_return(status: 405)
    stub_request(:get, redirected).to_return(status: 200)

    response = controller.send(:fetch_with_redirects, start_url)
    assert_equal "200", response.code
  end

  test "fetch_with_redirects raises after too many redirects" do
    controller = EvidenceController.new

    assert_raises(RuntimeError) do
      controller.send(:fetch_with_redirects, "https://sites.google.com/tamu.edu/start", limit: 0)
    end
  end

  test "reason_from_code maps known statuses and unavailable fallback" do
    controller = EvidenceController.new

    assert_equal "ok", controller.send(:reason_from_code, 200)
    assert_equal "unauthorized", controller.send(:reason_from_code, 401)
    assert_equal "forbidden", controller.send(:reason_from_code, 403)
    assert_equal "not_found", controller.send(:reason_from_code, 404)
    assert_equal "rate_limited", controller.send(:reason_from_code, 429)
    assert_equal "unavailable", controller.send(:reason_from_code, 500)
  end
end
