import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "panel"]
  static values = { defaultId: String }

  connect() {
    const initialId = this.defaultIdValue || this.buttonTargets[0]?.dataset.tabId
    if (initialId) this.show(initialId)
  }

  activate(event) {
    const tabId = event.currentTarget?.dataset?.tabId
    if (!tabId) return
    this.show(tabId)
  }

  show(tabId) {
    this.buttonTargets.forEach((button) => {
      const active = button.dataset.tabId === tabId
      button.classList.toggle("is-active", active)
      button.setAttribute("aria-selected", active ? "true" : "false")
      button.tabIndex = active ? 0 : -1
    })

    this.panelTargets.forEach((panel) => {
      const active = panel.dataset.tabId === tabId
      panel.classList.toggle("hidden", !active)
      panel.toggleAttribute("hidden", !active)
    })
  }
}
