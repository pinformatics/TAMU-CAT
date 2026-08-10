import { Controller } from "@hotwired/stimulus"

// Refreshes the page on an interval while this controller's element is
// connected. Used instead of a plain <meta http-equiv="refresh"> tag because
// Turbo Drive swaps the page body via pushState rather than a full
// navigation, so a meta-refresh timer set on one page keeps running (and
// reloading back to that page's URL) even after the user has navigated
// elsewhere.
//
// Uses Turbo.visit rather than window.location.reload(). A raw reload is a
// hard browser navigation outside Turbo's control -- once called, it can't
// be cancelled by anything that runs afterward (including the user's own
// click on a link), so it can still win a race against the user navigating
// away in the instant the timer fires. Turbo.visit is a *managed* visit:
// Turbo automatically cancels an in-flight visit when a new one starts, so
// the user's own navigation always supersedes a pending auto-refresh.
export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.timer = setInterval(() => {
      window.Turbo.visit(window.location.href, { action: "replace" })
    }, this.intervalValue)
    this.stop = this.stop.bind(this)
    document.addEventListener("turbo:before-visit", this.stop)
    document.addEventListener("turbo:before-cache", this.stop)
  }

  disconnect() {
    this.stop()
    document.removeEventListener("turbo:before-visit", this.stop)
    document.removeEventListener("turbo:before-cache", this.stop)
  }

  stop() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }
}
