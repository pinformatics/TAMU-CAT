import "@hotwired/turbo-rails"
import Sortable from "sortablejs"

import("controllers").catch((error) => {
  console.error("[Application] Stimulus controllers failed to load", error)
})

// Accessibility helpers for high contrast mode and text-to-speech support.

// -----------------------------
// App modal dialogs
// -----------------------------

let appModalId = 0
let appModalConfirmInstalled = false
let turboFalseConfirmFallbackInstalled = false
let dismissibleFlashesInstalled = false
let surveyBranchingEventsInstalled = false
let inlineModalEventsInstalled = false
let comboboxEventsInstalled = false

function escapeModalText(value) {
  const element = document.createElement("span")
  element.textContent = value == null ? "" : String(value)
  return element.innerHTML
}

function modalBodyHtml(message) {
  const lines = String(message || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)

  if (lines.length === 0) {
    return "<p>Continue?</p>"
  }

  const parts = []
  let listItems = []

  lines.forEach((line) => {
    if (line.startsWith("- ")) {
      listItems.push(line.slice(2))
      return
    }

    if (listItems.length > 0) {
      parts.push(`
        <ul class="c-modal__review-list">
          ${listItems.map((item) => `<li>${escapeModalText(item)}</li>`).join("")}
        </ul>
      `)
      listItems = []
    }

    parts.push(`<p>${escapeModalText(line)}</p>`)
  })

  if (listItems.length > 0) {
    parts.push(`
      <ul class="c-modal__review-list">
        ${listItems.map((item) => `<li>${escapeModalText(item)}</li>`).join("")}
      </ul>
    `)
  }

  return parts.join("")
}

function showAppModal(options = {}) {
  const title = options.title || (options.showCancel === false ? "Notice" : "Confirm action")
  const message = options.message || "Review this action before continuing."
  const confirmLabel = options.confirmLabel || (options.showCancel === false ? "OK" : "Continue")
  const cancelLabel = options.cancelLabel || "Cancel"
  const showCancel = options.showCancel !== false
  const id = `app-modal-${++appModalId}`

  return new Promise((resolve) => {
    const backdrop = document.createElement("div")
    let closed = false
    backdrop.className = "c-modal-backdrop"
    backdrop.innerHTML = `
      <section class="c-modal" role="dialog" aria-modal="true" aria-labelledby="${id}-title">
        <header class="c-modal__header">
          <div>
            <p class="c-eyebrow">${escapeModalText(options.eyebrow || (showCancel ? "Confirm action" : "Message"))}</p>
            <h2 id="${id}-title" class="c-modal__title">${escapeModalText(title)}</h2>
          </div>
          <button type="button" class="c-icon-button c-modal__close" data-app-modal-close aria-label="Close">&times;</button>
        </header>
        <div class="c-modal__body">
          ${modalBodyHtml(message)}
        </div>
        <footer class="c-modal__footer">
          ${showCancel ? `<button type="button" class="btn btn-secondary" data-app-modal-cancel>${escapeModalText(cancelLabel)}</button>` : ""}
          <button type="button" class="btn btn-primary" data-app-modal-confirm>${escapeModalText(confirmLabel)}</button>
        </footer>
      </section>
    `

    const finish = (value) => {
      if (closed) return
      closed = true
      document.removeEventListener("keydown", escapeHandler)
      backdrop.remove()
      document.body.classList.remove("is-modal-open")
      resolve(value)
    }

    const escapeHandler = (event) => {
      if (event.key === "Escape") finish(!showCancel)
    }

    backdrop.querySelector("[data-app-modal-confirm]")?.addEventListener("click", () => finish(true))
    backdrop.querySelector("[data-app-modal-cancel]")?.addEventListener("click", () => finish(false))
    backdrop.querySelector("[data-app-modal-close]")?.addEventListener("click", () => finish(!showCancel))
    backdrop.addEventListener("click", (event) => {
      if (event.target === backdrop) finish(!showCancel)
    })
    document.addEventListener("keydown", escapeHandler)

    document.body.appendChild(backdrop)
    document.body.classList.add("is-modal-open")

    const initialFocus = showCancel
      ? backdrop.querySelector("[data-app-modal-cancel]")
      : backdrop.querySelector("[data-app-modal-confirm]")
    initialFocus?.focus()
  })
}

function appModalConfirm(options) {
  const config = typeof options === "string" ? { message: options } : (options || {})
  return showAppModal({ ...config, showCancel: true })
}

function appModalAlert(options) {
  const config = typeof options === "string" ? { message: options } : (options || {})
  return showAppModal({ confirmLabel: "OK", ...config, showCancel: false })
}

function confirmWithAppModal(message, options = {}) {
  if (window.AppModal && typeof window.AppModal.confirm === "function") {
    return window.AppModal.confirm({ message, ...options })
  }

  return Promise.resolve(window.confirm(message))
}

function alertWithAppModal(message, options = {}) {
  if (message && typeof message === "object" && !Array.isArray(message)) {
    return appModalAlert(message)
  }

  if (window.AppModal && typeof window.AppModal.alert === "function") {
    return window.AppModal.alert({ message, ...options })
  }

  window.alert(message)
  return Promise.resolve(true)
}

function installTurboModalConfirm() {
  if (!window.Turbo || typeof window.Turbo.setConfirmMethod !== "function") return
  if (appModalConfirmInstalled) return

  window.Turbo.setConfirmMethod((message) => {
    return appModalConfirm({
      title: "Confirm action",
      message,
      confirmLabel: "Continue",
      cancelLabel: "Cancel"
    })
  })
  appModalConfirmInstalled = true
}

function initTurboFalseConfirmFallback() {
  if (turboFalseConfirmFallbackInstalled) return
  turboFalseConfirmFallbackInstalled = true

  document.addEventListener("click", async (event) => {
    const trigger = event.target.closest && event.target.closest("a[data-turbo-confirm][data-turbo='false']")
    if (!trigger) return
    if (trigger.dataset.appModalConfirmed === "true") {
      delete trigger.dataset.appModalConfirmed
      return
    }

    event.preventDefault()
    const confirmed = await confirmWithAppModal(trigger.dataset.turboConfirm || "Review this action before continuing.")
    if (!confirmed) return

    trigger.dataset.appModalConfirmed = "true"
    trigger.click()
  }, true)
}

function initInlineModals() {
  if (!inlineModalEventsInstalled) {
    inlineModalEventsInstalled = true

    document.addEventListener("click", (event) => {
      const trigger = event.target?.closest?.("[data-open-modal]")
      if (trigger) {
        const modal = document.getElementById(trigger.dataset.openModal || "")
        if (!modal) return

        event.preventDefault()
        modal.classList.remove("hidden")
        document.body.classList.add("is-modal-open")
        modal.querySelector("[data-close-modal], button, input, select, textarea, a")?.focus()
        return
      }

      const closeButton = event.target?.closest?.("[data-close-modal]")
      const modal = event.target?.closest?.("[data-inline-modal]")
      if (closeButton && modal) {
        event.preventDefault()
        modal.classList.add("hidden")
        document.body.classList.remove("is-modal-open")
        return
      }

      if (event.target?.matches?.("[data-inline-modal]")) {
        event.target.classList.add("hidden")
        document.body.classList.remove("is-modal-open")
      }
    })

    document.addEventListener("keydown", (event) => {
      if (event.key !== "Escape") return

      const modal = document.querySelector("[data-inline-modal]:not(.hidden)")
      if (!modal) return

      modal.classList.add("hidden")
      document.body.classList.remove("is-modal-open")
    })
  }

  document.querySelectorAll("[data-inline-modal]").forEach((modal) => {
    if (modal.dataset.inlineModalInitialized === "true") return
    modal.dataset.inlineModalInitialized = "true"
  })
}

function initProgramSetupSortables() {
  document.querySelectorAll("[data-program-setup-sortable='true']").forEach((list) => {
    if (list.dataset.sortableInitialized === "true") return

    const reorderUrl = list.dataset.reorderUrl
    if (!reorderUrl) return

    list.dataset.sortableInitialized = "true"
    const statusTargetId = list.dataset.reorderStatusTarget
    const statusTarget = statusTargetId ? document.getElementById(statusTargetId) : null
    const defaultStatus = statusTarget?.textContent || ""
    const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content || ""

    const setStatus = (message, state = "idle") => {
      if (!statusTarget) return
      statusTarget.textContent = message
      statusTarget.dataset.reorderState = state
    }

    const syncPositionInputs = () => {
      Array.from(list.querySelectorAll("[data-sortable-item]")).forEach((item, index) => {
        const positionInput = item.querySelector("input[name$='[position]']")
        if (!positionInput) return

        positionInput.value = String((index + 1) * 10)
      })
    }

    new Sortable(list, {
      animation: 150,
      draggable: "[data-sortable-item]",
      handle: "[data-drag-handle]",
      ghostClass: "is-dragging",
      onEnd: async () => {
        const orderedIds = Array.from(list.querySelectorAll("[data-sortable-item]"))
          .map((item) => item.dataset.sortableId)
          .filter(Boolean)

        if (orderedIds.length === 0) return

        setStatus("Saving order...", "saving")

        try {
          const response = await fetch(reorderUrl, {
            method: "PATCH",
            credentials: "same-origin",
            headers: {
              "Accept": "application/json",
              "Content-Type": "application/json",
              "X-CSRF-Token": csrfToken(),
              "X-Requested-With": "XMLHttpRequest"
            },
            body: JSON.stringify({ ordered_ids: orderedIds })
          })

          if (!response.ok) throw new Error(`Reorder failed with ${response.status}`)

          syncPositionInputs()
          setStatus("Order saved.", "saved")
          window.setTimeout(() => setStatus(defaultStatus, "idle"), 2500)
        } catch (error) {
          console.error("[Program setup] reorder failed", error)
          setStatus("Order could not be saved. Refresh and try again.", "error")
        }
      }
    })
  })
}

window.AppModal = {
  show: showAppModal,
  confirm: appModalConfirm,
  alert: appModalAlert
}

installTurboModalConfirm()

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

function initDismissibleFlashes() {
  const dismissFlash = (flash) => {
    if (!flash || flash.dataset.dismissibleFlashDismissed === "true") return

    flash.dataset.dismissibleFlashDismissed = "true"
    flash.classList.add("is-dismissing")
    window.setTimeout(() => flash.remove(), 340)
  }

  const scheduleFlashDismissal = (flash) => {
    if (!flash || flash.dataset.dismissibleFlashAutoDismiss === "true") return

    flash.dataset.dismissibleFlashAutoDismiss = "true"
    window.setTimeout(() => dismissFlash(flash), 5000)
  }

  document.querySelectorAll("[data-dismissible-flash]").forEach(scheduleFlashDismissal)

  if (dismissibleFlashesInstalled) return
  dismissibleFlashesInstalled = true

  document.addEventListener("click", (event) => {
    const target = event.target
    const targetElement = target instanceof Element ? target : (target instanceof Node ? target.parentElement : null)
    const trigger = targetElement?.closest("[data-dismiss-flash]")
    if (!trigger) return

    event.preventDefault()
    const flash = trigger.closest("[data-dismissible-flash]")
    dismissFlash(flash)
  })

  if ("MutationObserver" in window) {
    const observer = new MutationObserver((mutations) => {
      mutations.forEach((mutation) => {
        mutation.addedNodes.forEach((node) => {
          if (!(node instanceof Element)) return

          if (node.matches("[data-dismissible-flash]")) {
            scheduleFlashDismissal(node)
          }

          node.querySelectorAll?.("[data-dismissible-flash]").forEach(scheduleFlashDismissal)
        })
      })
    })

    observer.observe(document.body, { childList: true, subtree: true })
  }
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
    alertWithAppModal("Text-to-speech is not available in this browser.", {
      title: "Read Aloud unavailable"
    })
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
    alertWithAppModal("No readable content was found on this page.", {
      title: "Nothing to read"
    })
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
    syncSurveyBranchingForForm(form)
  })
}

function syncSurveyBranchingForForm(form) {
  if (!(form instanceof HTMLFormElement)) return

  const parents = form.querySelectorAll('[data-branch-parent="true"][data-branch-parent-id]')
  if (!parents.length) return

  parents.forEach((parent) => {
    const parentId = parent.dataset.branchParentId
    const targetValue = (parent.dataset.branchTargetValue || "").trim().toLowerCase()
    if (!parentId || !targetValue) return

    const inputName = `answers[${parentId}]`
    const checked = form.querySelector(`input[name="${inputName}"]:checked`)
    const select = form.querySelector(`select[name="${inputName}"]`)
    const currentValue = (checked ? checked.value : (select ? select.value : "")).trim().toLowerCase()

    setSurveyBranchChildrenVisibility(form, parentId, currentValue === targetValue)
  })
}

function setSurveyBranchChildrenVisibility(form, parentId, shouldShow) {
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

function installSurveyBranchingEventFallback() {
  if (surveyBranchingEventsInstalled) return
  surveyBranchingEventsInstalled = true

  const scheduleSync = (event) => {
    const target = event.target
    if (!(target instanceof Element)) return

    const form = target.closest(".survey-form")
    if (!(form instanceof HTMLFormElement)) return

    window.requestAnimationFrame(() => syncSurveyBranchingForForm(form))
  }

  document.addEventListener("change", scheduleSync, true)
  document.addEventListener("click", scheduleSync, true)
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

    wrappers.forEach((wrapper) => {
      const qid = wrapper.dataset.otherForQuestionId
      if (!qid) return

      const radios = form.querySelectorAll(`input[type="radio"][name$="[${qid}]"]`)
      radios.forEach((radio) => {
        radio.addEventListener("change", () => syncOtherChoiceInputsForQuestion(form, qid))
      })

      const select = form.querySelector(`select[name$="[${qid}]"]`)
      if (select) {
        select.addEventListener("change", () => syncOtherChoiceInputsForQuestion(form, qid))
      }

      syncOtherChoiceInputsForQuestion(form, qid)
    })
  })
}

function syncOtherChoiceInputsForForm(form) {
  const questionIds = new Set()
  form.querySelectorAll("[data-other-input-wrapper][data-other-for-question-id]").forEach((wrapper) => {
    if (wrapper.dataset.otherForQuestionId) questionIds.add(wrapper.dataset.otherForQuestionId)
  })

  questionIds.forEach((questionId) => syncOtherChoiceInputsForQuestion(form, questionId))
}

function syncOtherChoiceInputsForQuestion(form, questionId) {
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

function showSurveySubmitModal({ canSaveProgress = true, editingSubmittedResponse = false } = {}) {
  const id = `survey-submit-modal-${++appModalId}`
  const title = editingSubmittedResponse ? "Ready to update this submission?" : "Ready to submit?"
  const bodyMessage = editingSubmittedResponse
    ? "This will update the submitted survey response. You can still go back and keep editing before saving these changes."
    : (canSaveProgress
        ? "Submit only when your answers are final. You can also save progress and come back later."
        : "Submit only when your answers are final.")
  const confirmLabel = editingSubmittedResponse ? "Update submission" : "Submit"

  return new Promise((resolve) => {
    const backdrop = document.createElement("div")
    let closed = false
    backdrop.className = "c-modal-backdrop"
    backdrop.innerHTML = `
      <section class="c-modal" role="dialog" aria-modal="true" aria-labelledby="${id}-title">
        <header class="c-modal__header">
          <div>
            <p class="c-eyebrow">Survey submission</p>
            <h2 id="${id}-title" class="c-modal__title">${title}</h2>
          </div>
          <button type="button" class="c-icon-button c-modal__close" data-survey-submit-choice="edit" aria-label="Close">&times;</button>
        </header>
        <div class="c-modal__body">
          <p>${bodyMessage}</p>
        </div>
        <footer class="c-modal__footer">
          <button type="button" class="btn btn-secondary" data-survey-submit-choice="edit">Go back to editing</button>
          ${canSaveProgress ? '<button type="button" class="btn btn-secondary" data-survey-submit-choice="save">Save progress</button>' : ""}
          <button type="button" class="btn btn-primary" data-survey-submit-choice="submit">${confirmLabel}</button>
        </footer>
      </section>
    `

    const finish = (choice) => {
      if (closed) return
      closed = true
      document.removeEventListener("keydown", escapeHandler)
      backdrop.remove()
      document.body.classList.remove("is-modal-open")
      resolve(choice)
    }

    const escapeHandler = (event) => {
      if (event.key === "Escape") finish("edit")
    }

    backdrop.querySelectorAll("[data-survey-submit-choice]").forEach((button) => {
      button.addEventListener("click", () => finish(button.dataset.surveySubmitChoice || "edit"))
    })
    backdrop.addEventListener("click", (event) => {
      if (event.target === backdrop) finish("edit")
    })
    document.addEventListener("keydown", escapeHandler)

    document.body.appendChild(backdrop)
    document.body.classList.add("is-modal-open")
    backdrop.querySelector('[data-survey-submit-choice="edit"]')?.focus()
  })
}

function initSurveyReflectionVisibility() {
  const forms = document.querySelectorAll(".survey-form")
  if (!forms.length) return

  forms.forEach((form) => {
    if (form.dataset.reflectionVisibilityInitialized === "true") return
    form.dataset.reflectionVisibilityInitialized = "true"

    const reflectionCards = form.querySelectorAll('[data-reflection-question="true"][data-reflection-source-id]')
    if (!reflectionCards.length) return

    const sourceIds = new Set(Array.from(reflectionCards).map((card) => card.dataset.reflectionSourceId).filter(Boolean))

    const sourceValue = (sourceId) => {
      const radio = form.querySelector(`input[type="radio"][name$="[${sourceId}]"]:checked`)
      if (radio) return radio.value.toString().trim()

      const select = form.querySelector(`select[name$="[${sourceId}]"]`)
      if (select) return select.value.toString().trim()

      const input = form.querySelector(`input[name$="[${sourceId}]"], textarea[name$="[${sourceId}]"]`)
      return input ? input.value.toString().trim() : ""
    }

    const setReflectionVisibility = (sourceId) => {
      const sourceCard = form.querySelector(`[data-question-id="${sourceId}"]`)
      const sourceHidden = sourceCard && (sourceCard.classList.contains("hidden") || sourceCard.getAttribute("aria-hidden") === "true")
      const show = sourceValue(sourceId) !== "" && !sourceHidden
      form.querySelectorAll(`[data-reflection-question="true"][data-reflection-source-id="${sourceId}"]`).forEach((card) => {
        card.classList.toggle("hidden", !show)
        card.setAttribute("aria-hidden", show ? "false" : "true")

        card.querySelectorAll("input, select, textarea, button").forEach((el) => {
          if (el.getAttribute("type") === "hidden") return
          el.disabled = !show
        })
      })
    }

    sourceIds.forEach((sourceId) => {
      const controls = form.querySelectorAll(`input[name$="[${sourceId}]"], select[name$="[${sourceId}]"], textarea[name$="[${sourceId}]"]`)
      controls.forEach((control) => {
        control.addEventListener("input", () => setReflectionVisibility(sourceId))
        control.addEventListener("change", () => setReflectionVisibility(sourceId))
      })
      setReflectionVisibility(sourceId)
    })
  })
}

function initStudentSurveyFormAutosave() {
  const forms = document.querySelectorAll('.survey-form[data-survey-student-form="true"]')
  if (!forms.length) return

  forms.forEach((form) => {
    if (form.dataset.studentSurveyAutosaveInitialized === "true") return
    form.dataset.studentSurveyAutosaveInitialized = "true"

    const saveUrl = form.dataset.surveyAutosaveUrl
    const autosaveEnabled = form.dataset.surveyAutosaveEnabled === "true" && !!saveUrl
    const statusTargets = Array.from(form.querySelectorAll("[data-survey-autosave-status]"))
    let timer = null
    let inFlight = false
    let inFlightPromise = null
    let pending = false
    let dirty = false
    let submitting = false
    let autosaveController = null
    let modalOpen = false
    let lastAnswerSnapshot = null
    let lastSavedSnapshot = null
    let lastSavedAt = null
    let answerWatchInterval = null
    let pendingImmediate = false
    const textAutosaveDelay = 3500
    const answerWatchDelay = 5000

    const autosaveTime = () => {
      return new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" })
    }

    const autosaveImmediatelyForControl = (control) => {
      if (!(control instanceof HTMLInputElement || control instanceof HTMLSelectElement || control instanceof HTMLTextAreaElement)) return false
      if (control instanceof HTMLSelectElement) return true
      if (control instanceof HTMLTextAreaElement) return false

      return ["radio", "checkbox"].includes(control.type)
    }

    const answerSnapshot = () => {
      return Array.from(new FormData(form).entries())
        .filter(([name]) => name.startsWith("answers[") || name.startsWith("other_answers["))
        .sort(([nameA, valueA], [nameB, valueB]) => `${nameA}:${valueA}`.localeCompare(`${nameB}:${valueB}`))
        .map(([name, value]) => `${name}=${value}`)
        .join("&")
    }

    const setStatus = (message, options = {}) => {
      const state = options.state || "ready"
      const title = options.title || message
      const detail = options.detail || ""
      const statusText = options.statusText || (detail ? `${title}: ${detail}` : message)

      statusTargets.forEach((target) => {
        target.textContent = statusText
        target.dataset.autosaveState = state
      })
    }

    const clearTimer = () => {
      if (timer) {
        window.clearTimeout(timer)
        timer = null
      }
    }

    const abortAutosave = () => {
      clearTimer()
      if (autosaveController) {
        autosaveController.abort()
        autosaveController = null
      }
    }

    const autosaveMessage = async (title, message, options = {}) => {
      setStatus(title, {
        state: options.state || "saved",
        title,
        detail: message
      })

      if (!options.modal) return
      if (modalOpen) return
      modalOpen = true
      try {
        await alertWithAppModal(message, { title, confirmLabel: "OK" })
      } finally {
        modalOpen = false
      }
    }

    const markSnapshotSaved = (snapshot, savedAt) => {
      lastSavedSnapshot = snapshot
      lastSavedAt = savedAt
      lastAnswerSnapshot = snapshot
    }

    const currentAnswersAlreadySaved = () => {
      return !!lastSavedAt && answerSnapshot() === lastSavedSnapshot
    }

    const showAlreadySavedProgress = async () => {
      dirty = false
      pending = false
      pendingImmediate = false
      clearTimer()
      await autosaveMessage("Progress saved", `Already saved at ${lastSavedAt}. You can keep working.`, {
        state: "saved"
      })
      return true
    }

    const performAutosave = async (options = {}) => {
      clearTimer()
      if (!autosaveEnabled || submitting) return false
      if (!dirty && !pending && !options.force) {
        if (options.successTitle || options.successMessage) {
          await autosaveMessage(options.successTitle || "Progress saved", options.successMessage || `Saved at ${autosaveTime()}.`, {
            state: "saved",
            modal: options.modal
          })
        }
        return true
      }
      if (inFlight) {
        pending = true
        return inFlightPromise || false
      }

      inFlight = true
      pending = false
      pendingImmediate = false

      inFlightPromise = (async () => {
        const submittedSnapshot = answerSnapshot()
        setStatus("Autosaving...", {
          state: "saving",
          title: "Autosaving",
          detail: `Saving your latest answers at ${autosaveTime()}.`
        })
        autosaveController = new AbortController()

        const formData = new FormData(form)
        formData.append("autosave", "1")

        try {
          const response = await fetch(saveUrl, {
            method: "POST",
            body: formData,
            signal: autosaveController.signal,
            headers: {
              "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
              "X-Requested-With": "XMLHttpRequest",
              Accept: "application/json"
            },
            credentials: "same-origin"
          })

          const payload = await response.json().catch(() => ({}))
          if (!response.ok || payload.saved === false) {
            throw new Error(payload.message || "Autosave failed.")
          }

          dirty = pending
          const savedAt = autosaveTime()
          markSnapshotSaved(submittedSnapshot, savedAt)
          const successMessage = typeof options.successMessage === "function" ? options.successMessage(savedAt) : (options.successMessage || `Saved at ${savedAt}.`)
          await autosaveMessage(options.successTitle || "Progress auto-saved", successMessage, {
            state: "saved",
            modal: options.modal
          })
          return true
        } catch (error) {
          if (error.name === "AbortError") return false

          await autosaveMessage("Autosave failed", error.message || "Your progress could not be auto-saved. Use Save Progress before leaving.", {
            state: "error",
            modal: true
          })
          return false
        } finally {
          inFlight = false
          autosaveController = null
          inFlightPromise = null

          if (pending && !submitting) {
            queueAutosave({ immediate: pendingImmediate })
          }
        }
      })()

      return inFlightPromise
    }

    const queueAutosave = ({ immediate = true } = {}) => {
      if (!autosaveEnabled || submitting) return
      pending = true
      dirty = true
      pendingImmediate = pendingImmediate || immediate
      lastAnswerSnapshot = answerSnapshot()
      setStatus("Unsaved changes", {
        state: "dirty",
        title: "Unsaved changes",
        detail: immediate ? `Saving this answer now at ${autosaveTime()}.` : "Autosave will run shortly."
      })
      clearTimer()
      if (inFlight) return
      timer = window.setTimeout(performAutosave, immediate ? 0 : textAutosaveDelay)
    }

    const flushAutosaveBeforeLeaving = async () => {
      if (!autosaveEnabled || submitting || (!dirty && !pending)) return true
      return await performAutosave()
    }

    const saveProgressNow = async (options = {}) => {
      if (inFlight) {
        setStatus("Saving progress", {
          state: "saving",
          title: "Saving progress",
          detail: "Waiting for the current autosave to finish."
        })
        await inFlightPromise
      }

      if (currentAnswersAlreadySaved()) {
        return showAlreadySavedProgress()
      }

      let saved = await performAutosave({
        force: true,
        ...options
      })

      let attempts = 0
      while (saved && (dirty || pending) && attempts < 2) {
        attempts += 1
        saved = await performAutosave({
          force: true,
          ...options
        })
      }

      if (saved) {
        dirty = false
        pending = false
        pendingImmediate = false
        lastAnswerSnapshot = lastSavedSnapshot || answerSnapshot()
        clearTimer()
      }
      return saved
    }

    const saveProgressInPlace = async () => {
      return saveProgressNow({
        successTitle: "Progress saved",
        successMessage: (savedAt) => `Saved at ${savedAt}. You can keep working.`
      })
    }

    const saveProgressAndExit = async (href) => {
      const saved = await saveProgressNow({
        successTitle: "Progress saved",
        successMessage: "Your answers were saved before leaving this survey."
      })

      if (saved && href) {
        submitting = true
        abortAutosave()
        window.location.assign(href)
      }
    }

    const beaconAutosaveBeforeLeaving = () => {
      if (!autosaveEnabled || submitting || (!dirty && !pending)) return
      clearTimer()

      const formData = new FormData(form)
      formData.append("autosave", "1")
      formData.append("beacon", "1")

      if (navigator.sendBeacon && navigator.sendBeacon(saveUrl, formData)) {
        dirty = false
        pending = false
        return
      }

      fetch(saveUrl, {
        method: "POST",
        body: formData,
        keepalive: true,
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
          "X-Requested-With": "XMLHttpRequest",
          Accept: "application/json"
        },
        credentials: "same-origin"
      }).catch(() => {})
    }

    const handleAnswerChange = (event) => {
      queueAutosave({ immediate: autosaveImmediatelyForControl(event.target) })
    }
    form.addEventListener("input", handleAnswerChange, true)
    form.addEventListener("change", handleAnswerChange, true)
    lastAnswerSnapshot = answerSnapshot()
    answerWatchInterval = window.setInterval(() => {
      if (!autosaveEnabled || submitting || inFlight) return

      const currentSnapshot = answerSnapshot()
      if (currentSnapshot === lastAnswerSnapshot) return

      queueAutosave({ immediate: false })
    }, answerWatchDelay)

    window.addEventListener("pagehide", beaconAutosaveBeforeLeaving)
    window.addEventListener("beforeunload", beaconAutosaveBeforeLeaving)
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") beaconAutosaveBeforeLeaving()
    })
    document.addEventListener("turbo:before-cache", beaconAutosaveBeforeLeaving)
    document.addEventListener("turbo:before-cache", () => {
      if (answerWatchInterval) {
        window.clearInterval(answerWatchInterval)
        answerWatchInterval = null
      }
    })

    form.querySelectorAll("[data-survey-save-stay]").forEach((button) => {
      button.addEventListener("click", async (event) => {
        event.preventDefault()
        await saveProgressInPlace()
      })
    })

    form.querySelectorAll("[data-survey-save-exit], [data-survey-autosave-cancel]").forEach((control) => {
      control.addEventListener("click", async (event) => {
        event.preventDefault()
        if (!autosaveEnabled) {
          const fallbackHref = control.href || control.value
          if (fallbackHref) window.location.assign(fallbackHref)
          return
        }

        const href = control.href || control.value
        await saveProgressAndExit(href)
      })
    })

    if (form.dataset.surveySharedSubmit === "true") return

    form.addEventListener("submit", async (event) => {
      if (form.dataset.surveySubmitConfirmed === "true") {
        delete form.dataset.surveySubmitConfirmed
        submitting = true
        abortAutosave()
        return
      }

      const submitter = event.submitter
      if (submitter?.hasAttribute("data-survey-save-stay") || submitter?.hasAttribute("data-survey-save-exit")) {
        return
      }

      if (submitting) return

      event.preventDefault()
      const choice = await showSurveySubmitModal({
        canSaveProgress: autosaveEnabled,
        editingSubmittedResponse: form.dataset.surveyEditingSubmittedResponse === "true"
      })
      if (choice === "save" && autosaveEnabled) {
        await saveProgressInPlace()
        return
      }
      if (choice !== "submit") return

      submitting = true
      abortAutosave()
      form.dataset.surveySubmitConfirmed = "true"
      form.submit()
    })
  })
}

function initPreviewSurveyForms() {
  document.querySelectorAll("form[data-preview-survey-form='true']").forEach((form) => {
    if (form.dataset.surveySharedSubmit === "true") return
    if (form.dataset.previewSurveyFormInitialized === "true") return
    form.dataset.previewSurveyFormInitialized = "true"

    form.addEventListener("submit", async (event) => {
      event.preventDefault()
      syncSurveyBranchingForForm(form)
      window.TamuCatSurveyBehavior?.syncForm?.(form)
      initOtherChoiceInputs()
      syncOtherChoiceInputsForForm(form)

      const validation = await validatePreviewSurveyForm(form)
      if (!validation.valid) {
        await alertWithAppModal("Review the highlighted required or invalid answers before submitting the preview.", {
          title: "Preview needs attention",
          confirmLabel: "OK"
        })
        validation.firstError?.scrollIntoView({ behavior: "smooth", block: "center" })
        validation.firstError?.querySelector("input:not([disabled]), select:not([disabled]), textarea:not([disabled])")?.focus({ preventScroll: true })
        return
      }

      const choice = await showSurveySubmitModal({ canSaveProgress: false })
      if (choice !== "submit") return

      await alertWithAppModal("This was only a preview. No responses were saved.", {
        title: "Preview submitted",
        confirmLabel: "OK"
      })
    })
  })
}

async function validatePreviewSurveyForm(form) {
  const cards = Array.from(form.querySelectorAll("[data-question-id]"))
  const errorCards = []
  const checkEvidenceAccess = form.dataset.previewSurveyForm === "true"

  cards.forEach((card) => clearPreviewValidationError(card))

  for (const card of cards) {
    if (isPreviewCardHidden(card)) continue

    const required = card.dataset.previewRequired === "true"
    const missing = required && previewQuestionIsBlank(card)
    if (missing) {
      addPreviewValidationError(card, "This question is required.")
      errorCards.push(card)
      continue
    }

    const evidenceError = await previewEvidenceError(card, { checkAccess: checkEvidenceAccess })
    if (evidenceError) {
      addPreviewValidationError(card, evidenceError)
      errorCards.push(card)
      continue
    }

    const integerError = previewIntegerError(card)
    if (integerError) {
      addPreviewValidationError(card, integerError)
      errorCards.push(card)
      continue
    }

    const otherError = previewOtherTextError(card)
    if (otherError) {
      addPreviewValidationError(card, otherError)
      errorCards.push(card)
    }
  }

  return {
    valid: errorCards.length === 0,
    firstError: errorCards[0] || null
  }
}

function isPreviewCardHidden(card) {
  return card.hidden || card.classList.contains("hidden") || card.getAttribute("aria-hidden") === "true"
}

function previewEditableControls(card) {
  return Array.from(card.querySelectorAll("input, select, textarea")).filter((control) => {
    if (control.disabled) return false
    const type = (control.getAttribute("type") || "").toLowerCase()
    if (type === "hidden") return false
    return (control.getAttribute("name") || "").startsWith("answers[")
  })
}

function previewQuestionIsBlank(card) {
  const controls = previewEditableControls(card)
  if (!controls.length) return false

  const radios = controls.filter((control) => control instanceof HTMLInputElement && control.type === "radio")
  if (radios.length) return !radios.some((radio) => radio.checked)

  return controls.every((control) => (control.value || "").trim() === "")
}

function previewIntegerError(card) {
  const input = previewEditableControls(card).find((control) => control instanceof HTMLInputElement && control.type === "number")
  if (!input) return null

  const value = (input.value || "").trim()
  if (value === "") return null
  if (!/^\d+$/.test(value)) return "Enter a whole number"

  const intValue = Number.parseInt(value, 10)
  const min = input.getAttribute("min")
  const max = input.getAttribute("max")

  if (min !== null && min !== "" && intValue < Number.parseInt(min, 10)) return `Enter a number of at least ${min}`
  if (max !== null && max !== "" && intValue > Number.parseInt(max, 10)) return `Enter a number no higher than ${max}`

  return null
}

async function previewEvidenceError(card, { checkAccess = false } = {}) {
  if (card.dataset.questionType !== "evidence") return null

  const input = previewEditableControls(card).find((control) => {
    return control instanceof HTMLInputElement || control instanceof HTMLTextAreaElement
  })
  if (!input) return null

  const value = (input.value || "").trim()
  if (value === "") return null

  if (!/^https:\/\/sites\.google\.com(?:\/|$)\S*/i.test(value)) {
    return "Use a published Google Sites link that starts with https://sites.google.com/."
  }

  if (!checkAccess) return null

  try {
    const response = await fetch(`/evidence/check_access?url=${encodeURIComponent(value)}`, {
      headers: {
        Accept: "application/json",
        "X-Requested-With": "XMLHttpRequest"
      },
      credentials: "same-origin"
    })
    const payload = await response.json().catch(() => ({}))

    if (!response.ok || payload.ok === false || payload.accessible === false) {
      return 'This evidence link could not be verified. In Google Sites, set sharing to "Anyone with the link can view," publish again, then try again.'
    }
  } catch (_error) {
    return "This evidence link could not be verified. Check the link and try again."
  }

  return null
}

function previewOtherTextError(card) {
  const visibleOtherWrappers = Array.from(card.querySelectorAll("[data-other-input-wrapper]")).filter((wrapper) => {
    return !wrapper.classList.contains("hidden") && wrapper.getAttribute("aria-hidden") !== "true"
  })

  const missingOther = visibleOtherWrappers.some((wrapper) => {
    const input = wrapper.querySelector("input:not([disabled]), textarea:not([disabled])")
    return input && (input.value || "").trim() === ""
  })

  return missingOther ? "Please describe the Other response" : null
}

function addPreviewValidationError(card, message) {
  card.classList.add("c-question-card--error")
  const error = document.createElement("div")
  error.className = "c-help u-danger"
  error.dataset.previewValidationError = "true"
  error.textContent = message
  card.appendChild(error)
}

function clearPreviewValidationError(card) {
  card.classList.remove("c-question-card--error")
  card.querySelectorAll("[data-preview-validation-error='true']").forEach((error) => error.remove())
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

    input.addEventListener("change", async () => {
      const nextChecked = input.checked
      const prevChecked = input.dataset.togglePrev === "true"

      const confirmOn = input.getAttribute("data-confirm-on")
      const confirmOff = input.getAttribute("data-confirm-off")
      const message = nextChecked ? confirmOn : confirmOff

      if (message) {
        const confirmed = await confirmWithAppModal(message)
        if (!confirmed) {
          // Revert to previous value and do not submit.
          input.checked = prevChecked
          input.setAttribute("aria-checked", prevChecked ? "true" : "false")
          return
        }
      }

      if (message && input.checked !== nextChecked) {
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
  if (!widgets.length && comboboxEventsInstalled) return

  widgets.forEach((widget) => {
    const input = comboboxInputFor(widget)
    if (input) input.setAttribute("aria-expanded", "false")
    comboboxFilter(widget)
  })

  if (comboboxEventsInstalled) return
  comboboxEventsInstalled = true

  document.addEventListener("focusin", (event) => {
    const input = event.target.closest?.('[data-combobox-input="true"]')
    const widget = input?.closest?.('[data-combobox="true"]')
    if (!widget) return

    comboboxFilter(widget)
    comboboxSetOpen(widget, true)
  })

  document.addEventListener("input", (event) => {
    const input = event.target.closest?.('[data-combobox-input="true"]')
    const widget = input?.closest?.('[data-combobox="true"]')
    if (!widget) return

    const hidden = comboboxHiddenFor(widget)
    if (hidden) hidden.value = ""
    comboboxFilter(widget)
    comboboxSetOpen(widget, true)
  })

  document.addEventListener("keydown", (event) => {
    const input = event.target.closest?.('[data-combobox-input="true"]')
    const widget = input?.closest?.('[data-combobox="true"]')
    if (!widget || event.key !== "Escape") return

    comboboxSetOpen(widget, false)
  })

  document.addEventListener("click", (event) => {
    const option = event.target.closest?.('[data-combobox-option="true"]')
    if (option) {
      const widget = option.closest('[data-combobox="true"]')
      if (widget) comboboxSelectOption(widget, option)
      return
    }

    const input = event.target.closest?.('[data-combobox-input="true"]')
    const activeWidget = input?.closest?.('[data-combobox="true"]')
    if (activeWidget) {
      comboboxFilter(activeWidget)
      comboboxSetOpen(activeWidget, true)
      return
    }

    document.querySelectorAll('[data-combobox="true"]').forEach((widget) => {
      if (!widget.contains(event.target)) comboboxSetOpen(widget, false)
    })
  })
}

function comboboxInputFor(widget) {
  return widget?.querySelector?.('[data-combobox-input="true"]') || null
}

function comboboxHiddenFor(widget) {
  return widget?.querySelector?.('[data-combobox-value="true"]') || null
}

function comboboxMenuFor(widget) {
  return widget?.querySelector?.('[data-combobox-menu="true"]') || null
}

function comboboxSetOpen(widget, open) {
  const input = comboboxInputFor(widget)
  const menu = comboboxMenuFor(widget)
  if (!input || !menu) return

  menu.classList.toggle("hidden", !open)
  menu.classList.toggle("u-hidden", !open)
  input.setAttribute("aria-expanded", open ? "true" : "false")
}

function comboboxFilter(widget) {
  const input = comboboxInputFor(widget)
  const empty = widget?.querySelector?.('[data-combobox-empty="true"]')
  if (!input) return

  const q = (input.value || "").trim().toLowerCase()
  let visible = 0

  widget.querySelectorAll('[data-combobox-option="true"]').forEach((btn) => {
    const haystack = (btn.dataset.comboboxOptionSearch || "").toLowerCase()
    const match = q === "" || haystack.includes(q)
    btn.hidden = !match
    if (match) visible += 1
  })

  if (empty) empty.hidden = !(q !== "" && visible === 0)
}

function comboboxSelectOption(widget, option) {
  const input = comboboxInputFor(widget)
  const hidden = comboboxHiddenFor(widget)
  if (!input || !hidden || !option) return

  hidden.value = option.dataset.comboboxOptionValue || ""
  input.value = option.dataset.comboboxOptionLabel || ""
  comboboxSetOpen(widget, false)
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
// Hover dropdown support
// -----------------------------

function initHoverDropdownDetails() {
  document.querySelectorAll("details.u-hover-dropdown, .u-hover-dropdown[data-click-pins='true']").forEach((dropdown) => {
    if (dropdown.dataset.hoverDropdownInitialized === "true") return
    dropdown.dataset.hoverDropdownInitialized = "true"

    let closeTimer = null
    let pinnedOpen = false
    const isDetails = dropdown.tagName.toLowerCase() === "details"
    const clickPins = dropdown.dataset.clickPins === "true"
    const trigger = isDetails ? dropdown.querySelector("summary") : dropdown.querySelector("button")

    const setOpen = (open) => {
      if (isDetails) dropdown.open = open
      dropdown.classList.toggle("is-pinned", open && pinnedOpen)
      trigger?.setAttribute("aria-expanded", open ? "true" : "false")
    }

    const openNow = () => {
      if (closeTimer) {
        window.clearTimeout(closeTimer)
        closeTimer = null
      }
      if (isDetails) setOpen(true)
    }

    const closeSoon = () => {
      if (pinnedOpen) return
      if (closeTimer) window.clearTimeout(closeTimer)
      closeTimer = window.setTimeout(() => {
        if (pinnedOpen) return
        if (dropdown.matches(":focus-within")) return
        setOpen(false)
      }, 75)
    }

    dropdown.addEventListener("mouseenter", openNow)
    dropdown.addEventListener("mouseleave", closeSoon)
    dropdown.addEventListener("focusin", openNow)
    dropdown.addEventListener("focusout", closeSoon)

    if (clickPins && trigger) {
      trigger.addEventListener("click", (event) => {
        event.preventDefault()
        event.stopPropagation()

        pinnedOpen = !pinnedOpen
        setOpen(pinnedOpen)
      })

      document.addEventListener("click", (event) => {
        if (!pinnedOpen) return
        if (dropdown.contains(event.target)) return

        pinnedOpen = false
        setOpen(false)
      })

      dropdown.addEventListener("keydown", (event) => {
        if (event.key !== "Escape") return

        pinnedOpen = false
        setOpen(false)
        trigger.focus()
      })
    }

    if (isDetails) {
      // If a click toggles [open] off while still hovered/focused, immediately restore it.
      dropdown.addEventListener("toggle", () => {
        if (dropdown.open) return
        if (pinnedOpen) {
          setOpen(true)
          return
        }
        if (dropdown.matches(":hover") || dropdown.matches(":focus-within")) {
          setOpen(true)
        }
      })
    }
  })
}

function initMobileNavigation() {
  const mobileViewport = () => window.matchMedia("(max-width: 768px)").matches

  const toggleForDrawer = (drawer) => {
    if (!drawer?.id) return null
    return Array.from(document.querySelectorAll("[data-mobile-nav-toggle]"))
      .find((button) => button.getAttribute("aria-controls") === drawer.id)
  }

  const drawerForToggle = (button) => {
    const drawerId = button.getAttribute("aria-controls")
    return drawerId ? document.getElementById(drawerId) : null
  }

  const updateBodyLock = () => {
    const anyOpen = !!document.querySelector("[data-mobile-nav-drawer].is-open")
    document.body?.classList.toggle("is-mobile-nav-open", anyOpen)
  }

  const setDrawerOpen = (drawer, open, options = {}) => {
    if (!drawer) return

    const button = toggleForDrawer(drawer)
    const backdrop = drawer.closest(".c-app-header")?.querySelector("[data-mobile-nav-backdrop]")

    drawer.classList.toggle("is-open", open)
    if (mobileViewport()) {
      drawer.setAttribute("aria-hidden", open ? "false" : "true")
    } else {
      drawer.removeAttribute("aria-hidden")
    }

    button?.setAttribute("aria-expanded", open ? "true" : "false")
    backdrop?.classList.toggle("is-open", open)
    if (backdrop) backdrop.hidden = !open
    updateBodyLock()

    if (open && options.focusDrawer) {
      window.requestAnimationFrame(() => {
        drawer.querySelector("[data-mobile-nav-close], .c-nav-link, button, a")?.focus()
      })
    }

    if (!open && options.focusToggle) {
      button?.focus()
    }
  }

  const closeAllDrawers = (options = {}) => {
    document.querySelectorAll("[data-mobile-nav-drawer]").forEach((drawer) => {
      setDrawerOpen(drawer, false, options)
    })
  }

  const syncDrawerState = () => {
    document.querySelectorAll("[data-mobile-nav-drawer]").forEach((drawer) => {
      const open = drawer.classList.contains("is-open")
      const button = toggleForDrawer(drawer)
      const backdrop = drawer.closest(".c-app-header")?.querySelector("[data-mobile-nav-backdrop]")

      if (mobileViewport()) {
        drawer.setAttribute("aria-hidden", open ? "false" : "true")
      } else {
        drawer.classList.remove("is-open")
        drawer.removeAttribute("aria-hidden")
      }

      button?.setAttribute("aria-expanded", open && mobileViewport() ? "true" : "false")
      backdrop?.classList.toggle("is-open", open && mobileViewport())
      if (backdrop) backdrop.hidden = !(open && mobileViewport())
    })
    updateBodyLock()
  }

  syncDrawerState()

  if (window.__mobileNavigationInitialized === true) return
  window.__mobileNavigationInitialized = true

  document.addEventListener("click", (event) => {
    const target = event.target instanceof Element ? event.target : event.target?.parentElement
    if (!target) return

    const toggle = target.closest("[data-mobile-nav-toggle]")
    if (toggle) {
      event.preventDefault()
      const drawer = drawerForToggle(toggle)
      if (!drawer) return

      const open = !drawer.classList.contains("is-open")
      closeAllDrawers()
      setDrawerOpen(drawer, open, { focusDrawer: open })
      return
    }

    const closeButton = target.closest("[data-mobile-nav-close]")
    if (closeButton) {
      event.preventDefault()
      setDrawerOpen(closeButton.closest("[data-mobile-nav-drawer]"), false, { focusToggle: true })
      return
    }

    if (target.closest("[data-mobile-nav-backdrop]")) {
      event.preventDefault()
      closeAllDrawers()
      return
    }

    const drawerLink = target.closest("[data-mobile-nav-drawer] .c-nav-link, [data-mobile-nav-drawer] .c-profile-action")
    if (drawerLink) {
      setDrawerOpen(drawerLink.closest("[data-mobile-nav-drawer]"), false)
    }
  })

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return

    const openDrawer = document.querySelector("[data-mobile-nav-drawer].is-open")
    if (openDrawer) {
      event.preventDefault()
      setDrawerOpen(openDrawer, false, { focusToggle: true })
    }
  })

  window.addEventListener("resize", syncDrawerState)
  document.addEventListener("turbo:before-cache", () => closeAllDrawers())
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
// Google Translate widget
// -----------------------------

const GOOGLE_TRANSLATE_ELEMENT_ID = "google_translate_element"
const GOOGLE_TRANSLATE_SCRIPT_ID = "google-translate-script"
const GOOGLE_TRANSLATE_SCRIPT_URL = "https://translate.google.com/translate_a/element.js?cb=googleTranslateElementInit"

let googleTranslateBarObserver = null
let googleTranslateBarInterval = null
let googleTranslateRetryCount = 0
let googleTranslateStateEventsInstalled = false

function googleTranslateContainer() {
  return document.getElementById(GOOGLE_TRANSLATE_ELEMENT_ID)
}

function googleTranslatePanel() {
  return document.getElementById("gt-panel")
}

function googleTranslatePanelVisible() {
  const panel = googleTranslatePanel()
  return !!panel && window.getComputedStyle(panel).display !== "none"
}

function googleTranslateCombo() {
  const container = googleTranslateContainer()
  return container?.querySelector("select.goog-te-combo") || document.querySelector("select.goog-te-combo")
}

function googleTranslateStatusElement() {
  return document.querySelector("[data-gt-visible-status]")
}

function googleTranslateLanguageSelect() {
  return document.querySelector("[data-gt-language-select]")
}

function googleTranslateWidgetReady() {
  const container = googleTranslateContainer()
  if (!container) return false

  const interactive = container.querySelector("select.goog-te-combo, .goog-te-gadget, .goog-te-gadget-simple")
  if (!interactive) return false

  const visibleText = (container.textContent || "").trim().toLowerCase()
  return !visibleText.includes("loading translation options")
}

function setGoogleTranslateStatus(message, { retry = false } = {}) {
  const status = googleTranslateStatusElement()
  if (!status) return

  const normalizedMessage = message.toString()
  const retryState = retry ? "true" : "false"
  if (status.dataset.gtStatusMessage === normalizedMessage && status.dataset.gtStatusRetry === retryState) return

  status.dataset.gtStatusMessage = normalizedMessage
  status.dataset.gtStatusRetry = retryState
  status.innerHTML = `
    <span>${normalizedMessage}</span>
    ${retry ? '<button type="button" class="btn btn-secondary btn-sm" data-gt-retry>Retry</button>' : ""}
  `

  bindGoogleTranslateRetry()
}

function bindGoogleTranslateRetry() {
  const retryButton = googleTranslateStatusElement()?.querySelector("[data-gt-retry]")
  if (!retryButton || retryButton.dataset.gtRetryBound === "true") return
  retryButton.dataset.gtRetryBound = "true"

  retryButton.addEventListener("click", () => {
    googleTranslateRetryCount = 0
    const language = googleTranslateLanguageSelect()?.value || selectedGoogleTranslateLanguage()
    if (language) {
      applyGoogleTranslateLanguage(language)
      return
    }

    setGoogleTranslateStatus("Preparing translation options...")
    ensureGoogleTranslateScript({ force: true })
    scheduleGoogleTranslateAdoption({ reapply: true, maxAttempts: 32 })
  })
}

function writeGoogleTranslateCookie(language) {
  const normalizedLanguage = language.toString().trim()
  const maxAge = normalizedLanguage ? 31_536_000 : 0
  const value = normalizedLanguage ? `/en/${normalizedLanguage}` : ""
  const baseCookie = `googtrans=${value};path=/;max-age=${maxAge};SameSite=Lax`
  document.cookie = baseCookie

  const hostname = window.location.hostname
  if (hostname && hostname.includes(".") && hostname !== "localhost") {
    document.cookie = `${baseCookie};domain=.${hostname}`
  }
}

function bindGoogleTranslateLanguageSelect() {
  const select = googleTranslateLanguageSelect()
  if (!select) return

  syncVisibleGoogleLanguageOptions()

  const selected = selectedGoogleTranslateLanguage()
  if (selected && Array.from(select.options).some((option) => option.value === selected)) {
    select.value = selected
    setGoogleTranslateStatus("Translation active.")
  }

  if (select.dataset.gtLanguageBound === "true") return
  select.dataset.gtLanguageBound = "true"

  select.addEventListener("change", () => {
    const language = select.value.toString()
    applyGoogleTranslateLanguage(language)
  })
}

function syncVisibleGoogleLanguageOptions() {
  const appSelect = googleTranslateLanguageSelect()
  const googleSelect = googleTranslateCombo()
  if (!appSelect || !(googleSelect instanceof HTMLSelectElement)) return false

  const googleOptions = Array.from(googleSelect.options)
    .map((option) => ({
      value: option.value.toString().trim(),
      label: option.textContent.toString().trim()
    }))
    .filter((option) => option.value && option.label)

  if (!googleOptions.length) return false

  const signature = googleOptions.map((option) => `${option.value}:${option.label}`).join("|")
  const selected = appSelect.value || selectedGoogleTranslateLanguage()
  if (appSelect.dataset.gtOptionsSignature === signature) {
    if (selected && googleOptions.some((option) => option.value === selected)) appSelect.value = selected
    return true
  }

  const englishOption = document.createElement("option")
  englishOption.value = ""
  englishOption.textContent = "English"

  appSelect.innerHTML = ""
  appSelect.appendChild(englishOption)

  googleOptions.forEach((googleOption) => {
    const option = document.createElement("option")
    option.value = googleOption.value
    option.textContent = googleOption.label
    appSelect.appendChild(option)
  })

  appSelect.dataset.gtOptionsSignature = signature

  if (selected && googleOptions.some((option) => option.value === selected)) {
    appSelect.value = selected
  }

  return true
}

function readGoogleTranslateCookie() {
  const match = document.cookie.match(/(?:^|;\s*)googtrans=([^;]+)/)
  return match ? decodeURIComponent(match[1]) : ""
}

function selectedGoogleTranslateLanguage() {
  const cookie = readGoogleTranslateCookie()
  if (!cookie || cookie === "/auto/en" || cookie === "/en/en") return ""
  return cookie.split("/").filter(Boolean).pop() || ""
}

function pageTranslatedByGoogle() {
  return document.documentElement.classList.contains("translated-ltr") ||
    document.documentElement.classList.contains("translated-rtl") ||
    document.body?.classList.contains("translated-ltr") ||
    document.body?.classList.contains("translated-rtl")
}

function syncGoogleTranslateVisibleState() {
  const appSelect = googleTranslateLanguageSelect()
  if (!appSelect) return

  const language = selectedGoogleTranslateLanguage()
  if (!language && !pageTranslatedByGoogle()) {
    if (appSelect.value !== "") appSelect.value = ""
    setGoogleTranslateStatus("Select a language.")
    return
  }

  if (!language) return

  if (Array.from(appSelect.options).some((option) => option.value === language)) {
    appSelect.value = language
  }
  setGoogleTranslateStatus("Translation active.")
}

function bindGoogleTranslateToggle() {
  const button = document.getElementById("gt-toggle")
  const panel = googleTranslatePanel()
  if (!button || !panel) return
  if (button.dataset.gtToggleBound === "true") return
  button.dataset.gtToggleBound = "true"

  const mountWhenVisible = () => {
    window.requestAnimationFrame(() => {
      if (!googleTranslatePanelVisible()) return
      ensureGoogleTranslateScript()
      mountGoogleTranslateWidget()
      scheduleGoogleTranslateAdoption({ reapply: true, maxAttempts: 32 })
    })
  }

  button.addEventListener("click", () => {
    const isHidden = panel.style.display === "none" || window.getComputedStyle(panel).display === "none"
    panel.style.display = isHidden ? "block" : "none"
    panel.setAttribute("aria-hidden", isHidden ? "false" : "true")
    button.setAttribute("aria-expanded", isHidden ? "true" : "false")

    if (isHidden) mountWhenVisible()
  })

  const wrapper = button.closest(".translate-nav")
  wrapper?.addEventListener("mouseenter", mountWhenVisible)
  wrapper?.addEventListener("focusin", mountWhenVisible)
}

function installGoogleTranslateCallback() {
  window.googleTranslateElementInit = () => {
    mountGoogleTranslateWidget()
    scheduleGoogleTranslateAdoption({ reapply: true })
  }
}

function ensureGoogleTranslateScript(options = {}) {
  installGoogleTranslateCallback()

  if (window.google?.translate?.TranslateElement) {
    mountGoogleTranslateWidget({ force: options.force })
    return
  }

  const existingScript = document.getElementById(GOOGLE_TRANSLATE_SCRIPT_ID)
  if (existingScript && !options.force) return
  if (existingScript && options.force) existingScript.remove()

  const script = document.createElement("script")
  script.id = GOOGLE_TRANSLATE_SCRIPT_ID
  script.type = "text/javascript"
  script.src = options.force ? `${GOOGLE_TRANSLATE_SCRIPT_URL}&retry=${Date.now()}` : GOOGLE_TRANSLATE_SCRIPT_URL
  script.async = true
  script.onload = () => {
    script.dataset.loaded = "true"
    window.setTimeout(() => {
      mountGoogleTranslateWidget()
      scheduleGoogleTranslateAdoption({ reapply: true })
    }, 0)
  }
  script.onerror = () => {
    setGoogleTranslateStatus("Translation options could not load.", { retry: true })
  }
  document.head.appendChild(script)
}

function mountGoogleTranslateWidget(options = {}) {
  const container = googleTranslateContainer()
  if (!container) return
  if (googleTranslateWidgetReady() && !options.force) return
  if (!window.google?.translate?.TranslateElement) return

  try {
    container.innerHTML = ""
    new window.google.translate.TranslateElement(
      { pageLanguage: "en", autoDisplay: false },
      GOOGLE_TRANSLATE_ELEMENT_ID
    )
  } catch (error) {
    console.warn("[Google Translate] widget mount failed", error)
  }
}

function bindGoogleTranslateCombo(select) {
  if (!select || select.dataset.gtChangeBound === "true") return
  select.dataset.gtChangeBound = "true"

  select.addEventListener("change", () => {
    if (select.dataset.gtProgrammatic === "true") return

    window.setTimeout(() => {
      const cookie = readGoogleTranslateCookie()
      const language = cookie || select.value
      if (!language) return

      // Google usually translates immediately. The reload is only a one-time
      // fallback for cases where the cookie is set but Turbo content did not update.
      const key = `gt_reload_after_choice:${language}`
      if (window.sessionStorage.getItem(key) === "true") return
      window.sessionStorage.setItem(key, "true")
      window.sessionStorage.removeItem("gt_turbo_reloaded")
      window.location.reload()
    }, 700)
  })
}

function adoptGoogleTranslateWidget() {
  const container = googleTranslateContainer()
  if (!container) return false

  const select = googleTranslateCombo()
  if (!select) return googleTranslateWidgetReady()

  select.style.width = "100%"
  select.style.height = "2.25rem"
  select.style.display = ""

  const gadget = select.closest(".goog-te-gadget")
  if (gadget) {
    Array.from(gadget.children).forEach((child) => {
      if (child !== select && !child.contains(select)) child.style.display = "none"
    })
  }

  bindGoogleTranslateCombo(select)
  syncVisibleGoogleLanguageOptions()
  syncGoogleTranslateVisibleState()
  return true
}

function scheduleGoogleTranslateAdoption(options = {}) {
  const maxAttempts = options.maxAttempts || 24
  const delay = options.delay || 250
  let attempts = 0

  const tick = () => {
    attempts += 1
    const ready = adoptGoogleTranslateWidget()
    if (ready) {
      if (options.reapply) reapplyGoogleTranslateLanguage()
      return
    }
    if (attempts < maxAttempts) window.setTimeout(tick, delay)
    else handleGoogleTranslateTimeout(options)
  }

  tick()
}

function handleGoogleTranslateTimeout(options = {}) {
  if (googleTranslateWidgetReady()) return

  if (googleTranslateRetryCount < 1) {
    googleTranslateRetryCount += 1
    ensureGoogleTranslateScript({ force: true })
    scheduleGoogleTranslateAdoption({ reapply: options.reapply, maxAttempts: 20 })
    return
  }

  setGoogleTranslateStatus("Google Translate is taking longer than expected to load.", { retry: true })
}

function triggerGoogleTranslateCombo(language) {
  const select = googleTranslateCombo()
  if (!(select instanceof HTMLSelectElement)) return false

  try {
    select.dataset.gtProgrammatic = "true"
    select.value = language
    if (language && select.value !== language) return false
    select.dispatchEvent(new Event("change", { bubbles: true }))
    return true
  } catch (error) {
    console.warn("[Google Translate] language apply failed", error)
    return false
  } finally {
    window.setTimeout(() => {
      delete select.dataset.gtProgrammatic
    }, 0)
  }
}

function applyGoogleTranslateLanguage(language, options = {}) {
  const normalizedLanguage = language.toString().trim()
  const attempts = options.attempts || 0

  writeGoogleTranslateCookie(normalizedLanguage)

  if (!normalizedLanguage) {
    setGoogleTranslateStatus("Returning to English...")
    window.setTimeout(() => window.location.reload(), 150)
    return
  }

  setGoogleTranslateStatus(attempts === 0 ? "Applying translation..." : "Still applying translation...")
  ensureGoogleTranslateScript()
  mountGoogleTranslateWidget()
  adoptGoogleTranslateWidget()

  if (triggerGoogleTranslateCombo(normalizedLanguage)) {
    const appSelect = googleTranslateLanguageSelect()
    if (appSelect) appSelect.value = normalizedLanguage
    setGoogleTranslateStatus("Translation active.")
    return
  }

  if (attempts < 32) {
    window.setTimeout(() => applyGoogleTranslateLanguage(normalizedLanguage, { attempts: attempts + 1 }), 250)
    return
  }

  setGoogleTranslateStatus("Google Translate could not apply the selected language. Try again.", { retry: true })
}

function reapplyGoogleTranslateLanguage() {
  const language = selectedGoogleTranslateLanguage()
  if (!language) return

  triggerGoogleTranslateCombo(language)
}

function restoreGoogleTranslateAfterLoad() {
  if (!selectedGoogleTranslateLanguage() && !pageTranslatedByGoogle()) return

  const restoreTranslation = () => {
    ensureGoogleTranslateScript()
    mountGoogleTranslateWidget()
    scheduleGoogleTranslateAdoption({ reapply: true })
  }

  if (document.readyState === "complete") {
    window.setTimeout(restoreTranslation, 0)
    return
  }

  window.addEventListener("load", () => window.setTimeout(restoreTranslation, 0), { once: true })
}

// When the user clicks "Show original" in Google's bar, Google removes the
// translated-ltr/rtl class but leaves the googtrans cookie intact. Without this
// watcher, opening the panel again would read the stale cookie and re-translate.
function watchForGoogleTranslateShowOriginal() {
  const target = document.documentElement
  if (target.dataset.gtShowOriginalWatcher === "true") return
  target.dataset.gtShowOriginalWatcher = "true"

  new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      if (mutation.type !== "attributes" || mutation.attributeName !== "class") continue
      const wasTranslated =
        mutation.oldValue?.includes("translated-ltr") || mutation.oldValue?.includes("translated-rtl")
      const isNowEnglish =
        !target.classList.contains("translated-ltr") && !target.classList.contains("translated-rtl")
      if (wasTranslated && isNowEnglish) {
        writeGoogleTranslateCookie("")
        const appSelect = googleTranslateLanguageSelect()
        if (appSelect) appSelect.value = ""
        setGoogleTranslateStatus("Select a language.")
      }
    }
  }).observe(target, { attributes: true, attributeOldValue: true, attributeFilter: ["class"] })
}

function initGoogleTranslateWidget() {
  if (!googleTranslateContainer()) return

  bindGoogleTranslateToggle()
  bindGoogleTranslateLanguageSelect()
  syncGoogleTranslateVisibleState()
  watchForGoogleTranslateShowOriginal()

  restoreGoogleTranslateAfterLoad()
}

function adjustForGoogleTranslateBar() {
  syncGoogleTranslateVisibleState()

  try {
    const frame = document.querySelector('iframe[id^="goog-gt-"]') || document.querySelector("iframe.goog-te-banner-frame")
    if (frame && frame.clientHeight) {
      const height = `${frame.clientHeight}px`
      document.body.style.setProperty("margin-top", height, "important")
      document.documentElement.style.setProperty("margin-top", height, "important")
      document.body.style.setProperty("transform", "none", "important")
    } else if (frame) {
      document.body.style.setProperty("margin-top", "40px", "important")
      document.documentElement.style.setProperty("margin-top", "40px", "important")
      document.body.style.setProperty("transform", "none", "important")
    } else {
      document.body.style.removeProperty("margin-top")
      document.documentElement.style.removeProperty("margin-top")
      document.body.style.removeProperty("transform")
    }
  } catch {
    // Google injects cross-browser iframe variations; failing to offset should never break the app.
  }
}

function initGoogleTranslateBarOffset() {
  adjustForGoogleTranslateBar()

  if (!googleTranslateBarObserver) {
    googleTranslateBarObserver = new MutationObserver(adjustForGoogleTranslateBar)
    googleTranslateBarObserver.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: [ "class" ]
    })
  }

  if (googleTranslateBarInterval) window.clearInterval(googleTranslateBarInterval)

  let checks = 0
  googleTranslateBarInterval = window.setInterval(() => {
    adjustForGoogleTranslateBar()
    checks += 1
    if (checks > 20) {
      window.clearInterval(googleTranslateBarInterval)
      googleTranslateBarInterval = null
    }
  }, 300)

  if (!googleTranslateStateEventsInstalled) {
    googleTranslateStateEventsInstalled = true
    window.addEventListener("focus", syncGoogleTranslateVisibleState)
    document.addEventListener("visibilitychange", syncGoogleTranslateVisibleState)
  }
}

// -----------------------------
// Hook into Turbo / DOM load
// -----------------------------

function runFeatureInitializer(name, initializer) {
  try {
    initializer()
  } catch (error) {
    console.error(`[Application] ${name} failed`, error)
  }
}

function initAccessibilityFeatures() {
  [
    ["mobile navigation", initMobileNavigation],
    ["survey branching fallback", installSurveyBranchingEventFallback],
    ["modal confirmations", installTurboModalConfirm],
    ["turbo false confirmations", initTurboFalseConfirmFallback],
    ["inline modals", initInlineModals],
    ["program setup sortables", initProgramSetupSortables],
    ["dismissible flashes", initDismissibleFlashes],
    ["high contrast toggle", initHighContrastToggle],
    ["text-to-speech toggle", initTTSToggle],
    ["survey branching", initSurveyBranching],
    ["survey reflection visibility", initSurveyReflectionVisibility],
    ["survey keyboard shortcuts", initSurveyQuestionKeyboardShortcuts],
    ["other choice inputs", initOtherChoiceInputs],
    ["student survey autosave", initStudentSurveyFormAutosave],
    ["preview survey forms", initPreviewSurveyForms],
    ["toggle switches", initToggleSwitches],
    ["comboboxes", initComboboxes],
    ["impersonation read-only UI", initImpersonationReadOnlyUI],
    ["disable unchanged submits", initDisableSubmitIfUnchanged],
    ["hover dropdowns", initHoverDropdownDetails],
    ["markdown previews", initServerMarkdownPreviews],
    ["Google Translate widget", initGoogleTranslateWidget],
    ["Google Translate offset", initGoogleTranslateBarOffset]
  ].forEach(([name, initializer]) => runFeatureInitializer(name, initializer))
}

initMobileNavigation()
installSurveyBranchingEventFallback()
initDismissibleFlashes()
document.addEventListener("turbo:load", initAccessibilityFeatures)

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initAccessibilityFeatures, { once: true })
} else {
  window.queueMicrotask(initAccessibilityFeatures)
}

console.debug("[Application] JS bootstrap loaded (once)")
