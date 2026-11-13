import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { liveStep, redrawAddress } from "inbox_live"

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
    this.connected = true
    this.submitting = false
    this.counted = null
    this.retryDelay = 1000
    this.onVisibility = () => this.visibilityChanged()
    this.onOnline = () => this.reconcile()
    this.onSubmitStart = () => {
      this.submitting = true
      this.cancelRedraw()
    }
    this.onSubmitEnd = () => {
      this.submitting = false
      this.reconcile()
    }
    document.addEventListener("visibilitychange", this.onVisibility)
    window.addEventListener("online", this.onOnline)
    this.element.addEventListener("turbo:submit-start", this.onSubmitStart)
    this.element.addEventListener("turbo:submit-end", this.onSubmitEnd)

    // Turbo marks its cable source as connected on every subscription, including
    // reconnects. Broadcasts missed before subscribing or while offline are not
    // replayed, so local stamp equality cannot prove that the page is current.
    this.cableObserver = new MutationObserver((changes) => {
      if (changes.some(({ target }) => target.matches("turbo-cable-stream-source[connected]"))) this.reconcile()
    })
    this.cableObserver.observe(this.element, { subtree: true, attributes: true, attributeFilter: ["connected"] })
    this.reconcile()
  }

  disconnect() {
    this.connected = false
    this.cancelRedraw()
    this.cableObserver.disconnect()
    document.removeEventListener("visibilitychange", this.onVisibility)
    window.removeEventListener("online", this.onOnline)
    this.element.removeEventListener("turbo:submit-start", this.onSubmitStart)
    this.element.removeEventListener("turbo:submit-end", this.onSubmitEnd)
  }

  signalTargetConnected() {
    if (!this.connected) return
    const requestedList = this.request?.part === "list" || this.retryPart === "list"
    this.cancelRedraw()
    if (requestedList) return this.redraw("list")
    this.react()
  }

  drawnTargetConnected() {
    if (!this.connected) return
    // A row action or a search frame has redrawn the list independently of our
    // fetch. An earlier counts response must never undo that action's counts.
    this.cancelRedraw()
    this.counted = null
    this.react()
  }

  // The banner's word: the list catches up, and the banner goes once the drawn
  // stamp equals the signal (react, after the redraw).
  refresh() {
    this.redraw("list")
  }

  visibilityChanged() {
    if (document.hidden) return
    this.redraw("list")
  }

  reconcile() {
    if (!document.hidden) this.redraw("counts")
  }

  react() {
    if (!this.connected || this.submitting) return
    const stamps = this.stamps()
    const step = liveStep({ ...stamps, counted: this.counted, hidden: document.hidden })
    if (this.hasBannerTarget) this.bannerTarget.classList.toggle("hidden", !step.banner)
    if (step.fetch === "counts") this.redraw("counts")
  }

  stamps() {
    return {
      signal: this.hasSignalTarget ? this.signalTarget.dataset.stamp : null,
      drawn: this.hasDrawnTarget ? this.drawnTarget.dataset.stamp : null
    }
  }

  cancelRedraw() {
    this.request?.abort.abort()
    this.request = null
    clearTimeout(this.retryTimer)
    this.retryTimer = null
    this.retryPart = null
  }

  current(request) {
    return this.request === request && this.sameContext(request)
  }

  sameContext(request) {
    return this.connected && this.element.isConnected && !this.submitting &&
      this.hasSignalTarget && this.hasDrawnTarget &&
      window.location.href === request.page &&
      this.signalTarget === request.signal && this.drawnTarget === request.drawn &&
      document.getElementById("inbox_master_list") === request.list
  }

  retry(request) {
    if (!this.current(request)) return
    this.retryPart = request.part
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null
      this.retryPart = null
      if (!document.hidden && this.sameContext(request)) this.redraw(request.part)
    }, this.retryDelay)
    this.retryDelay = Math.min(this.retryDelay * 2, 30_000)
  }

  async redraw(part) {
    if (!this.connected || this.submitting || !this.element.isConnected || !this.hasSignalTarget || !this.hasDrawnTarget) return
    // A newer signal may supersede a refresh, but must still fulfil the reader's
    // request for the list, rather than downgrade it to counts alone.
    if (this.request?.part === "list" || this.retryPart === "list") part = "list"
    this.cancelRedraw()
    const list = document.getElementById("inbox_master_list")
    const request = this.request = {
      abort: new AbortController(), part, list, page: window.location.href,
      signal: this.signalTarget, drawn: this.drawnTarget,
      firstPage: list?.dataset.neoEndlessScrollFirstPageValue,
      throughPage: list?.dataset.neoEndlessScrollPageValue
    }
    const address = redrawAddress(window.location.href, {
      path: new URL(this.urlValue, window.location.origin).pathname,
      firstPage: request.firstPage,
      throughPage: request.throughPage,
      part
    })
    try {
      const response = await fetch(address, {
        signal: request.abort.signal,
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin"
      })
      if (response.redirected || !this.current(request)) return
      if (!response.ok) {
        if (response.status === 408 || response.status === 429 || (response.status >= 500 && response.status < 600)) this.retry(request)
        return
      }
      const html = await response.text()
      const stamp = response.headers.get("X-Inbox-Stamp")
      if (!stamp || !this.current(request)) return
      // Endless scroll appends to the same element. If it loaded another page
      // while we fetched, ask for that enlarged range before replacing the list.
      if (part === "list" && (request.firstPage !== list?.dataset.neoEndlessScrollFirstPageValue ||
        request.throughPage !== list?.dataset.neoEndlessScrollPageValue)) return this.redraw("list")

      // This endpoint contains only replacements. Apply the checked batch
      // synchronously through Turbo's replace action: renderStreamMessage queues
      // each action for a later repaint, after the context could change again.
      const template = document.createElement("template")
      template.innerHTML = html
      const streams = [...template.content.querySelectorAll("turbo-stream")].map(stream => document.importNode(stream, true))
      if (streams.some(stream => stream.action !== "replace")) return
      for (const stream of streams) Turbo.StreamActions.replace.call(stream)
      this.signalTarget.dataset.stamp = stamp
      this.counted = stamp
      this.retryDelay = 1000
      this.request = null
      this.react()
    } catch (error) {
      if (error.name !== "AbortError") {
        console.warn("Inbox redraw failed", error)
        this.retry(request)
      }
    } finally {
      if (this.request === request) this.request = null
    }
  }
}
