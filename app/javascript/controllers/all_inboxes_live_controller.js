import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { liveStep, returnStep, redrawAddress } from "inbox_live"

// Keeps the inbox above the organisations current while it is open
// (all_inboxes/index). The stream (Notifications::Streams.all_inboxes) replaces
// the signal target with the latest stamp; every list redraw replaces the drawn
// target. Both connect here, and each time the rule of lib/inbox_live decides:
// redraw the counts and show the banner, redraw the list, or nothing.
// The redraw is GET /inbox as turbo_stream, the page's own reader.
export default class extends Controller {
  static targets = ["signal", "drawn", "banner"]
  static values = { url: String }

  connect() {
    this.counted = null
    this.onVisibility = () => this.visibilityChanged()
    document.addEventListener("visibilitychange", this.onVisibility)
  }

  disconnect() {
    document.removeEventListener("visibilitychange", this.onVisibility)
  }

  signalTargetConnected() {
    this.react()
  }

  drawnTargetConnected() {
    this.react()
  }

  // The banner's word: the list catches up, and the banner goes once the drawn
  // stamp equals the signal (react, after the redraw).
  refresh() {
    this.redraw("list")
  }

  visibilityChanged() {
    if (document.hidden) return
    if (returnStep(this.stamps())) this.redraw("list")
  }

  react() {
    const stamps = this.stamps()
    const step = liveStep({ ...stamps, counted: this.counted, hidden: document.hidden })
    if (this.hasBannerTarget) this.bannerTarget.classList.toggle("hidden", !step.banner)
    if (step.fetch === "counts") {
      this.counted = stamps.signal
      this.redraw("counts")
    }
  }

  stamps() {
    return {
      signal: this.hasSignalTarget ? this.signalTarget.dataset.stamp : null,
      drawn: this.hasDrawnTarget ? this.drawnTarget.dataset.stamp : null
    }
  }

  async redraw(part) {
    const list = document.getElementById("inbox_master_list")
    const address = redrawAddress(window.location.href, {
      path: new URL(this.urlValue, window.location.origin).pathname,
      firstPage: list?.dataset.neoEndlessScrollFirstPageValue,
      throughPage: list?.dataset.neoEndlessScrollPageValue,
      part
    })
    try {
      const response = await fetch(address, {
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin"
      })
      if (response.ok) Turbo.renderStreamMessage(await response.text())
    } catch (error) {
      // The next signal or the next visit tries again.
      console.warn("Inbox redraw failed", error)
    }
  }
}
