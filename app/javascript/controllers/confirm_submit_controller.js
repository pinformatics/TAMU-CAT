import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    message: String
  }

  connect() {
    this.confirmed = false
  }

  async confirm(event) {
    if (this.confirmed) {
      this.confirmed = false
      return
    }

    const message = this.messageValue || "Are you sure you want to continue?"
    event.preventDefault()
    event.stopImmediatePropagation()

    const confirmed = window.AppModal && typeof window.AppModal.confirm === "function"
      ? await window.AppModal.confirm({ message, title: "Confirm action" })
      : window.confirm(message)

    if (!confirmed) return

    this.confirmed = true
    if (typeof this.element.requestSubmit === "function") {
      this.element.requestSubmit(event.submitter || undefined)
    } else {
      this.element.submit()
    }
  }
}
