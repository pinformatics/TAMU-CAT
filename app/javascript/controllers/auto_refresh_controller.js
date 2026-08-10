import { Controller } from "@hotwired/stimulus"

// Reloads the page on an interval while this controller's element is
// connected. Used instead of a plain <meta http-equiv="refresh"> tag because
// Turbo Drive swaps the page body via pushState rather than a full
// navigation, so a meta-refresh timer set on one page keeps running (and
// reloading back to that page's URL) even after the user has navigated
// elsewhere.
//
// Stopping the timer only in disconnect() isn't enough on its own: if the
// interval callback has already fired (calling location.reload()) at the
// same moment the user clicks a link away from this page, clearInterval()
// can't cancel a callback that's already running, and the reload races
// with -- and can win over -- the user's own navigation. Listening for
// turbo:before-visit stops the timer synchronously as soon as any Turbo
// navigation begins, before the reload has a chance to fire.
export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.timer = setInterval(() => window.location.reload(), this.intervalValue)
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
