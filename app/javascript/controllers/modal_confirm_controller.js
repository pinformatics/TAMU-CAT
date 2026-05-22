import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    title: String,
    message: String,
    sections: Array,
    confirmLabel: String,
    cancelLabel: String
  }

  connect() {
    this.confirmed = false
  }

  submit(event) {
    if (this.confirmed) {
      this.confirmed = false
      return
    }

    event.preventDefault()
    event.stopImmediatePropagation()
    this.open()
  }

  open() {
    this.close()

    this.modal = document.createElement("div")
    this.modal.className = "c-modal-backdrop"
    this.modal.innerHTML = this.template()
    document.body.appendChild(this.modal)

    this.modal.querySelectorAll("[data-modal-confirm-cancel]").forEach((button) => {
      button.addEventListener("click", () => this.close())
    })
    this.modal.querySelector("[data-modal-confirm-submit]").addEventListener("click", () => this.confirm())
    this.modal.addEventListener("click", (event) => {
      if (event.target === this.modal) this.close()
    })

    this.escapeHandler = (event) => {
      if (event.key === "Escape") this.close()
    }
    document.addEventListener("keydown", this.escapeHandler)

    this.modal.querySelector("[data-modal-confirm-cancel]").focus()
    document.body.classList.add("is-modal-open")
  }

  confirm() {
    this.confirmed = true
    this.close()
    this.element.requestSubmit()
  }

  close() {
    if (this.escapeHandler) {
      document.removeEventListener("keydown", this.escapeHandler)
      this.escapeHandler = null
    }
    if (this.modal) {
      this.modal.remove()
      this.modal = null
    }
    document.body.classList.remove("is-modal-open")
  }

  template() {
    const title = this.titleValue || "Confirm action"
    const confirmLabel = this.confirmLabelValue || "Continue"
    const cancelLabel = this.cancelLabelValue || "Cancel"

    return `
      <section class="c-modal" role="dialog" aria-modal="true" aria-labelledby="modal-confirm-title">
        <header class="c-modal__header">
          <div>
            <p class="c-eyebrow">${this.escape(this.eyebrowText())}</p>
            <h2 id="modal-confirm-title" class="c-modal__title">${this.escape(title)}</h2>
          </div>
          <button type="button" class="c-icon-button c-modal__close" data-modal-confirm-cancel aria-label="Close">&times;</button>
        </header>
        <div class="c-modal__body">
          ${this.bodyHtml()}
        </div>
        <footer class="c-modal__footer">
          <button type="button" class="btn btn-secondary" data-modal-confirm-cancel>${this.escape(cancelLabel)}</button>
          <button type="button" class="btn btn-primary" data-modal-confirm-submit>${this.escape(confirmLabel)}</button>
        </footer>
      </section>
    `
  }

  bodyHtml() {
    if (this.sections().length > 0) {
      return `${this.paragraphsHtml()}${this.sectionsHtml()}`
    }

    return this.messageHtml()
  }

  messageHtml() {
    const lines = (this.messageValue || "Are you sure you want to continue?")
      .split(/\r?\n/)
      .map((line) => line.trim())

    const bodyLines = lines.filter((line, index) => {
      if (line === "") return false
      if (index === 0 && line.replace(/\?$/, "") === (this.titleValue || "").replace(/\?$/, "")) return false
      return true
    })

    const parts = []
    let listItems = []

    bodyLines.forEach((line) => {
      if (line.startsWith("- ")) {
        listItems.push(line.slice(2))
        return
      }

      if (listItems.length > 0) {
        parts.push(this.listHtml(listItems))
        listItems = []
      }
      parts.push(`<p>${this.escape(line)}</p>`)
    })

    if (listItems.length > 0) parts.push(this.listHtml(listItems))
    return parts.join("")
  }

  paragraphsHtml() {
    return this.bodyLines()
      .filter((line) => !line.startsWith("- "))
      .map((line) => `<p>${this.escape(line)}</p>`)
      .join("")
  }

  sectionsHtml() {
    return `
      <div class="c-modal__sections">
        <div class="c-modal__issue-summary">
          <strong>${this.escape(this.totalItemCountLabel())}</strong>
          <span>Review all issues below before approving.</span>
        </div>
        ${this.sections().map((section) => this.sectionHtml(section)).join("")}
      </div>
    `
  }

  sectionHtml(section) {
    const title = section.title || "Review items"
    const items = Array.isArray(section.items) ? section.items : []
    const count = Number.isInteger(section.count) ? section.count : items.length
    const open = section.collapsed ? "" : " open"
    const overflow = section.overflow_message || section.overflowMessage

    return `
      <details class="c-modal__section"${open}>
        <summary class="c-modal__section-summary">
          <span>${this.escape(title)}</span>
          <span class="c-modal__section-meta">${this.escape(this.itemCountLabel(count))}</span>
        </summary>
        <div class="c-modal__section-body">
          ${this.listHtml(items)}
          ${overflow ? `<p class="c-modal__section-overflow">${this.escape(overflow)}</p>` : ""}
        </div>
      </details>
    `
  }

  listHtml(items) {
    return `
      <ul class="c-modal__review-list">
        ${items.map((item) => `<li>${this.escape(item)}</li>`).join("")}
      </ul>
    `
  }

  bodyLines() {
    const title = this.titleValue || ""

    return (this.messageValue || "Are you sure you want to continue?")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line, index) => {
        if (line === "") return false
        if (index === 0 && line.replace(/\?$/, "") === title.replace(/\?$/, "")) return false
        return true
      })
  }

  sections() {
    if (!this.hasSectionsValue || !Array.isArray(this.sectionsValue)) return []

    return this.sectionsValue.filter((section) => {
      return section && Array.isArray(section.items) && section.items.length > 0
    })
  }

  itemCountLabel(count) {
    return `${count} ${count === 1 ? "item" : "items"}`
  }

  totalItemCountLabel() {
    const total = this.sections().reduce((sum, section) => {
      const count = Number.isInteger(section.count) ? section.count : (Array.isArray(section.items) ? section.items.length : 0)
      return sum + count
    }, 0)

    return `${total} total ${total === 1 ? "issue" : "issues"}`
  }

  eyebrowText() {
    return this.sections().length > 0 || (this.messageValue || "").includes("- ") ? "Review required" : "Confirm action"
  }

  escape(value) {
    const element = document.createElement("span")
    element.textContent = value == null ? "" : String(value)
    return element.innerHTML
  }
}
