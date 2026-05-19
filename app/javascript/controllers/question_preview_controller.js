import { Controller } from "@hotwired/stimulus"

// Live preview for admin survey question editing.
// Keeps the "Preview" portion of a question block in sync while typing.
export default class extends Controller {
  static values = {
    initialOptionPairs: Array
  }

  static targets = [
    "promptInput",
    "promptFormatSelect",
    "descriptionInput",
    "requiredInput",
    "evidenceInput",
    "feedbackInput",
    "targetLevelInput",
    "typeSelect",
    "answerOptionsInput",
    "answerOptionsEditor",
    "optionsList",
    "optionsEditorSection",
    "answerOptionsBlock",
    "answerOptionsDrawer",
    "answerOptionsToggleButton",
    "answerOptionsToggleLabel",
    "answerOptionsToggleIcon",
    "answerOptionsCount",
    "optionsDrawerBackdrop",
    "optionsDrawerPanel",
    "questionTypeDropdown",
    "questionTypeButtonLabel",
    "integerRulesBlock",
    "integerMinInput",
    "integerMaxInput",
    "targetLevelBadge",
    "promptText",
    "summaryPromptText",
    "typeBadge",
    "descriptionText",
    "requiredStar",
    "metadataRequired",
    "metadataEvidence",
    "metadataFeedback",
    "metadataTarget",
    "response"
  ]

  connect() {
    this.update = this.update.bind(this)
    this.handleKeyDown = this.handleKeyDown.bind(this)
    this.handleActivationEvent = this.handleActivationEvent.bind(this)

    // Track how the backing textarea stores options so edits preserve semantics.
    this.optionsFormat = this.detectOptionsFormat()
    this.answerOptionsDrawerOpen = false
    this.instanceId = this.element.id || `question-preview-${Math.random().toString(36).slice(2, 9)}`

    // If the textarea is empty/unparseable but Rails was able to compute option pairs,
    // bootstrap from them so the preview doesn't lose options.
    this.bootstrapOptionsFromInitialPairs()

    this.element.addEventListener("input", this.update)
    this.element.addEventListener("change", this.update)
    this.element.addEventListener("keydown", this.handleKeyDown)
    window.addEventListener("question-preview:activate", this.handleActivationEvent)

    this.hydrateEditorFromHidden()
    this.update()
    this.updateOptionsCount()
  }

  bootstrapOptionsFromInitialPairs() {
    if (this._bootstrappedOptions) return
    if (!this.hasAnswerOptionsInputTarget) return

    const currentEntries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    if (currentEntries.length) return

    const pairs = this.readInitialOptionPairs() || []
    if (!pairs.length) return

    const entries = pairs
      .filter((p) => Array.isArray(p) && p.length >= 2)
      .map((p) => ({ label: String(p[0] ?? "").trim(), value: String(p[1] ?? "").trim() }))
      .filter((e) => e.label.length)

    if (!entries.length) return

    // Preserve the seeded meaning: for pairs, keep JSON pairs.
    this.optionsFormat = "json_pairs"
    this._bootstrappedOptions = true
    this.setOptionEntries(entries)
  }

  readInitialOptionPairs() {
    // Prefer Stimulus values API.
    if (this.hasInitialOptionPairsValue) return this.initialOptionPairsValue

    // Fallback for older Stimulus versions: read raw JSON from dataset.
    const raw = this.element?.dataset?.questionPreviewInitialOptionPairsValue
    if (!raw || !raw.length) return null

    try {
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed : null
    } catch {
      return null
    }
  }

  entriesFromInitialPairsForRender() {
    const pairs = this.readInitialOptionPairs() || []
    if (!pairs.length) return []

    return pairs
      .filter((p) => Array.isArray(p) && p.length >= 2)
      .map((p) => ({
        label: this.normalizeOptionString(p[0]),
        value: this.normalizeOptionString(p[1])
      }))
      .filter((e) => e.label.length)
  }

  disconnect() {
    this.element.removeEventListener("input", this.update)
    this.element.removeEventListener("change", this.update)
    this.element.removeEventListener("keydown", this.handleKeyDown)
    window.removeEventListener("question-preview:activate", this.handleActivationEvent)
  }

  activate(event) {
    // Ignore clicks inside other interactive controls that should not steal focus.
    if (event?.target?.closest?.("[data-action*='question-preview#closeOptionsDrawer']")) return

    this.answerOptionsDrawerOpen = true
    this.hydrateEditorFromHidden()
    this.renderOptionsList()
    this.syncAnswerOptionsDrawerUi()

    window.dispatchEvent(new CustomEvent("question-preview:activate", { detail: { id: this.instanceId } }))
  }

  handleActivationEvent(event) {
    const activeId = event?.detail?.id
    if (!activeId || activeId === this.instanceId) return
    this.answerOptionsDrawerOpen = false
    this.syncAnswerOptionsDrawerUi()
  }

  update(event) {
    // When editing an option inline, keystrokes happen inside the rendered
    // preview region. If we re-render the preview on every keystroke, the
    // input can be replaced mid-edit and indices can drift, making text land
    // on the wrong choice. Only re-render once the backing textarea changes.
    const target = event?.target
    const editingInsideResponsePreview = !!(target && this.hasResponseTarget && this.responseTarget.contains(target))

    this.updatePrompt()
    this.updateDescription()
    this.updateRequired()
    this.updateQuestionTypeUi()
    this.updateTargetLevelBadge()
    this.updateMetadataTray()
    this.updateIntegerRulesVisibility()
    this.updateAnswerOptionsVisibility()
    this.updateOptionsCount()

    if (!editingInsideResponsePreview) {
      this.updateResponsePreview()
    }
  }

  updatePrompt() {
    const value = (this.promptInputTarget?.value || "").trim()
    const prompt = value.length ? value : "Untitled question"

    if (this.hasSummaryPromptTextTarget) {
      this.summaryPromptTextTarget.textContent = prompt
    }

    if (!this.hasPromptTextTarget) return

    const rich = this.hasPromptFormatSelectTarget && this.promptFormatSelectTarget?.value === "rich_text"

    if (rich) {
      this.promptTextTarget.innerHTML = this.renderSafePromptHtml(prompt)
      return
    }

    this.promptTextTarget.textContent = prompt
  }

  updateDescription() {
    if (!this.hasDescriptionTextTarget) return
    const raw = (this.descriptionInputTarget?.value || "").trim()
    if (!raw.length) {
      this.descriptionTextTarget.innerHTML = '<span class="text-slate-400">Add description</span>'
      return
    }

    this.descriptionTextTarget.innerHTML = this.renderPreviewMarkdown(raw)
  }

  updateRequired() {
    if (!this.hasRequiredStarTarget) return
    const required = !!this.requiredInputTarget?.checked
    this.requiredStarTarget.classList.toggle("hidden", !required)
  }

  updateAnswerOptionsVisibility() {
    if (!this.hasAnswerOptionsBlockTarget) return

    const type = (this.typeSelectTarget?.value || "").trim()

    const supportsOptions = type === "multiple_choice" || type === "dropdown"

    // Keep the drawer trigger available for all types so advanced settings
    // (including question type) stay accessible.
    this.answerOptionsBlockTarget.classList.remove("hidden")

    if (supportsOptions) {
      this.syncAnswerOptionsDrawerUi()
    }

    if (this.hasOptionsEditorSectionTarget) {
      this.optionsEditorSectionTarget.classList.toggle("hidden", !supportsOptions)
    }

    if (!supportsOptions && this.answerOptionsDrawerOpen && this.hasOptionsEditorSectionTarget) {
      this.renderOptionsList()
    }
  }

  updateQuestionTypeUi() {
    const type = (this.typeSelectTarget?.value || "").trim()
    const supportsOptions = type === "multiple_choice" || type === "dropdown"

    if (this.hasQuestionTypeButtonLabelTarget) {
      this.questionTypeButtonLabelTarget.textContent = this.humanizeType(type)
    }

    if (this.hasAnswerOptionsToggleLabelTarget) {
      this.answerOptionsToggleLabelTarget.textContent = supportsOptions ? "Manage Options" : "Edit Settings"
    }
  }

  updateTargetLevelBadge() {
    if (!this.hasTargetLevelBadgeTarget) return
    const value = this.hasTargetLevelInputTarget ? String(this.targetLevelInputTarget?.value || "").trim() : ""
    this.targetLevelBadgeTarget.classList.toggle("hidden", !value.length)
    if (value.length) {
      this.targetLevelBadgeTarget.textContent = `Target ${value}/5`
    }
  }

  setQuestionType(event) {
    event?.preventDefault()

    const type = String(event?.currentTarget?.dataset?.questionType || "").trim()
    if (!type.length || !this.hasTypeSelectTarget) return

    this.typeSelectTarget.value = type
    this.typeSelectTarget.dispatchEvent(new Event("change", { bubbles: true }))

    if (this.hasQuestionTypeDropdownTarget) {
      this.questionTypeDropdownTarget.open = false
    }

    this.update()
  }

  updateIntegerRulesVisibility() {
    if (!this.hasIntegerRulesBlockTarget) return
    const type = (this.typeSelectTarget?.value || "").trim()
    this.integerRulesBlockTarget.classList.toggle("hidden", type !== "integer")
  }

  openOptionsDrawer(event) {
    event?.preventDefault()
    this.activate(event)
  }

  closeOptionsDrawer(event) {
    event?.preventDefault()
    this.answerOptionsDrawerOpen = false
    this.syncAnswerOptionsDrawerUi()
  }

  syncAnswerOptionsDrawerUi() {
    if (!this.hasOptionsDrawerPanelTarget) return

    this.optionsDrawerPanelTarget.classList.toggle("hidden", !this.answerOptionsDrawerOpen)
    if (this.hasOptionsDrawerBackdropTarget) {
      this.optionsDrawerBackdropTarget.classList.toggle("hidden", true)
    }
    this.optionsDrawerPanelTarget.setAttribute("aria-hidden", this.answerOptionsDrawerOpen ? "false" : "true")

    if (this.hasAnswerOptionsToggleButtonTarget) {
      this.answerOptionsToggleButtonTarget.setAttribute("aria-expanded", this.answerOptionsDrawerOpen ? "true" : "false")
    }
  }

  updateOptionsCount() {
    if (!this.hasAnswerOptionsCountTarget) return
    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    this.answerOptionsCountTarget.textContent = String(entries.length)
  }

  syncFromEditor() {
    if (!this.hasAnswerOptionsEditorTarget) return

    const lines = this.answerOptionsEditorTarget.value
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.length)

    const entries = lines.map((line) => ({ label: line, value: line }))
    this.setOptionEntries(entries)
    this.renderOptionsList()
    this.updateOptionsCount()
    this.updateResponsePreview()
  }

  hydrateEditorFromHidden() {
    if (!this.hasAnswerOptionsEditorTarget) return
    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    this.answerOptionsEditorTarget.value = entries.map((e) => e.label).join("\n")
  }

  renderOptionsList() {
    if (!this.hasOptionsListTarget) return

    const type = (this.typeSelectTarget?.value || "").trim()
    const supportsOptions = type === "multiple_choice" || type === "dropdown"
    if (!supportsOptions) {
      this.optionsListTarget.innerHTML =
        '<p class="rounded-md border border-dashed border-slate-300 bg-slate-50 px-3 py-2 text-xs text-slate-500">This question type does not use answer options.</p>'
      return
    }

    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    if (!entries.length) {
      this.optionsListTarget.innerHTML =
        '<p class="rounded-md border border-dashed border-slate-300 bg-slate-50 px-3 py-2 text-xs text-slate-500">No options yet. Add one to begin.</p>'
      return
    }

    const rows = entries
      .map((entry, idx) => {
        const label = this.escapeHtml(entry.label || "")
        const disabledUp = idx === 0 ? "disabled" : ""
        const disabledDown = idx === entries.length - 1 ? "disabled" : ""

        return `
          <div class="c-option-row" data-option-index="${idx}" draggable="true" data-action="dragstart->question-preview#onOptionDragStart dragover->question-preview#onOptionDragOver drop->question-preview#onOptionDrop dragend->question-preview#onOptionDragEnd">
            <span class="c-option-row__drag" aria-hidden="true" title="Drag to reorder">⋮⋮</span>
            <input
              type="text"
              value="${label}"
              class="c-option-row__input"
              data-option-index="${idx}"
              data-action="input->question-preview#updateOptionRow"
              aria-label="Option ${idx + 1}">
            <div class="c-option-row__actions">
              <button type="button" class="btn btn-secondary btn-sm" data-option-index="${idx}" data-action="question-preview#moveOptionUp" ${disabledUp}>Up</button>
              <button type="button" class="btn btn-secondary btn-sm" data-option-index="${idx}" data-action="question-preview#moveOptionDown" ${disabledDown}>Down</button>
              <button type="button" class="btn btn-danger btn-sm" data-option-index="${idx}" data-action="question-preview#removeOptionRow">Remove</button>
            </div>
          </div>
        `
      })
      .join("")

    this.optionsListTarget.innerHTML = rows
  }

  addOptionRow(event) {
    event?.preventDefault()

    const type = (this.typeSelectTarget?.value || "").trim()
    const supportsOptions = type === "multiple_choice" || type === "dropdown"
    if (!supportsOptions) return

    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    const nextLabel = `Option ${entries.length + 1}`
    const nextValue = this.suggestNextOptionValue(entries, nextLabel)
    entries.push({ label: nextLabel, value: nextValue })

    this.setOptionEntries(entries)
    this.hydrateEditorFromHidden()
    this.renderOptionsList()
    this.updateOptionsCount()
    this.updateResponsePreview()

    requestAnimationFrame(() => {
      const input = this.optionsListTarget.querySelector(`[data-option-index="${entries.length - 1}"] .c-option-row__input`)
      input?.focus()
      input?.select()
    })
  }

  updateOptionRow(event) {
    const idx = Number(event?.currentTarget?.dataset?.optionIndex)
    if (!Number.isFinite(idx)) return

    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    if (idx < 0 || idx >= entries.length) return

    const nextLabel = this.normalizeOptionString(event?.currentTarget?.value)
    entries[idx] = {
      ...entries[idx],
      label: nextLabel,
      value: nextLabel.length ? entries[idx]?.value || nextLabel : entries[idx]?.value || ""
    }

    const normalized = entries.filter((entry) => this.normalizeOptionString(entry?.label).length)
    this.setOptionEntries(normalized)
    this.hydrateEditorFromHidden()
    this.updateOptionsCount()
    this.updateResponsePreview()
  }

  removeOptionRow(event) {
    event?.preventDefault()

    const idx = Number(event?.currentTarget?.dataset?.optionIndex)
    if (!Number.isFinite(idx)) return

    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    if (idx < 0 || idx >= entries.length) return

    entries.splice(idx, 1)
    this.setOptionEntries(entries)
    this.hydrateEditorFromHidden()
    this.renderOptionsList()
    this.updateOptionsCount()
    this.updateResponsePreview()
  }

  moveOptionUp(event) {
    event?.preventDefault()
    this.reorderOption(event, -1)
  }

  moveOptionDown(event) {
    event?.preventDefault()
    this.reorderOption(event, 1)
  }

  reorderOption(event, direction) {
    const idx = Number(event?.currentTarget?.dataset?.optionIndex)
    if (!Number.isFinite(idx)) return

    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    const nextIdx = idx + direction
    if (idx < 0 || nextIdx < 0 || idx >= entries.length || nextIdx >= entries.length) return

    ;[entries[idx], entries[nextIdx]] = [entries[nextIdx], entries[idx]]

    this.setOptionEntries(entries)
    this.hydrateEditorFromHidden()
    this.renderOptionsList()
    this.updateOptionsCount()
    this.updateResponsePreview()
  }

  onOptionDragStart(event) {
    const idx = Number(event?.currentTarget?.dataset?.optionIndex)
    if (!Number.isFinite(idx)) return

    this.draggedOptionIndex = idx
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = "move"
      event.dataTransfer.setData("text/plain", String(idx))
    }

    event.currentTarget.classList.add("is-dragging")
  }

  onOptionDragOver(event) {
    event.preventDefault()
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = "move"
    }
  }

  onOptionDrop(event) {
    event.preventDefault()

    const toIdx = Number(event?.currentTarget?.dataset?.optionIndex)
    if (!Number.isFinite(toIdx)) return

    const fromFromTransfer = Number(event?.dataTransfer?.getData("text/plain"))
    const fromIdx = Number.isFinite(fromFromTransfer) ? fromFromTransfer : Number(this.draggedOptionIndex)
    if (!Number.isFinite(fromIdx) || fromIdx === toIdx) return

    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    if (fromIdx < 0 || toIdx < 0 || fromIdx >= entries.length || toIdx >= entries.length) return

    const [moved] = entries.splice(fromIdx, 1)
    entries.splice(toIdx, 0, moved)

    this.setOptionEntries(entries)
    this.hydrateEditorFromHidden()
    this.renderOptionsList()
    this.updateOptionsCount()
    this.updateResponsePreview()
  }

  onOptionDragEnd(event) {
    event?.currentTarget?.classList?.remove("is-dragging")
    this.draggedOptionIndex = null
  }

  updateMetadataTray() {
    if (this.hasMetadataRequiredTarget) {
      const required = !!this.requiredInputTarget?.checked
      this.metadataRequiredTarget.classList.toggle("hidden", !required)
    }

    if (this.hasMetadataEvidenceTarget) {
      const evidence = !!this.evidenceInputTarget?.checked
      this.metadataEvidenceTarget.classList.toggle("hidden", !evidence)
    }

    if (this.hasMetadataFeedbackTarget) {
      const feedback = this.hasFeedbackInputTarget ? !!this.feedbackInputTarget?.checked : false
      this.metadataFeedbackTarget.classList.toggle("hidden", !feedback)
    }

    if (this.hasMetadataTargetTarget) {
      const value = this.hasTargetLevelInputTarget ? (this.targetLevelInputTarget?.value || "").trim() : ""
      this.metadataTargetTarget.classList.toggle("hidden", !value.length)
      if (value.length) {
        this.metadataTargetTarget.textContent = `Target ${value}/5`
      }
    }
  }

  updateResponsePreview() {
    if (!this.hasResponseTarget) return

    const type = (this.typeSelectTarget?.value || "").trim()
    if (this.hasTypeBadgeTarget) {
      this.typeBadgeTarget.textContent = this.humanizeType(type)
    }
    let entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    if (entries.length === 0) {
      this.bootstrapOptionsFromInitialPairs()
      entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    }

    if (entries.length === 0 && (type === "multiple_choice" || type === "dropdown")) {
      entries = this.entriesFromInitialPairsForRender()
    }
    const options = entries.map((e) => e.label)

    // Render an interactive preview similar to Google Forms.
    if (type === "short_answer") {
      this.responseTarget.innerHTML =
        '<input type="text" class="u-w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm" disabled>'
      return
    }

    if (type === "integer") {
      const min = this.hasIntegerMinInputTarget ? this.normalizeOptionString(this.integerMinInputTarget?.value) : ""
      const max = this.hasIntegerMaxInputTarget ? this.normalizeOptionString(this.integerMaxInputTarget?.value) : ""
      const minAttr = min.length ? ` min="${this.escapeHtml(min)}"` : ""
      const maxAttr = max.length ? ` max="${this.escapeHtml(max)}"` : ""
      const ruleText = min.length || max.length
        ? `<p class="text-xs text-slate-500">Allowed range: ${min.length ? `>= ${this.escapeHtml(min)}` : "any"}${max.length ? ` and <= ${this.escapeHtml(max)}` : ""}</p>`
        : '<p class="text-xs text-slate-500">Allowed range: any integer</p>'

      this.responseTarget.innerHTML =
        `<div class="space-y-2"><input type="number" step="1"${minAttr}${maxAttr} class="w-36 rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm" disabled>${ruleText}</div>`
      return
    }

    if (type === "evidence") {
      this.responseTarget.innerHTML =
        '<input type="text" class="u-w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm" placeholder="https://sites.google.com/tamu.edu/..." disabled>'
      return
    }

    if (type === "dropdown") {
      const optionTags = options
        .map((opt) => `<option>${this.escapeHtml(opt)}</option>`)
        .join("")

      const editableRows = options
        .map(
          (opt, idx) => `<button type="button" class="text-left text-xs text-slate-700 underline-offset-2 hover:underline" data-option-index="${idx}" data-action="question-preview#editOption">${this.escapeHtml(opt)}</button>`
        )
        .join("")

      this.responseTarget.innerHTML = options.length
        ? `<div class="space-y-2"><select class="u-w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm bg-white" disabled>${optionTags}</select><div class="flex flex-col gap-1">${editableRows}</div></div>`
        : '<p class="text-xs text-slate-500">No options yet. Use Manage Options to add choices.</p>'
      return
    }

    if (type === "multiple_choice") {
      const icon = "○"
      const rows = options
        .map(
          (opt, idx) => `
            <div class="flex items-center gap-2 text-sm text-slate-800" data-option-row>
              <span class="text-slate-500" aria-hidden="true">${icon}</span>
              <button type="button" class="flex-1 text-left text-slate-800 underline-offset-2 hover:underline" data-option-index="${idx}" data-action="question-preview#editOption">${this.escapeHtml(
                opt
              )}</button>
            </div>
          `
        )
        .join("")

      const empty = '<p class="text-xs text-slate-500">No options yet. Use Edit options to add choices.</p>'

      this.responseTarget.innerHTML = `
        <div class="space-y-2" data-options-editor>
          ${options.length ? rows : empty}
        </div>
      `
      return
    }

    // Default preview
    this.responseTarget.innerHTML = '<input type="text" class="u-w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm" disabled>'
  }

  renderSafePromptHtml(text) {
    return this.renderPreviewMarkdown(text)
  }

  renderPreviewMarkdown(text) {
    const source = String(text || "").trim()
    if (!source.length) return ""

    const escaped = this.escapeHtml(source)
    return escaped
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*\n][\s\S]*?[^*\n]|[^*\n])\*\*/g, "<strong>$1</strong>")
      .replace(/(^|[^*])\*([^*\n][\s\S]*?[^*\n]|[^*\n])\*(?!\*)/g, "$1<em>$2</em>")
      .replace(/\[([^\]]+)]\(([^\s)]+)(?:\s+"[^"]*")?\)/g, (_full, label, href) => {
        const normalized = this.normalizePreviewHref(href)
        if (!normalized) return label

        const attrs = /^https?:\/\//i.test(normalized)
          ? ' target="_blank" rel="noopener noreferrer"'
          : ""

        return `<a href="${normalized}"${attrs}>${label}</a>`
      })
      .replace(/(^|[\s(>])(https?:\/\/[^\s<]+|www\.[^\s<]+)/gi, (_full, lead, href) => {
        const normalized = this.normalizePreviewHref(href)
        if (!normalized) return `${lead}${href}`

        return `${lead}<a href="${normalized}" target="_blank" rel="noopener noreferrer">${href}</a>`
      })
      .replace(/&lt;br\s*\/?&gt;/gi, "<br>")
      .replace(/\r?\n/g, "<br>")
  }

  normalizePreviewHref(rawHref) {
    const href = String(rawHref || "").trim()
    if (!href.length) return null

    if (/^www\./i.test(href)) return `https://${href}`
    if (/^https?:\/\//i.test(href)) return href
    if (/^mailto:/i.test(href)) return href
    if (/^tel:/i.test(href)) return href
    if (/^\//.test(href)) return href
    if (/^#/.test(href)) return href

    return null
  }

  humanizeType(type) {
    const raw = String(type || "").trim()
    if (!raw.length) return "Question"
    return raw
      .replaceAll("_", " ")
      .replace(/\b\w/g, (ch) => ch.toUpperCase())
  }

  // ---------------------------
  // Inline editing interactions
  // ---------------------------

  editPrompt(event) {
    event?.preventDefault()
    this.startInlineEditor({
      inputEl: this.promptInputTarget,
      displayEl: this.promptTextTarget,
      placeholder: "Question",
      multiline: false
    })
  }

  editDescription(event) {
    event?.preventDefault()
    this.startInlineEditor({
      inputEl: this.descriptionInputTarget,
      displayEl: this.descriptionTextTarget,
      placeholder: "Add description",
      multiline: true
    })
  }

  editOption(event) {
    const el = event?.currentTarget
    const idx = Number(el?.dataset?.optionIndex)
    if (!Number.isFinite(idx)) return

    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    const current = entries[idx]?.label || ""

    const input = document.createElement("input")
    input.type = "text"
    input.value = current
    input.className = "u-w-full u-max-w-xl rounded-md border border-slate-300 px-2 py-1 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-500"

    const replaceBack = (nextValue) => {
      const next = (nextValue || "").trim()
      if (next.length === 0) {
        entries.splice(idx, 1)
      } else {
        const existing = entries[idx] || { label: "", value: "" }
        const nextEntry = { ...existing, label: next }
        if (!nextEntry.value || String(nextEntry.value).trim().length === 0) nextEntry.value = next
        entries[idx] = nextEntry
      }
      this.setOptionEntries(entries)
      this.updateResponsePreview()
    }

    input.addEventListener("blur", () => replaceBack(input.value))
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        input.blur()
      }
      if (e.key === "Escape") {
        e.preventDefault()
        this.updateResponsePreview()
      }
    })

    el.replaceWith(input)
    input.focus()
    input.select()
  }

  removeOption(event) {
    event?.preventDefault()
    event?.stopPropagation()

    const el = event?.currentTarget
    const idx = Number(el?.dataset?.optionIndex)
    if (!Number.isFinite(idx)) return

    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    if (idx < 0 || idx >= entries.length) return

    entries.splice(idx, 1)
    this.setOptionEntries(entries)
    this.updateResponsePreview()
  }

  addOption(event) {
    event?.preventDefault()
    const entries = this.parseOptionEntries(this.answerOptionsInputTarget?.value)
    const nextLabel = `Option ${entries.length + 1}`
    const nextValue = this.suggestNextOptionValue(entries, nextLabel)
    entries.push({ label: nextLabel, value: nextValue })
    this.setOptionEntries(entries)
    this.updateResponsePreview()

    // Focus the new option's inline editor.
    requestAnimationFrame(() => {
      const last = this.responseTarget.querySelector('[data-option-index="' + (entries.length - 1) + '"]')
      last?.click()
    })
  }

  handleKeyDown(event) {
    // Allow Enter to start editing prompt when focused on it.
    if (event.key !== "Enter") return
    if (event.target === this.promptTextTarget) {
      event.preventDefault()
      this.editPrompt(event)
    }
  }

  startInlineEditor({ inputEl, displayEl, placeholder, multiline }) {
    if (!inputEl || !displayEl) return

    // Capture the current display element's identity so we can restore it.
    const tagName = displayEl.tagName.toLowerCase()
    const className = displayEl.className
    const targetName = displayEl.dataset.questionPreviewTarget
    const action = displayEl.getAttribute("data-action")

    const textarea = document.createElement(multiline ? "textarea" : "input")
    if (!multiline) textarea.type = "text"

    textarea.value = (inputEl.value || "").trim()
    textarea.placeholder = placeholder || ""
    textarea.className =
      "u-w-full rounded-md border border-slate-300 bg-white px-2 py-1 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-500"

    if (multiline) {
      textarea.rows = 2
      textarea.style.resize = "vertical"
    }

    const restoreDisplayEl = () => {
      const restored = document.createElement(tagName)
      restored.className = className
      if (targetName) restored.dataset.questionPreviewTarget = targetName
      if (action) restored.setAttribute("data-action", action)
      textarea.replaceWith(restored)
      return restored
    }

    let canceled = false

    const commit = () => {
      inputEl.value = textarea.value
      inputEl.dispatchEvent(new Event("input", { bubbles: true }))
      restoreDisplayEl()
      this.update()
    }

    const cancel = () => {
      canceled = true
      restoreDisplayEl()
      this.update()
    }

    textarea.addEventListener("blur", () => {
      if (canceled) return
      commit()
    })
    textarea.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault()
        cancel()
      }
      if (!multiline && e.key === "Enter") {
        e.preventDefault()
        textarea.blur()
      }
    })

    // Replace the visible display element with the editor.
    displayEl.replaceWith(textarea)

    textarea.focus()
    textarea.select()

  }

  // ---------------------------
  // Options parsing/serialization
  // ---------------------------

  // Backwards-compatible helper (returns labels only)
  parseOptions(raw) {
    return this.parseOptionEntries(raw).map((e) => e.label)
  }

  setOptionEntries(entries) {
    if (!this.hasAnswerOptionsInputTarget) return

    const normalized = (entries || [])
      .map((e) => ({
        label: this.normalizeOptionString(e?.label),
        value: this.normalizeOptionString(e?.value ?? e?.label)
      }))
      .filter((e) => e.label.length)

    this.answerOptionsInputTarget.value = this.serializeOptionEntries(normalized)
    this.answerOptionsInputTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  parseOptionEntries(raw) {
    const text = (raw || "").trim()
    if (!text.length) return []

    const parsed = this.tryParseJsonArray(text)
    if (parsed) {
      return this.normalizeEntries(this.parseEntriesFromJsonArray(parsed))
    }

    // Fallback: newline-first, comma if single-line.
    const parts = text.includes("\n") ? text.split(/\r?\n/) : text.split(",")
    const lines = parts.map((s) => this.normalizeOptionString(s)).filter((s) => s.length)
    return this.normalizeEntries(lines.map((s) => ({ label: s, value: s })))
  }

  detectOptionsFormat() {
    const text = (this.answerOptionsInputTarget?.value || "").trim()
    if (!text.length) return "newline"

    const parsed = this.tryParseJsonArray(text)
    if (!parsed) return "newline"

    if (parsed.some((e) => Array.isArray(e))) return "json_pairs"
    if (parsed.some((e) => e && typeof e === "object" && !Array.isArray(e))) return "json_objects"
    return "json_strings"
  }

  tryParseJsonArray(text) {
    if (!(text.startsWith("[") && text.endsWith("]"))) return null
    try {
      const parsed = JSON.parse(text)
      return Array.isArray(parsed) ? parsed : null
    } catch {
      // A lot of option lists are copied in with smart quotes; normalize and retry.
      const normalized = String(text)
        .replace(/[“”]/g, '"')
        .replace(/[‘’]/g, "'")
      try {
        const parsed = JSON.parse(normalized)
        return Array.isArray(parsed) ? parsed : null
      } catch {
        return null
      }
    }
  }

  parseEntriesFromJsonArray(arr) {
    // Mirrors Question#answer_option_pairs / #answer_options_list behavior.
    const entries = []

    const allStrings = arr.every((e) => typeof e === "string")
    if (allStrings && this.looksLikeAlternatingPairs(arr)) {
      // Legacy oddity: ["1 — Label", "1", "2 — Label", "2", ...]
      this.optionsFormat = "json_pairs"
      for (let i = 0; i < arr.length; i += 2) {
        const label = this.normalizeOptionString(arr[i])
        const value = this.normalizeOptionString(arr[i + 1])
        if (!label.length) continue
        entries.push({ label, value: value || this.extractLeadingValue(label) || label })
      }
      return entries
    }

    for (const entry of arr) {
      if (typeof entry === "string") {
        const s = this.normalizeOptionString(entry)
        if (!s.length) continue
        entries.push({ label: s, value: s })
        continue
      }

      if (Array.isArray(entry)) {
        const label = this.normalizeOptionString(entry[0])
        const value = this.normalizeOptionString(entry[1] ?? entry[0])
        if (!label.length) continue
        entries.push({ label, value: value || label })
        continue
      }

      if (entry && typeof entry === "object") {
        const label = this.normalizeOptionString(entry.label ?? entry["label"] ?? entry.value ?? entry["value"])
        const value = this.normalizeOptionString(entry.value ?? entry["value"] ?? label)
        if (!label.length) continue
        entries.push({ label, value: value || label })
        continue
      }
    }

    return entries
  }

  normalizeEntries(entries) {
    // Merge wrapped/continuation lines and drop value-only duplicates.
    const out = []

    for (const e of (entries || [])) {
      const label = this.normalizeOptionString(e?.label)
      const value = this.normalizeOptionString(e?.value ?? label)
      if (!label.length) continue

      if (this.isValueOnlyLine(label) && out.length) {
        const prev = out[out.length - 1]
        const prevLeading = this.extractLeadingValue(prev.label)
        if (prevLeading && prevLeading === label) {
          prev.value = prev.value || label
          continue
        }
      }

      out.push({ label, value: value || label })
    }

    return out
  }

  looksLikeAlternatingPairs(strings) {
    if (strings.length < 2 || strings.length % 2 !== 0) return false
    for (let i = 0; i < strings.length; i += 2) {
      const label = this.normalizeOptionString(strings[i])
      const value = this.normalizeOptionString(strings[i + 1])
      if (!label.length || !value.length) return false
      if (!this.isValueOnlyLine(value)) return false
      const leading = this.extractLeadingValue(label)
      if (!leading || leading !== value) return false
    }
    return true
  }

  looksLikeContinuation(label) {
    if (this.isValueOnlyLine(label)) return false

    const trimmed = String(label || "").trim()

    // Only merge wrapped lines that look like sentence continuations.
    // (E.g. "with limited variation ...")
    if (!/^[a-z]/.test(trimmed)) return false

    return !/^\s*(\d+|[A-Za-z])\s*(—|–|-)/.test(label)
  }

  isValueOnlyLine(label) {
    return /^\s*\d+\s*$/.test(label)
  }

  extractLeadingValue(label) {
    const m = String(label || "").match(/^\s*(\d+)\s*(—|–|-)/)
    return m ? m[1] : ""
  }

  serializeOptionEntries(entries) {
    const format = this.optionsFormat || this.detectOptionsFormat()

    if (format === "json_pairs") {
      return JSON.stringify(entries.map((e) => [e.label, e.value || e.label]))
    }

    if (format === "json_objects") {
      return JSON.stringify(entries.map((e) => ({ label: e.label, value: e.value || e.label })))
    }

    if (format === "json_strings") {
      return JSON.stringify(entries.map((e) => e.label))
    }

    return entries.map((e) => e.label).join("\n")
  }

  suggestNextOptionValue(entries, nextLabel) {
    const values = (entries || [])
      .map((e) => String(e?.value ?? "").trim())
      .filter((v) => v.length)

    const allInts = values.length && values.every((v) => /^\d+$/.test(v))
    if (allInts) {
      const max = Math.max(...values.map((v) => Number(v)))
      return String(max + 1)
    }

    return nextLabel
  }

  normalizeOptionString(value) {
    let s = String(value ?? "").trim()
    if (!s.length) return ""

    // Common artifacts from array-ish strings when delimiter-splitting JSON.
    // Examples:
    //   ["Yes"  -> Yes
    //   "No"]  -> No
    if (s.startsWith("[")) s = s.slice(1).trim()
    if (s.endsWith("]")) s = s.slice(0, -1).trim()

    // Remove one layer of surrounding quotes.
    if (
      (s.startsWith('"') && s.endsWith('"')) ||
      (s.startsWith("'") && s.endsWith("'")) ||
      (s.startsWith("“") && s.endsWith("”")) ||
      (s.startsWith("‘") && s.endsWith("’"))
    ) {
      s = s.slice(1, -1).trim()
    }

    // Trim stray smart quotes that can appear after splitting.
    s = s.replace(/^[“”‘’]+/, "").replace(/[“”‘’]+$/, "").trim()

    return s
  }


  escapeHtml(input) {
    return String(input)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\"/g, "&quot;")
      .replace(/'/g, "&#039;")
  }
}
