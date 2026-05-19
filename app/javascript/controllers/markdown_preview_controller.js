import { Controller } from "@hotwired/stimulus"

// Server-backed markdown preview that uses the same Rails renderer as the rest
// of the app, instead of duplicating markdown parsing logic in the browser.
export default class extends Controller {
  static targets = ["input", "output"]

  static values = {
    previewUrl: String,
    wrapperClass: String,
    minHeadingLevel: Number,
    emptyHtml: String
  }

  connect() {
    this.abortController = null
    this.renderTimeout = null
    this.requestSequence = 0

    this.queueRender = this.queueRender.bind(this)
    this.renderPreview = this.renderPreview.bind(this)

    if (this.hasInputTarget) {
      this.inputTarget.addEventListener("input", this.queueRender)
    }

    this.renderPreview()
  }

  disconnect() {
    if (this.hasInputTarget) {
      this.inputTarget.removeEventListener("input", this.queueRender)
    }

    if (this.renderTimeout) clearTimeout(this.renderTimeout)
    if (this.abortController) this.abortController.abort()
  }

  queueRender() {
    if (this.renderTimeout) clearTimeout(this.renderTimeout)
    this.renderTimeout = setTimeout(this.renderPreview, 180)
  }

  async renderPreview() {
    if (!this.hasInputTarget || !this.hasOutputTarget || !this.hasPreviewUrlValue) return

    const text = this.inputTarget.value || ""
    if (!text.trim().length) {
      this.outputTarget.innerHTML = this.emptyHtmlValue || ""
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
          "Accept": "application/json",
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

      if (!response.ok) throw new Error(`Markdown preview failed: ${response.status}`)

      const payload = await response.json()
      if (requestId !== this.requestSequence) return

      this.outputTarget.innerHTML = payload.html || ""
    } catch (error) {
      if (error.name === "AbortError") return

      this.outputTarget.innerHTML = '<div class="c-markdown-preview__error">Preview unavailable right now.</div>'
    }
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
