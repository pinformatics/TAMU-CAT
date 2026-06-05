# frozen_string_literal: true

require "test_helper"

class TranslateWidgetTest < ActionDispatch::IntegrationTest
  test "auth layout renders the persistent translate widget without inline bootstrap" do
    get new_user_session_path

    assert_response :success
    assert_select "#gt-compact[data-turbo-permanent]"
    assert_select "#gt-toggle[aria-controls='gt-panel'][aria-expanded='false']"
    assert_select "#gt-panel[aria-hidden='true']"
    assert_select "[data-gt-language-select] option[value='es']", text: "Spanish"
    assert_select "[data-gt-language-select] option[value='zh-CN']", text: "Simplified Chinese"
    assert_select "#google_translate_element.translate-widget-mount[aria-hidden='true']"
    assert_select "[data-gt-visible-status]", text: /Select a language/
    assert_no_match "Loading translation options", response.body
    refute_includes response.body, "Google Translate widget loader"
  end

  test "signed in layout renders the persistent translate widget without inline bootstrap" do
    sign_in users(:student)

    get student_dashboard_path

    assert_response :success
    assert_select "#gt-compact[data-turbo-permanent]"
    assert_select "#google_translate_element"
    assert_select "[data-gt-language-select] option[value='vi']", text: "Vietnamese"
    assert_select "[data-gt-language-select] option[value='ko']", text: "Korean"
    assert_select "#google_translate_element.translate-widget-mount[aria-hidden='true']"
    assert_select "[data-gt-visible-status]", text: /Select a language/
    assert_no_match "Loading translation options", response.body
    refute_includes response.body, "Google Translate widget loader"
  end

  test "translation javascript syncs visible list from google and applies selected language" do
    source = Rails.root.join("app/javascript/application.js").read

    assert_includes source, "function syncVisibleGoogleLanguageOptions()"
    assert_includes source, "const googleOptions = Array.from(googleSelect.options)"
    assert_includes source, "appSelect.appendChild(englishOption)"
    assert_includes source, "syncVisibleGoogleLanguageOptions()"
    assert_includes source, "function triggerGoogleTranslateCombo(language)"
    assert_includes source, "select.dispatchEvent(new Event(\"change\", { bubbles: true }))"
    assert_includes source, "function applyGoogleTranslateLanguage(language"
    assert_includes source, "function syncGoogleTranslateVisibleState()"
    assert_includes source, "function pageTranslatedByGoogle()"
    assert_includes source, "appSelect.value = \"\""
    assert_includes source, "attributes: true"
    assert_includes source, "attributeFilter: [ \"class\" ]"
    assert_includes source, "function restoreGoogleTranslateAfterLoad()"
    assert_includes source, "window.addEventListener(\"load\", () => window.setTimeout(restoreTranslation, 0), { once: true })"
    assert_includes source, "{ pageLanguage: \"en\", autoDisplay: false }"
  end

  test "translation javascript does not rely on paid ai translation or frozen turbo mutation" do
    source = Rails.root.join("app/javascript/application.js").read

    assert_no_match(/LlmTranslator|OPENAI_TRANSLATION|LLM_TRANSLATION/, source)
    assert_no_match(/window\.Turbo\.appModalConfirmInstalled/, source)
    assert_includes source, "let appModalConfirmInstalled = false"
  end
end
