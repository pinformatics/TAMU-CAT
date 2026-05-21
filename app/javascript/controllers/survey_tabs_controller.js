import { Controller } from "@hotwired/stimulus"

// Shared tab controller for switching between sibling panels without page reload.
// Implements the ARIA tabs pattern (role="tablist" / role="tab" / role="tabpanel")
// including arrow-key navigation as per the WAI-ARIA authoring practices.
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { defaultTab: String }

  connect() {
    this.activeTabId = this.defaultTabValue || this.tabTargets[0]?.dataset.tabId || "settings"
    this.sync()
  }

  switchTab(event) {
    event?.preventDefault()
    const nextId = (event?.currentTarget?.dataset?.tabId || "").trim()
    if (!nextId.length) return

    this.activeTabId = nextId
    this.sync()
    // Move focus to the newly activated tab
    const activeTab = this.tabTargets.find((t) => t.dataset.tabId === nextId)
    activeTab?.focus()
  }

  // Arrow-key navigation as per the ARIA tabs pattern
  handleKeydown(event) {
    const tabs = this.tabTargets
    const currentIndex = tabs.indexOf(event.currentTarget)
    if (currentIndex === -1) return

    let nextIndex = null
    if (event.key === "ArrowRight" || event.key === "ArrowDown") {
      nextIndex = (currentIndex + 1) % tabs.length
    } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
      nextIndex = (currentIndex - 1 + tabs.length) % tabs.length
    } else if (event.key === "Home") {
      nextIndex = 0
    } else if (event.key === "End") {
      nextIndex = tabs.length - 1
    }

    if (nextIndex !== null) {
      event.preventDefault()
      this.activeTabId = tabs[nextIndex].dataset.tabId
      this.sync()
      tabs[nextIndex].focus()
    }
  }

  sync() {
    this.tabTargets.forEach((tab) => {
      const tabId = tab.dataset.tabId
      const isActive = tabId === this.activeTabId

      tab.setAttribute("aria-selected", isActive ? "true" : "false")
      tab.setAttribute("tabindex", isActive ? "0" : "-1")
      tab.classList.toggle("is-active", isActive)

      if (tab.classList.contains("btn") || tab.classList.contains("btn-primary") || tab.classList.contains("btn-secondary")) {
        tab.classList.toggle("btn-primary", isActive)
        tab.classList.toggle("btn-secondary", !isActive)
      }
    })

    this.panelTargets.forEach((panel) => {
      const panelId = panel.dataset.tabPanel
      const isActive = panelId === this.activeTabId
      panel.classList.toggle("hidden", !isActive)
      panel.setAttribute("aria-hidden", isActive ? "false" : "true")
    })
  }
}
