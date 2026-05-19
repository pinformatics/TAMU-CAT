import { Controller } from "@hotwired/stimulus"

// Adds common markdown keyboard shortcuts for textarea-style editors.
export default class extends Controller {
  static targets = ["previewInput", "previewOutput"]

  static values = {
    previewUrl: String,
    wrapperClass: String,
    minHeadingLevel: Number,
    emptyHtml: String
  }

  connect() {
    this.handleShortcut = this.handleShortcut.bind(this)
    this.queuePreviewRender = this.queuePreviewRender.bind(this)
    this.renderPreview = this.renderPreview.bind(this)
    this.abortController = null
    this.renderTimeout = null
    this.requestSequence = 0

    this.element.addEventListener("keydown", this.handleShortcut)

    if (this.hasPreviewInputTarget) {
      this.previewInputTarget.addEventListener("input", this.queuePreviewRender)
      this.renderPreview()
    }
  }

  disconnect() {
    this.element.removeEventListener("keydown", this.handleShortcut)

    if (this.hasPreviewInputTarget) {
      this.previewInputTarget.removeEventListener("input", this.queuePreviewRender)
    }

    if (this.renderTimeout) clearTimeout(this.renderTimeout)
    if (this.abortController) this.abortController.abort()
  }

  handleShortcut(event) {
    if ((!event.ctrlKey && !event.metaKey) || event.altKey) return
    if (event.defaultPrevented) return

    const target = event.target
    if (!this.supportsTextSelection(target)) return

    const key = event.key.toLowerCase()

    if (key === "b") {
      event.preventDefault()
      this.wrapSelection(target, "**", "**")
      return
    }

    if (key === "i") {
      event.preventDefault()
      this.wrapSelection(target, "*", "*")
      return
    }

    if (key === "k") {
      event.preventDefault()
      this.wrapLink(target)
      return
    }

    if (key === "8" && event.shiftKey) {
      event.preventDefault()
      this.toggleListPrefix(target, "- ")
      return
    }

    if (key === "7" && event.shiftKey) {
      event.preventDefault()
      this.toggleOrderedList(target)
    }
  }

  supportsTextSelection(target) {
    if (!(target instanceof HTMLTextAreaElement)) return false
    return !target.disabled && !target.readOnly
  }

  wrapSelection(target, openTag, closeTag) {
    const start = target.selectionStart
    const end = target.selectionEnd
    const selected = target.value.slice(start, end)
    const fallback = openTag + "text" + closeTag
    const replacement = selected.length ? `${openTag}${selected}${closeTag}` : fallback

    target.setRangeText(replacement, start, end, "select")

    if (!selected.length) {
      const cursorStart = start + openTag.length
      const cursorEnd = cursorStart + 4
      target.setSelectionRange(cursorStart, cursorEnd)
    }

    this.dispatchInput(target)
  }

  wrapLink(target) {
    const start = target.selectionStart
    const end = target.selectionEnd
    const selected = target.value.slice(start, end) || "link text"
    const replacement = `[${selected}](https://example.com)`

    target.setRangeText(replacement, start, end, "end")

    const urlStart = start + replacement.indexOf("https://example.com")
    const urlEnd = urlStart + "https://example.com".length
    target.setSelectionRange(urlStart, urlEnd)

    this.dispatchInput(target)
  }

  toggleListPrefix(target, prefix) {
    const { start, end, lines, rangeStart, rangeEnd } = this.selectedLines(target)
    const hasPrefix = lines.every((line) => line.startsWith(prefix))

    const updated = lines.map((line) => {
      if (hasPrefix) return line.replace(prefix, "")
      if (!line.trim().length) return line
      return `${prefix}${line}`
    })

    target.setRangeText(updated.join("\n"), start, end, "select")
    target.setSelectionRange(rangeStart, rangeEnd)
    this.dispatchInput(target)
  }

  toggleOrderedList(target) {
    const { start, end, lines, rangeStart, rangeEnd } = this.selectedLines(target)
    const numberedPattern = /^\d+\.\s/
    const hasNumbers = lines.every((line) => numberedPattern.test(line) || !line.trim().length)

    const updated = lines.map((line, idx) => {
      if (!line.trim().length) return line
      if (hasNumbers) return line.replace(numberedPattern, "")
      return `${idx + 1}. ${line}`
    })

    target.setRangeText(updated.join("\n"), start, end, "select")
    target.setSelectionRange(rangeStart, rangeEnd)
    this.dispatchInput(target)
  }

  selectedLines(target) {
    const raw = target.value
    const selStart = target.selectionStart
    const selEnd = target.selectionEnd
    const start = raw.lastIndexOf("\n", selStart - 1) + 1
    const lineEndIndex = raw.indexOf("\n", selEnd)
    const end = lineEndIndex === -1 ? raw.length : lineEndIndex
    const block = raw.slice(start, end)

    return {
      start,
      end,
      lines: block.split("\n"),
      rangeStart: start,
      rangeEnd: start + block.length
    }
  }

  dispatchInput(target) {
    target.dispatchEvent(new Event("input", { bubbles: true }))
  }

  queuePreviewRender() {
    if (this.renderTimeout) clearTimeout(this.renderTimeout)
    this.renderTimeout = setTimeout(this.renderPreview, 180)
  }

  async renderPreview() {
    if (!this.hasPreviewInputTarget || !this.hasPreviewOutputTarget || !this.hasPreviewUrlValue) return

    const text = this.previewInputTarget.value || ""
    if (!text.trim().length) {
      this.previewOutputTarget.innerHTML = this.emptyHtmlValue || ""
      return
    }

    if (this.abortController) this.abortController.abort()
    this.abortController = new AbortController()
    const requestId = ++this.requestSequence

    try {
      const response = await fetch(this.previewUrlValue, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({
          text,
          wrapper_class: this.wrapperClassValue || "c-rich-text",
          min_heading_level: this.hasMinHeadingLevelValue ? this.minHeadingLevelValue : 3
        }),
        signal: this.abortController.signal
      })

      if (!response.ok) throw new Error(`Markdown preview failed with ${response.status}`)

      const payload = await response.json()
      if (requestId !== this.requestSequence) return

      this.previewOutputTarget.innerHTML = payload.html || ""
    } catch (error) {
      if (error.name === "AbortError") return

      this.previewOutputTarget.innerHTML = '<div class="c-markdown-preview__error">Preview unavailable right now.</div>'
    }
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
