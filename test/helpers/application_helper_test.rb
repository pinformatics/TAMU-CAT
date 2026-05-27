require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "flash_classes returns expected classes for known keys" do
    assert_includes flash_classes(:notice), "flash__notice"
    assert_includes flash_classes(:success), "flash__success"
    assert_includes flash_classes(:alert), "flash__alert"
    assert_includes flash_classes(:warning), "flash__warning"
  end

  test "flash_title returns fallback for unknown keys" do
    assert_equal "Custom Key", flash_title(:custom_key)
  end

  test "app names expose short browser name and full display name" do
    assert_equal "TAMU CAT", app_short_name
    assert_equal "TAMU Competency Assessment Tracking", app_full_name
    assert_equal "TAMU_CAT_icon.png", app_icon_asset
    assert_equal "tamu-logo.png", tamu_icon_asset
  end

  test "browser_title keeps tab text compact" do
    assert_equal "TAMU CAT", browser_title(nil)
    assert_equal "Reports | TAMU CAT", browser_title("Reports")
    assert_equal "Login - TAMU CAT", browser_title("Login - TAMU Competency Assessment Tracking")
    assert_equal "FAQ - TAMU CAT", browser_title("FAQ - TAMU Competency Assessment Tool")
  end

  test "tailwind_button_classes returns different variants" do
    primary = tailwind_button_classes(:primary)
    danger = tailwind_button_classes(:danger)
    subtle = tailwind_button_classes(:subtle)

    assert_includes primary, "btn-primary"
    assert_includes danger, "btn-danger"
    assert_includes subtle, "btn-subtle"

    refute_equal primary, danger
    refute_equal primary, subtle
  end

  test "tailwind_button_classes falls back for unknown variant and appends extra classes" do
    classes = tailwind_button_classes(:unknown_variant, extra_classes: "mt-2")
    assert_includes classes, "btn"
    assert_includes classes, "btn-secondary"
    assert_includes classes, "mt-2"
  end

  test "survey_availability_note handles blank and formats closing dates" do
    assert_equal "No deadline", survey_availability_note(nil)

    today = Time.zone.today
    assert_equal "Closes #{today.strftime('%B')} #{today.day}, #{today.year}", survey_availability_note(today)

    future = today + 5
    assert_equal "Closes #{future.strftime('%B')} #{future.day}, #{future.year}", survey_availability_note(future)
  end

  test "survey_status_badge_classes maps status variants" do
    assert_includes survey_status_badge_classes("completed"), "emerald"
    assert_includes survey_status_badge_classes("assigned"), "amber"
    assert_includes survey_status_badge_classes("unassigned"), "slate"
    assert_includes survey_status_badge_classes("unknown"), "slate"
  end

  test "avatar_aria_label falls back when user missing or name blank" do
    assert_equal "User avatar", avatar_aria_label(nil)

    user = Struct.new(:full_name).new(" ")
    assert_equal "User avatar", avatar_aria_label(user)

    user = Struct.new(:full_name).new("Ada Lovelace")
    assert_equal "Profile picture for Ada Lovelace", avatar_aria_label(user)
  end

  test "humanize_audit_value and list behaviors" do
    assert_equal "none", humanize_audit_value(nil)
    # Empty string should be normalized to "none"
    assert_equal "none", humanize_audit_value("")
    assert_equal "a, b", humanize_audit_list([ "a", "b" ])
    assert_equal "none", humanize_audit_list([])
  end

  test "summarize_survey_audit_metadata builds a short summary" do
    meta = {
      note: "Test note",
      attributes: { title: { before: "Old", after: "New" } },
      associations: { tracks: { before: [ "A" ], after: [ "B" ] } }
    }

    summary = summarize_survey_audit_metadata(meta)
    assert_includes summary, "Test note"
    assert_includes summary, "Title: Old -> New"
    assert_includes summary, "Tracks: A -> B"
  end

  test "tailwind_stylesheet_tag returns fallback link when asset pipeline raises" do
    fake_asset = Struct.new(:digested_path).new("tailwind-abc123.css")
    load_path = Object.new
    load_path.define_singleton_method(:find) do |name|
      name == "tailwind.css" ? fake_asset : nil
    end
    fake_assets = Struct.new(:load_path).new(load_path)

    self.stub(:stylesheet_link_tag, ->(*) { raise StandardError, "boom" }) do
      Rails.application.stub(:assets, fake_assets) do
        html = tailwind_stylesheet_tag
        assert html
        assert_includes html, "tailwind-abc123.css"
        assert_includes html, "rel=\"stylesheet\""
      end
    end
  end

  test "tailwind_stylesheet_tag returns nil when fallback asset missing" do
    self.stub(:stylesheet_link_tag, ->(*) { raise StandardError, "boom" }) do
      Rails.application.stub(:assets, nil) do
        assert_nil tailwind_stylesheet_tag
      end
    end
  end

  test "render_question_prompt supports underscore markdown emphasis" do
    question = Question.new(
      prompt_format: "rich_text",
      question_text: "How many **hours per week** do you work on _average_?"
    )

    html = render_question_prompt(question).to_s
    assert_includes html, "<strong>hours per week</strong>"
    assert_includes html, "<em>average</em>"
  end

  test "render_question_prompt supports ++underline++ markdown" do
    question = Question.new(
      prompt_format: "rich_text",
      question_text: "How many **hours per week** do you work on ++average++?"
    )

    html = render_question_prompt(question).to_s
    assert_includes html, "<strong>hours per week</strong>"
    assert_includes html, "<u>average</u>"
  end
end
