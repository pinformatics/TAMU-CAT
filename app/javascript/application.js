import "@hotwired/turbo-rails"
import "controllers"

// Accessibility helpers for high contrast mode and text-to-speech support.

// -----------------------------
// High-contrast mode
// -----------------------------

const HIGH_CONTRAST_KEY = "mha_high_contrast"

function applyHighContrast(enabled) {
  const body = document.body
  if (!body) return

  if (enabled) {
    body.classList.add("high-contrast")
  } else {
    body.classList.remove("high-contrast")
  }

  // Keep all toggle switches in sync.
  const controls = document.querySelectorAll("[data-high-contrast-toggle]")
  controls.forEach((el) => {
    if (!(el instanceof HTMLInputElement) || el.type !== "checkbox") return

    el.checked = enabled
    el.setAttribute("aria-checked", enabled ? "true" : "false")
    if (el.dataset.toggleInitialized === "true") {
      el.dataset.togglePrev = enabled ? "true" : "false"
    }
  })
}

function initHighContrastToggle() {
  const controls = document.querySelectorAll("[data-high-contrast-toggle]")
  if (!controls.length) return

  // Restore previous preference (if any)
  const stored = window.localStorage.getItem(HIGH_CONTRAST_KEY)
  const initialEnabled = stored === "true"
  applyHighContrast(initialEnabled)

  controls.forEach((el) => {
    if (!(el instanceof HTMLInputElement) || el.type !== "checkbox") return

    // Avoid adding duplicate listeners on Turbo navigations
    if (el.dataset.hcInitialized === "true") return
    el.dataset.hcInitialized = "true"

    const handler = () => {
      const next = el.checked
      applyHighContrast(next)
      window.localStorage.setItem(HIGH_CONTRAST_KEY, String(next))
    }

    el.addEventListener("change", handler)
  })
}

// -----------------------------
// Text-to-speech: Read Page Aloud
// -----------------------------

let currentUtterance = null

const TTS_RATE_KEY = "mha:tts_rate"

let ttsHighlightState = {
  overlayEl: null,
  nodes: [],
  text: "",
  currentRange: null,
  rafId: null,
  scrollHandlerInstalled: false
}

function ensureTTSHighlightOverlay() {
  if (ttsHighlightState.overlayEl && document.body.contains(ttsHighlightState.overlayEl)) {
    return ttsHighlightState.overlayEl
  }

  const el = document.createElement("div")
  el.className = "c-tts-highlight"
  el.setAttribute("aria-hidden", "true")
  document.body.appendChild(el)
  ttsHighlightState.overlayEl = el
  return el
}

function hideTTSHighlight() {
  const el = ttsHighlightState.overlayEl
  if (!el) return
  el.style.width = "0"
  el.style.height = "0"
}

function scheduleTTSHighlightUpdate() {
  if (ttsHighlightState.rafId) return
  ttsHighlightState.rafId = window.requestAnimationFrame(() => {
    ttsHighlightState.rafId = null
    updateTTSHighlightFromCurrentRange()
  })
}

function updateTTSHighlightFromCurrentRange() {
  const range = ttsHighlightState.currentRange
  if (!range) {
    hideTTSHighlight()
    return
  }

  const rect = range.getBoundingClientRect()
  if (!rect || rect.width === 0 || rect.height === 0) {
    hideTTSHighlight()
    return
  }

  const overlay = ensureTTSHighlightOverlay()
  overlay.style.left = `${Math.max(0, rect.left)}px`
  overlay.style.top = `${Math.max(0, rect.top)}px`
  overlay.style.width = `${Math.max(0, rect.width)}px`
  overlay.style.height = `${Math.max(0, rect.height)}px`
}

function getReadableTextNodes(container) {
  const nodes = []

  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node || !node.nodeValue) return NodeFilter.FILTER_REJECT
      if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT

      const parent = node.parentElement
      if (!parent) return NodeFilter.FILTER_REJECT
      const tag = parent.tagName ? parent.tagName.toLowerCase() : ""
      if (tag === "script" || tag === "style" || tag === "noscript") return NodeFilter.FILTER_REJECT
      if (parent.closest("[aria-hidden='true'], [hidden]")) return NodeFilter.FILTER_REJECT

      return NodeFilter.FILTER_ACCEPT
    }
  })

  let current = walker.nextNode()
  while (current) {
    nodes.push(current)
    current = walker.nextNode()
  }

  return nodes
}

function buildTextMapFromNodes(nodes) {
  const parts = []
  const mapped = []
  let index = 0

  nodes.forEach((node) => {
    const value = (node.nodeValue || "").replace(/\s+/g, " ").trim()
    if (!value) return

    if (parts.length) {
      parts.push(" ")
      index += 1
    }

    mapped.push({ node, start: index, length: value.length, text: value })
    parts.push(value)
    index += value.length
  })

  return { text: parts.join(""), mapped }
}

function findMappedNodeAtIndex(mapped, charIndex) {
  let lo = 0
  let hi = mapped.length - 1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    const item = mapped[mid]
    const start = item.start
    const end = item.start + item.length

    if (charIndex < start) {
      hi = mid - 1
    } else if (charIndex >= end) {
      lo = mid + 1
    } else {
      return item
    }
  }
  return null
}

function computeWordBounds(text, charIndex) {
  const clamped = Math.max(0, Math.min(charIndex, Math.max(0, text.length - 1)))
  let start = clamped
  let end = clamped

  while (start > 0 && !/\s/.test(text[start - 1])) start -= 1
  while (end < text.length && !/\s/.test(text[end])) end += 1

  return { start, end }
}

function highlightWordAtCharIndex(charIndex) {
  const mapped = ttsHighlightState.nodes
  const text = ttsHighlightState.text
  if (!mapped.length || !text) return

  const bounds = computeWordBounds(text, charIndex)
  const item = findMappedNodeAtIndex(mapped, bounds.start)
  if (!item) {
    hideTTSHighlight()
    return
  }

  const offsetInItem = bounds.start - item.start
  const wordLength = Math.max(1, bounds.end - bounds.start)
  const startOffset = Math.max(0, Math.min(offsetInItem, (item.node.nodeValue || "").length))
  const endOffset = Math.max(startOffset + 1, Math.min(startOffset + wordLength, (item.node.nodeValue || "").length))

  try {
    const range = document.createRange()
    range.setStart(item.node, startOffset)
    range.setEnd(item.node, endOffset)
    ttsHighlightState.currentRange = range
    scheduleTTSHighlightUpdate()
  } catch {
    hideTTSHighlight()
  }
}

function stopReading() {
  if (window.speechSynthesis && window.speechSynthesis.speaking) {
    window.speechSynthesis.cancel()
  }
  currentUtterance = null

  ttsHighlightState.currentRange = null
  hideTTSHighlight()

  const controls = document.querySelectorAll("[data-tts-toggle]")
  controls.forEach((el) => {
    if (!(el instanceof HTMLInputElement) || el.type !== "checkbox") return

    el.checked = false
    el.setAttribute("aria-checked", "false")
    if (el.dataset.toggleInitialized === "true") {
      el.dataset.togglePrev = "false"
    }
  })
}

function startReading() {
  if (!("speechSynthesis" in window)) {
    alert("Text-to-speech is not supported in this browser.")
    stopReading()
    return
  }

  const main = document.querySelector("main")
  const container = main || document.body
  const rawNodes = getReadableTextNodes(container)
  const { text, mapped } = buildTextMapFromNodes(rawNodes)
  ttsHighlightState.nodes = mapped
  ttsHighlightState.text = text

  if (!text || !text.trim()) {
    alert("There is no readable content on this page.")
    stopReading()
    return
  }

  stopReading() // cancel any previous utterance just in case

  const utterance = new SpeechSynthesisUtterance(text)
  utterance.lang = "en-US"
  try {
    const storedRate = window.localStorage.getItem(TTS_RATE_KEY)
    const parsedRate = storedRate ? parseFloat(storedRate) : 1.0
    const rate = Number.isFinite(parsedRate) ? Math.max(0.25, Math.min(2.0, parsedRate)) : 1.0
    utterance.rate = rate
  } catch {
    utterance.rate = 1.0
  }
  utterance.pitch = 1.0

  utterance.onstart = () => {
    const controls = document.querySelectorAll("[data-tts-toggle]")
    controls.forEach((el) => {
      if (!(el instanceof HTMLInputElement) || el.type !== "checkbox") return

      el.checked = true
      el.setAttribute("aria-checked", "true")
      if (el.dataset.toggleInitialized === "true") {
        el.dataset.togglePrev = "true"
      }
    })
  }

  utterance.onend = stopReading
  utterance.onerror = stopReading

  utterance.onboundary = (event) => {
    if (!event || typeof event.charIndex !== "number") return
    highlightWordAtCharIndex(event.charIndex)
  }

  if (!ttsHighlightState.scrollHandlerInstalled) {
    ttsHighlightState.scrollHandlerInstalled = true
    window.addEventListener("scroll", scheduleTTSHighlightUpdate, { passive: true })
    window.addEventListener("resize", scheduleTTSHighlightUpdate)
  }

  currentUtterance = utterance
  window.speechSynthesis.speak(utterance)
}

function initTTSToggle() {
  const controls = document.querySelectorAll("[data-tts-toggle]")
  if (!controls.length) return

  // If API is missing, disable the control
  if (!("speechSynthesis" in window)) {
    controls.forEach((el) => {
      if (!(el instanceof HTMLInputElement) || el.type !== "checkbox") return
      el.disabled = true
    })
    return
  }

  controls.forEach((el) => {
    if (!(el instanceof HTMLInputElement) || el.type !== "checkbox") return

    if (el.dataset.ttsInitialized === "true") return
    el.dataset.ttsInitialized = "true"

    const handler = () => {
      if (el.checked) {
        startReading()
      } else {
        stopReading()
      }
    }

    el.addEventListener("change", handler)
  })
}

// -----------------------------
// Survey branching: Yes/No parents
// -----------------------------

function initSurveyBranching() {
  const forms = document.querySelectorAll(".survey-form")
  if (!forms.length) return

  forms.forEach((form) => {
    if (form.dataset.branchInitialized === "true") return
    form.dataset.branchInitialized = "true"

    const parents = form.querySelectorAll('[data-branch-parent="true"]')
    if (!parents.length) return

    const setChildVisibility = (parentId, shouldShow) => {
      const children = form.querySelectorAll(`[data-branch-child-of="${parentId}"]`)
      children.forEach((child) => {
        child.classList.toggle("hidden", !shouldShow)
        child.setAttribute("aria-hidden", shouldShow ? "false" : "true")

        const inputs = child.querySelectorAll("input, select, textarea, button")
        inputs.forEach((el) => {
          if (el.getAttribute("type") === "hidden") return
          el.disabled = !shouldShow
        })
      })
    }

    parents.forEach((parent) => {
      const parentId = parent.dataset.branchParentId
      const targetValue = (parent.dataset.branchTargetValue || "").trim()
      if (!parentId || !targetValue) return

      const inputName = `answers[${parentId}]`
      const inputs = form.querySelectorAll(`input[name="${inputName}"]`)
      if (!inputs.length) return

      const update = () => {
        const checked = form.querySelector(`input[name="${inputName}"]:checked`)
        const currentValue = (checked ? checked.value : "").trim()
        setChildVisibility(parentId, currentValue === targetValue)
      }

      inputs.forEach((input) => {
        input.addEventListener("change", update)
      })

      update()
    })
  })
}

// -----------------------------
// Survey keyboard shortcuts (multiple choice + dropdown)
// -----------------------------

function initSurveyQuestionKeyboardShortcuts() {
  const body = document.body
  if (!body) return
  if (body.dataset.surveyKeyboardShortcutsInitialized === "true") return
  body.dataset.surveyKeyboardShortcutsInitialized = "true"

  const isTypingField = (el) => {
    if (!(el instanceof Element)) return false
    const tag = (el.tagName || "").toLowerCase()
    if (tag === "textarea") return true

    if (tag !== "input") return false
    const type = ((el.getAttribute("type") || "text") + "").toLowerCase()
    return (
      type === "text" ||
      type === "search" ||
      type === "email" ||
      type === "url" ||
      type === "password" ||
      type === "tel" ||
      type === "number" ||
      type === "date" ||
      type === "time"
    )
  }

  const handler = (e) => {
    if (e.defaultPrevented) return
    if (e.metaKey || e.ctrlKey || e.altKey) return
    if (typeof e.key !== "string" || !/^[0-9]$/.test(e.key)) return

    const target = e.target
    if (!(target instanceof Element)) return
    if (isTypingField(target)) return

    // Only on survey pages
    if (!target.closest(".survey-form")) return

    // Find the nearest question container for both survey render paths:
    // - surveys/show: <article data-question-id ...>
    // - survey_responses/_survey_response: <article class="c-question-card" ...>
    const container = target.closest('[data-question-id], .c-question-card, article[id^="question-block-"]')
    if (!container) return

    const raw = e.key === "0" ? 10 : parseInt(e.key, 10)
    if (!Number.isFinite(raw) || raw < 1) return
    const index = raw - 1

    const radios = Array.from(container.querySelectorAll('input[type="radio"]')).filter((el) => {
      return el instanceof HTMLInputElement && !el.disabled
    })

    if (radios.length) {
      if (index >= radios.length) return
      e.preventDefault()

      const radio = radios[index]
      radio.checked = true
      radio.focus()
      radio.dispatchEvent(new Event("input", { bubbles: true }))
      radio.dispatchEvent(new Event("change", { bubbles: true }))
      return
    }

    const select = container.querySelector('select:not([multiple])')
    if (!(select instanceof HTMLSelectElement) || select.disabled) return

    const options = Array.from(select.options || []).filter((opt) => {
      if (!opt || opt.disabled) return false
      // Skip blank placeholder options.
      return (opt.value || "").toString() !== ""
    })

    if (index >= options.length) return
    e.preventDefault()

    select.value = options[index].value
    select.dispatchEvent(new Event("input", { bubbles: true }))
    select.dispatchEvent(new Event("change", { bubbles: true }))
  }

  // Use capture so we still see events when a native <select> is focused/open.
  document.addEventListener("keydown", handler, true)
  // Fallback for some browsers that behave oddly with open <select> controls.
  document.addEventListener("keypress", handler, true)
}

function initOtherChoiceInputs() {
  const forms = document.querySelectorAll(".survey-form")
  if (!forms.length) return

  forms.forEach((form) => {
    if (form.dataset.otherChoiceInitialized === "true") return
    form.dataset.otherChoiceInitialized = "true"

    const wrappers = form.querySelectorAll("[data-other-input-wrapper]")
    if (!wrappers.length) return

    const sync = (questionId) => {
      // Support both editable survey forms (answers[ID]) and read-only displays
      // (readonly_answers[ID]) by matching on the trailing [ID].
      const selectedRadio = form.querySelector(`input[type="radio"][name$="[${questionId}]"]:checked`)
      const select = form.querySelector(`select[name$="[${questionId}]"]`)
      const currentValue = (selectedRadio ? selectedRadio.value : (select ? select.value : "")).trim()

      const matchingWrappers = form.querySelectorAll(`[data-other-input-wrapper][data-other-for-question-id="${questionId}"]`)
      if (!matchingWrappers.length) return

      matchingWrappers.forEach((wrapper) => {
        const otherChoiceValue = (wrapper.dataset.otherChoiceValue || "Other").trim()
        const isOther = currentValue && currentValue === otherChoiceValue

        wrapper.classList.toggle("hidden", !isOther)
        wrapper.setAttribute("aria-hidden", isOther ? "false" : "true")

        const input = wrapper.querySelector("input")
        // Only manage disabled state for editable inputs (other_answers[ID]).
        // Read-only pages intentionally keep inputs disabled.
        if (input && (input.name || "").startsWith("other_answers[")) {
          input.disabled = !isOther
        }
      })
    }

    wrappers.forEach((wrapper) => {
      const qid = wrapper.dataset.otherForQuestionId
      if (!qid) return

      const radios = form.querySelectorAll(`input[type="radio"][name$="[${qid}]"]`)
      radios.forEach((radio) => {
        radio.addEventListener("change", () => sync(qid))
      })

      const select = form.querySelector(`select[name$="[${qid}]"]`)
      if (select) {
        select.addEventListener("change", () => sync(qid))
      }

      sync(qid)
    })
  })
}

// -----------------------------
// Reusable toggle switch (confirm + submit)
// -----------------------------

function initToggleSwitches() {
  const inputs = document.querySelectorAll('input[type="checkbox"][data-toggle-switch="true"]')
  if (!inputs.length) return

  inputs.forEach((input) => {
    if (input.dataset.toggleInitialized === "true") return
    input.dataset.toggleInitialized = "true"

    // Track last confirmed state so cancel can revert cleanly.
    input.dataset.togglePrev = input.checked ? "true" : "false"
    input.setAttribute("aria-checked", input.checked ? "true" : "false")

    input.addEventListener("change", (e) => {
      const nextChecked = input.checked
      const prevChecked = input.dataset.togglePrev === "true"

      const confirmOn = input.getAttribute("data-confirm-on")
      const confirmOff = input.getAttribute("data-confirm-off")
      const message = nextChecked ? confirmOn : confirmOff

      if (message && !window.confirm(message)) {
        // Revert to previous value and do not submit.
        input.checked = prevChecked
        input.setAttribute("aria-checked", prevChecked ? "true" : "false")
        return
      }

      input.dataset.togglePrev = nextChecked ? "true" : "false"
      input.setAttribute("aria-checked", nextChecked ? "true" : "false")

      const form = input.closest("form")
      if (form) form.requestSubmit()
    })
  })
}

// -----------------------------
// Combobox (searchable dropdown)
// -----------------------------

function initComboboxes() {
  const widgets = document.querySelectorAll('[data-combobox="true"]')
  if (!widgets.length) return

  widgets.forEach((widget) => {
    if (widget.dataset.comboboxInitialized === "true") return
    widget.dataset.comboboxInitialized = "true"

    const input = widget.querySelector('[data-combobox-input="true"]')
    const hidden = widget.querySelector('[data-combobox-value="true"]')
    const menu = widget.querySelector('[data-combobox-menu="true"]')
    const empty = widget.querySelector('[data-combobox-empty="true"]')
    if (!input || !hidden || !menu) return

    const options = Array.from(widget.querySelectorAll('[data-combobox-option="true"]'))

    const setOpen = (open) => {
      menu.classList.toggle("hidden", !open)
      input.setAttribute("aria-expanded", open ? "true" : "false")
    }

    const filter = () => {
      const q = (input.value || "").trim().toLowerCase()
      let visible = 0

      options.forEach((btn) => {
        const haystack = (btn.dataset.comboboxOptionSearch || "").toLowerCase()
        const match = q === "" || haystack.includes(q)
        btn.hidden = !match
        if (match) visible += 1
      })

      if (empty) empty.hidden = !(q !== "" && visible === 0)
    }

    const selectOption = (btn) => {
      const value = btn.dataset.comboboxOptionValue || ""
      const label = btn.dataset.comboboxOptionLabel || ""
      hidden.value = value
      input.value = label
      setOpen(false)
    }

    input.addEventListener("focus", () => {
      filter()
      setOpen(true)
    })

    input.addEventListener("input", () => {
      hidden.value = "" // user is typing; clear selection until chosen
      filter()
      setOpen(true)
    })

    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        setOpen(false)
        return
      }
    })

    options.forEach((btn) => {
      btn.addEventListener("click", () => selectOption(btn))
    })

    document.addEventListener("click", (e) => {
      if (!widget.contains(e.target)) setOpen(false)
    })
  })
}

// -----------------------------
// Impersonation: lock write forms (UI)
// -----------------------------

function initImpersonationReadOnlyUI() {
  const body = document.body
  if (!body) return
  if (body.dataset.impersonating !== "true") return

  const forms = document.querySelectorAll("form")
  forms.forEach((form) => {
    if (form.dataset.impersonationLocked === "true") return

    const rawMethod = (form.getAttribute("method") || "get").toLowerCase()
    if (rawMethod === "get") return

    const action = (form.getAttribute("action") || "").toLowerCase()
    const override = form.querySelector('input[name="_method"]')
    const intendedMethod = (override ? override.value : rawMethod).toLowerCase()

    const isExitOrSignOut =
      intendedMethod === "delete" &&
      (action.endsWith("/impersonation") ||
        action.endsWith("/advisor_impersonation") ||
        action.endsWith("/users/sign_out") ||
        action.endsWith("/sign_out"))

    if (isExitOrSignOut) return

    form.dataset.impersonationLocked = "true"
    form.setAttribute("aria-disabled", "true")

    const controls = form.querySelectorAll("input, select, textarea, button")
    controls.forEach((el) => {
      if (el instanceof HTMLInputElement && el.type === "hidden") return
      el.disabled = true
    })
  })
}


// -----------------------------
// Disable submit if unchanged (survey response edit)
// -----------------------------

function initDisableSubmitIfUnchanged() {
  const forms = document.querySelectorAll('form[data-disable-submit-if-unchanged="true"]')
  if (!forms.length) return

  const serialize = (form) => {
    const entries = []

    const elements = Array.from(form.elements || [])
    elements.forEach((el) => {
      if (!(el instanceof HTMLInputElement || el instanceof HTMLSelectElement || el instanceof HTMLTextAreaElement)) return

      if (el.disabled) return
      if (!el.name) return

      if (el instanceof HTMLInputElement) {
        const type = (el.type || "").toLowerCase()

        // Ignore Rails plumbing + buttons.
        if (type === "hidden" || type === "submit" || type === "button" || type === "reset") return

        if (type === "radio") {
          if (!el.checked) return
          entries.push([ el.name, el.value ])
          return
        }

        if (type === "checkbox") {
          entries.push([ el.name, el.checked ? (el.value || "on") : "" ])
          return
        }

        entries.push([ el.name, el.value || "" ])
        return
      }

      if (el instanceof HTMLSelectElement) {
        if (el.multiple) {
          const values = Array.from(el.selectedOptions || []).map((opt) => opt.value)
          entries.push([ el.name, values.sort().join("\u0000") ])
        } else {
          entries.push([ el.name, el.value || "" ])
        }
        return
      }

      // textarea
      entries.push([ el.name, el.value || "" ])
    })

    entries.sort((a, b) => {
      if (a[0] === b[0]) return a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0
      return a[0] < b[0] ? -1 : 1
    })

    return JSON.stringify(entries)
  }

  const setDisabled = (form, disabled) => {
    const buttons = form.querySelectorAll('[data-save-button="true"]')
    buttons.forEach((btn) => {
      btn.disabled = !!disabled
      if (disabled) {
        btn.setAttribute("aria-disabled", "true")
      } else {
        btn.removeAttribute("aria-disabled")
      }
    })
  }

  forms.forEach((form) => {
    if (form.dataset.disableSubmitInitialized === "true") return
    form.dataset.disableSubmitInitialized = "true"

    const baseline = serialize(form)
    form.dataset.disableSubmitBaseline = baseline

    const refresh = () => {
      const current = serialize(form)
      const unchanged = current === form.dataset.disableSubmitBaseline
      setDisabled(form, unchanged)
    }

    // Disable on first load unless already dirty.
    refresh()

    let scheduled = false
    const scheduleRefresh = () => {
      if (scheduled) return
      scheduled = true
      window.requestAnimationFrame(() => {
        scheduled = false
        refresh()
      })
    }

    form.addEventListener("input", scheduleRefresh)
    form.addEventListener("change", scheduleRefresh)
  })
}


// -----------------------------
// Hover dropdown support for <details>
// -----------------------------

function initHoverDropdownDetails() {
  // Some browsers effectively keep <details> content non-rendered unless [open] is set.
  // For hover-based dropdowns implemented with <details>/<summary>, keep [open]
  // in sync with hover/focus so menus behave like the profile dropdown.
  document.querySelectorAll("details.u-hover-dropdown").forEach((details) => {
    if (details.dataset.hoverDropdownInitialized === "true") return
    details.dataset.hoverDropdownInitialized = "true"

    let closeTimer = null

    const openNow = () => {
      if (closeTimer) {
        window.clearTimeout(closeTimer)
        closeTimer = null
      }
      details.open = true
    }

    const closeSoon = () => {
      if (closeTimer) window.clearTimeout(closeTimer)
      closeTimer = window.setTimeout(() => {
        if (details.matches(":focus-within")) return
        details.open = false
      }, 75)
    }

    details.addEventListener("mouseenter", openNow)
    details.addEventListener("mouseleave", closeSoon)
    details.addEventListener("focusin", openNow)
    details.addEventListener("focusout", closeSoon)

    // If a click toggles [open] off while still hovered/focused, immediately restore it.
    details.addEventListener("toggle", () => {
      if (details.open) return
      if (details.matches(":hover") || details.matches(":focus-within")) {
        details.open = true
      }
    })
  })
}

// -----------------------------
// Server-backed markdown preview
// -----------------------------

function initServerMarkdownPreviews() {
  document.querySelectorAll("[data-server-markdown-preview='true']").forEach((container) => {
    if (container.dataset.serverMarkdownPreviewInitialized === "true") return
    container.dataset.serverMarkdownPreviewInitialized = "true"

    const input = container.querySelector("[data-preview-input='true']")
    const output = container.querySelector("[data-preview-output='true']")
    const previewUrl = container.dataset.previewUrl
    const wrapperClass = container.dataset.previewWrapperClass || "c-rich-text"
    const minHeadingLevel = Number(container.dataset.previewMinHeadingLevel || "3")
    const emptyHtml = container.dataset.previewEmptyHtml || ""

    if (!input || !output || !previewUrl) return

    let timeoutId = null
    let abortController = null
    let requestSequence = 0

    const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content || ""

    const setEmpty = () => {
      output.innerHTML = emptyHtml
    }

    const renderPreview = async () => {
      const text = input.value || ""
      if (!text.trim().length) {
        setEmpty()
        return
      }

      if (abortController) abortController.abort()
      abortController = new AbortController()
      const requestId = ++requestSequence

      try {
        const response = await fetch(previewUrl, {
          method: "POST",
          credentials: "same-origin",
          headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
            "X-CSRF-Token": csrfToken()
          },
          body: JSON.stringify({
            text,
            wrapper_class: wrapperClass,
            min_heading_level: minHeadingLevel
          }),
          signal: abortController.signal
        })

        if (!response.ok) throw new Error(`Markdown preview failed with ${response.status}`)

        const payload = await response.json()
        if (requestId !== requestSequence) return

        output.innerHTML = payload.html || ""
      } catch (error) {
        if (error.name === "AbortError") return
        output.innerHTML = '<div class="c-markdown-preview__error">Preview unavailable right now.</div>'
      }
    }

    const scheduleRender = () => {
      if (timeoutId) window.clearTimeout(timeoutId)
      timeoutId = window.setTimeout(() => {
        timeoutId = null
        renderPreview()
      }, 180)
    }

    input.addEventListener("input", scheduleRender)
    renderPreview()
  })
}


// -----------------------------
// Hook into Turbo / DOM load
// -----------------------------

function initAccessibilityFeatures() {
  initHighContrastToggle()
  initTTSToggle()
  initSurveyBranching()
  initSurveyQuestionKeyboardShortcuts()
  initOtherChoiceInputs()
  initToggleSwitches()
  initComboboxes()
  initImpersonationReadOnlyUI()
  initDisableSubmitIfUnchanged()
  initHoverDropdownDetails()
  initServerMarkdownPreviews()
}

document.addEventListener("turbo:load", initAccessibilityFeatures)
document.addEventListener("DOMContentLoaded", initAccessibilityFeatures)

console.debug("[Application] JS bootstrap loaded (once)")
