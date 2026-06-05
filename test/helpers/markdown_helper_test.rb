require "test_helper"

class MarkdownHelperTest < ActionView::TestCase
  test "blank markdown renders empty safe strings" do
    assert_equal "", render_markdown("   ").to_s
    assert_equal "", render_markdown_inline("\n\n").to_s
  end

  test "render_markdown wraps sanitized html and offsets headings" do
    html = render_markdown(
      "# Heading\n\nVisit [TAMU](https://www.tamu.edu). <script>alert(1)</script>",
      wrapper_class: "c-rich-text",
      min_heading_level: 3
    ).to_s

    assert_includes html, "c-rich-text"
    assert_includes html, "<h3"
    assert_includes html, "https://www.tamu.edu"
    refute_includes html, "<script>"
  end

  test "render_markdown_inline keeps inline formatting and removes paragraphs" do
    html = render_markdown_inline("Use **bold**, `code`, and www.tamu.edu\nnext line").to_s

    assert_includes html, "<strong>bold</strong>"
    assert_includes html, "<code>code</code>"
    assert_includes html, 'href="https://www.tamu.edu"'
    assert_includes html, "<br"
    refute_includes html, "<p>"
  end

  test "basic fallback renders headings lists ordered lists rules and paragraphs" do
    unordered = send(:basic_markdown_to_html, "Title\n-----\n- One\n- Two")
    ordered = send(:basic_markdown_to_html, "# Steps\n1. First\n2. Second")
    rule = send(:basic_markdown_to_html, "---")
    paragraph = send(:basic_markdown_to_html, "Plain\ntext")

    assert_includes unordered, "<h2>Title</h2><ul>"
    assert_includes unordered, "<li>One</li>"
    assert_includes ordered, "<h1>Steps</h1><ol>"
    assert_includes ordered, "<li>Second</li>"
    assert_equal "<hr>", rule
    assert_includes paragraph, "<p>Plain<br>text</p>"
  end

  test "inline fallback normalizes safe links and drops unsafe links" do
    html = send(
      :inline_markdown_fallback,
      "[site](www.tamu.edu) [email](mailto:test@example.com) [bad](javascript:alert(1)) ++under++ <u>also</u>"
    )

    assert_includes html, 'href="https://www.tamu.edu"'
    assert_includes html, 'href="mailto:test@example.com"'
    assert_includes html, "bad"
    refute_includes html, "javascript:alert"
    assert_includes html, "<u>under</u>"
    assert_includes html, "<u>also</u>"
  end

  test "heading offset caps at h6 and leaves lower requested levels unchanged" do
    capped = send(:offset_heading_levels, "<h4>Deep</h4><h6>Last</h6>", 5)
    unchanged = send(:offset_heading_levels, "<h3>Already lower</h3>", 2)

    assert_includes capped, "<h5>Deep</h5>"
    assert_includes capped, "<h6>Last</h6>"
    assert_equal "<h3>Already lower</h3>", unchanged
  end

  test "fallback markdown covers setext paragraphs mixed remainders and single headings" do
    setext_paragraph = send(:basic_markdown_to_html, "Title\n=====\nBody line")
    setext_ordered = send(:basic_markdown_to_html, "Title\n=====\n1. First\n2. Second")
    single_heading = send(:basic_markdown_to_html, "### Small")
    blank = send(:basic_markdown_to_html, "   ")

    assert_includes setext_paragraph, "<h1>Title</h1><p>Body line</p>"
    assert_includes setext_ordered, "<h1>Title</h1><ol>"
    assert_equal "<h3>Small</h3>", single_heading
    assert_equal "", blank
  end

  test "markdown normalization allows safe relative anchors phone and drops blank links" do
    assert_equal "/faq", send(:normalize_href, "/faq")
    assert_equal "#top", send(:normalize_href, "#top")
    assert_equal "tel:1234567890", send(:normalize_href, "tel:1234567890")
    assert_nil send(:normalize_href, "")
    assert_nil send(:normalize_href, "javascript:alert(1)")

    html = send(:inline_markdown_fallback, "[relative](/faq) [anchor](#top) [phone](tel:1234567890)")
    assert_includes html, 'href="/faq"'
    assert_includes html, 'href="#top"'
    assert_includes html, 'href="tel:1234567890"'
  end

  test "markdown renderer falls back when commonmarker raises and heading offset ignores html without headings" do
    if defined?(Commonmarker)
      Commonmarker.stub(:to_html, ->(*) { raise StandardError, "boom" }) do
        assert_includes send(:markdown_to_html, "**fallback**"), "<strong>fallback</strong>"
      end
    else
      assert_includes send(:markdown_to_html, "**fallback**"), "<strong>fallback</strong>"
    end

    assert_equal "<p>No headings</p>", send(:offset_heading_levels, "<p>No headings</p>", 4)
    assert_equal "<h2>Already high</h2>", send(:offset_heading_levels, "<h2>Already high</h2>", 1)
  end
end
