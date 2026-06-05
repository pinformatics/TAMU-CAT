require "test_helper"

class Api::MarkdownPreviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:admin)
  end

  test "renders markdown preview with sanitized options" do
    post api_markdown_preview_path, params: {
      text: "Preview Heading\n---\n\n- One\n- Two",
      wrapper_class: "c-markdown-preview custom_class",
      min_heading_level: "3"
    }

    assert_response :success
    body = JSON.parse(response.body)

    assert_includes body["html"], "c-markdown-preview custom_class"
    assert_includes body["html"], "<h3"
    assert_includes body["html"], "<li>One</li>"
  end

  test "drops unsafe wrapper classes and clamps invalid heading levels" do
    post api_markdown_preview_path, params: {
      text: "# Unsafe Heading",
      wrapper_class: "safe<script>",
      min_heading_level: "9"
    }

    assert_response :success
    body = JSON.parse(response.body)

    refute_includes body["html"], "safe<script>"
    assert_includes body["html"], "<h1"
  end

  test "requires authentication" do
    sign_out users(:admin)

    post api_markdown_preview_path, params: { text: "Nope" }

    assert_redirected_to new_user_session_path
  end
end
