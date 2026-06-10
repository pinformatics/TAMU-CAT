require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "flash_classes returns expected classes for known keys" do
    assert_includes flash_classes(:notice), "flash__notice"
    assert_includes flash_classes(:success), "flash__success"
    assert_includes flash_classes(:alert), "flash__alert"
    assert_includes flash_classes(:warning), "flash__warning"
    assert_equal "flash", flash_classes(:custom_key)
  end

  test "flash_title returns fallback for unknown keys" do
    assert_equal "Custom Key", flash_title(:custom_key)
  end

  test "ferpa_export_confirmation gives consistent export warning copy" do
    message = ferpa_export_confirmation("student-level competency data")

    assert_includes message, "FERPA reminder"
    assert_includes message, "student-level competency data"
    assert_includes message, "legitimate educational interest"
    assert_includes message, "store or share the file securely"
  end

  test "ferpa_export_notice gives visible warning copy" do
    message = ferpa_export_notice("Student-level competency exports")

    assert_includes message, "FERPA reminder"
    assert_includes message, "Student-level competency exports"
    assert_includes message, "legitimate educational or program review use"
    assert_includes message, "store and share it securely"
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

  test "status_badge_classes maps status variants" do
    assert_includes status_badge_classes("completed"), "c-status-badge--success"
    assert_includes status_badge_classes("assigned"), "c-status-badge--warning"
    assert_includes status_badge_classes("in progress"), "c-status-badge--warning"
    assert_includes status_badge_classes("unassigned"), "c-status-badge--danger"
    assert_includes status_badge_classes("unknown"), "c-status-badge--neutral"
    assert_includes survey_status_badge_classes("unassigned"), "c-status-badge--danger"
    assert_includes feedback_status_badge_classes("submitted"), "c-status-badge--success"
  end

  test "status_badge renders reusable badge markup" do
    html = status_badge("Unassigned", data: { testid: "status" })

    assert_includes html, "c-status-badge"
    assert_includes html, "c-status-badge--danger"
    assert_includes html, "data-testid=\"status\""
    assert_includes html, "Unassigned"
  end

  test "survey lifecycle label handles archived blank open and closed rows" do
    survey = surveys(:fall_2025)

    assert_equal "Archived", survey_lifecycle_label(nil, [])
    assert_equal "Active", survey_lifecycle_label(survey, [])
    assert_equal "Active", survey_lifecycle_label(survey, [ { available_until: nil } ])
    assert_equal "Active", survey_lifecycle_label(survey, [ { available_until: 1.day.from_now } ])
    assert_equal "Closed", survey_lifecycle_label(survey, [ { available_until: 1.day.ago } ])
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
    assert_equal "a, b", humanize_audit_value([ "a", "", "b" ])
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

  test "summarize survey audit metadata skips unchanged and missing structures" do
    summary = summarize_survey_audit_metadata(
      attributes: { title: { before: "Same", after: "Same" } },
      associations: { tracks: { before: [ "A" ], after: [ "A" ] } }
    )

    assert_equal "No recorded changes", summary
    assert_equal "No recorded changes", summarize_survey_audit_metadata(note: "", attributes: [], associations: [])
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

  test "consolidated_stylesheet_tags falls back to resolved asset links" do
    fake_asset = Struct.new(:digested_path).new("application-abc123.css")
    load_path = Object.new
    load_path.define_singleton_method(:find) do |name|
      name == "application.css" ? fake_asset : nil
    end
    fake_assets = Struct.new(:load_path).new(load_path)

    self.stub(:stylesheet_link_tag, ->(*) { raise StandardError, "boom" }) do
      Rails.application.stub(:assets, fake_assets) do
        html = consolidated_stylesheet_tags.to_s

        assert_includes html, "application-abc123.css"
        assert_includes html, "accessibility.css"
        assert_includes html, "rel=\"stylesheet\""
      end
    end
  end

  test "consolidated_stylesheet_tags returns nil when all fallback links fail" do
    self.stub(:stylesheet_link_tag, ->(*) { raise StandardError, "boom" }) do
      self.stub(:stylesheet_fallback_tag, nil) do
        assert_nil consolidated_stylesheet_tags
      end
    end
  end

  test "review_meetings_note formats blank single date and range values" do
    offering = Struct.new(:review_meetings_start, :review_meetings_end)
    start_date = Date.new(2026, 6, 2)
    end_date = Date.new(2026, 6, 9)

    assert_nil review_meetings_note(nil)
    assert_nil review_meetings_note(offering.new(nil, nil))
    assert_equal "June 2, 2026", review_meetings_note(offering.new(start_date, nil))
    assert_equal "June 9, 2026", review_meetings_note(offering.new(nil, end_date))
    assert_equal "June 2, 2026", review_meetings_note(offering.new(start_date, start_date))
    assert_equal "June 2, 2026 – June 9, 2026", review_meetings_note(offering.new(start_date, end_date))
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

  test "render_question_prompt escapes plain and nil prompts" do
    escape = ->(value) { ERB::Util.html_escape(value) }
    define_singleton_method(:h, &escape)

    assert_equal "", render_question_prompt(nil)

    question = Question.new(question_text: "<script>alert('x')</script>")
    assert_includes render_question_prompt(question), "&lt;script&gt;"
  end

  test "sortable header preserves filters and toggles active direction" do
    request.query_parameters.merge!("q" => "health", "track" => "Residential", "ignored" => "nope")
    @sort_column = "title"
    @sort_direction = "asc"

    active_html = sortable_header("Title", "title")
    assert_includes active_html, "direction=desc"
    assert_includes active_html, "q=health"
    assert_includes active_html, "track=Residential"
    assert_includes active_html, "(asc)"
    assert_includes active_html, "text-indigo-600"

    inactive_html = sortable_header("Semester", "semester")
    assert_includes inactive_html, "direction=asc"
    refute_includes inactive_html, "(asc)"
  end
end
