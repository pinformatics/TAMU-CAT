require "test_helper"

class GuidanceTextHelperTest < ActionView::TestCase
  include GuidanceTextHelper

  test "render_guidance_text returns blank when no sections" do
    assert_equal "", render_guidance_text("")
    assert_equal "", render_guidance_text(nil)
  end

  test "render_guidance_text renders titles, paragraphs, and bullets" do
    input = <<~TEXT
      # Title One

      - Bullet A
      - Bullet B

      # Title Two
      Second paragraph.
    TEXT

    html = render_guidance_text(input, heading_tag: :h3)

    assert_includes html, "c-rich-text"
    assert_includes html, "<h3"
    assert_includes html, "Title One"
    assert_includes html, "<ul"
    assert_includes html, "Bullet A"
    assert_includes html, "Title Two"
  end
end
