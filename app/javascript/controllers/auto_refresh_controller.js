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
//
// turbo:before-visit only covers link-style navigation. Actions like the
// "Delete batch" button submit a form instead, which Turbo handles through
// a separate lifecycle that doesn't fire turbo:before-visit until *after*
// the request completes -- so without also listening for turbo:submit-start,
// the timer can still fire mid-submission and reload a page whose record
// the submission just deleted, landing on a 404.
export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.timer = setInterval(() => {
      window.Turbo.visit(window.location.href, { action: "replace" })
    }, this.intervalValue)
    this.stop = this.stop.bind(this)
    document.addEventListener("turbo:before-visit", this.stop)
    document.addEventListener("turbo:before-cache", this.stop)
    document.addEventListener("turbo:submit-start", this.stop)
  }

  disconnect() {
    this.stop()
    document.removeEventListener("turbo:before-visit", this.stop)
    document.removeEventListener("turbo:before-cache", this.stop)
    document.removeEventListener("turbo:submit-start", this.stop)
  }

  stop() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }
}
