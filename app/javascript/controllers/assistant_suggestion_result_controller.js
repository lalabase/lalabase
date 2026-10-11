import { Controller } from "@hotwired/stimulus"

const INITIAL_DELAY = 4000
const MAX_DELAY = 30000
const THROTTLED_DELAY = 60000
const AUTO_REFRESH_INTERVAL = 60000
// Runs already announced as started on this page. Module-level on purpose: the
// card reconnects on every panel transplant and history re-render, and each of
// those must not send the meeting page another fetch.
const ANNOUNCED_ACTIVE_RUNS = new Set()

// Only running, visible cards poll. Completed cards refresh on explicit actions
// or returning to the panel; a permission-aware digest excludes changing CSRF tokens.
export default class extends Controller {
  static values = {
    url: String, active: Boolean, digest: String, meeting: String, error: String,
    announce: Boolean, announceLinks: Boolean
  }

  connect() {
    this.generation = (this.generation || 0) + 1
    this.delay ||= INITIAL_DELAY
    this.observed = false
    this.lastRefreshAt ??= Date.now()
    this.onVisible = () => {
      if (this.stale || Date.now() - this.lastRefreshAt >= AUTO_REFRESH_INTERVAL) return this.refresh(this.generation, true)
    }
    this.onChanged = event => {
      if (event.detail?.runId !== this.element.id && event.detail?.meetingId === this.meetingValue) {
        this.refresh(this.generation, true)
      }
    }
    window.addEventListener?.("focus", this.onVisible)
    window.addEventListener?.("assistant:suggestions-changed", this.onChanged)
    document.addEventListener?.("visibilitychange", this.onVisible)
    // ⚠️ A run that has just STARTED is announced too, once per page: the meeting
    // section otherwise keeps offering the previous open suggestions for accept
    // while this run is about to replace them, instead of showing "in progress".
    const startedRun = this.activeValue && !ANNOUNCED_ACTIVE_RUNS.has(this.element.id)
    if (startedRun) ANNOUNCED_ACTIVE_RUNS.add(this.element.id)
    if (this.announceValue || startedRun) {
      this.announceValue = false
      window.dispatchEvent?.(new CustomEvent("assistant:suggestions-changed", {
        detail: { runId: this.element.id, meetingId: this.meetingValue, refreshLinks: this.announceLinksValue }
      }))
    }
    if (typeof IntersectionObserver !== "undefined") {
      this.inViewport = false
      this.observer = new IntersectionObserver(entries => {
        const visible = entries.some(entry => entry.isIntersecting)
        const returned = this.observed && !this.inViewport && visible
        this.observed = true
        this.inViewport = visible
        clearTimeout(this.timer)
        if (returned) this.onVisible()
        else this.schedule(this.generation)
      })
      this.observer.observe(this.element)
    }
    this.schedule(this.generation)
  }

  schedule(generation) {
    if (generation === this.generation && this.activeValue && this.visible()) {
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.refresh(generation), this.delay || INITIAL_DELAY)
    }
  }

  disconnect() {
    this.generation += 1
    clearTimeout(this.timer)
    this.request?.abort()
    this.request = null
    this.observer?.disconnect()
    window.removeEventListener?.("focus", this.onVisible)
    window.removeEventListener?.("assistant:suggestions-changed", this.onChanged)
    document.removeEventListener?.("visibilitychange", this.onVisible)
  }

  visible() { return this.inViewport !== false && this.element.isConnected && this.element.getClientRects().length > 0 && !document.hidden }
  reload() { return this.refresh(this.generation, true) }

  async refresh(generation = this.generation, force = false) {
    let request
    try {
      if ((!this.activeValue && !force) || !this.visible() || this.request) {
        // ⚠️ A forced refresh (a change announced elsewhere) that cannot run NOW --
        // hidden card, closed panel, request in flight -- is remembered instead of
        // dropped. Otherwise a completed card keeps offering "accept" for a
        // suggestion settled on the meeting page, and nothing polls it later.
        if (force) this.stale = true
        return
      }
      this.stale = false
      request = this.request = new AbortController()
      this.lastRefreshAt = Date.now()
      const response = await fetch(this.urlValue, { signal: request.signal, headers: { Accept: "text/html" } })
      if (generation !== this.generation) return
      if (!this.visible()) { this.stale = true; return }
      if (!response.ok) {
        if ([403, 404].includes(response.status)) { this.element.textContent = this.errorValue; this.activeValue = false }
        if (response.status === 429) this.delay = THROTTLED_DELAY
        return
      }
      const result = new DOMParser().parseFromString(await response.text(), "text/html")
      const frame = result.getElementById(this.element.id)
      if (generation !== this.generation) return
      if (!this.visible()) { this.stale = true; return }
      if (!frame || response.redirected) { this.element.textContent = this.errorValue; this.activeValue = false; return }
      const wasActive = this.activeValue
      this.activeValue = frame.dataset.assistantSuggestionResultActiveValue === "true"
      const digest = frame.dataset.assistantSuggestionResultDigestValue
      if (digest && digest === this.digestValue) return
      this.digestValue = digest
      const open = [...this.element.querySelectorAll("[data-suggestion-id] details[open]")].map(node => node.closest("[data-suggestion-id]").dataset.suggestionId)
      frame.querySelectorAll("[data-suggestion-id]").forEach(node => { if (open.includes(node.dataset.suggestionId)) node.querySelector("details").open = true })
      const focused = window.document.activeElement
      let nextFocus
      if (this.element.contains(focused)) {
        if (focused.tagName === "SUMMARY") {
          const id = focused.closest("[data-suggestion-id]")?.dataset.suggestionId
          nextFocus = [...frame.querySelectorAll("[data-suggestion-id]")].find(node => node.dataset.suggestionId === id)?.querySelector("summary")
        } else if (focused.tagName === "BUTTON" && focused.form) {
          const action = focused.form.getAttribute("action")
          nextFocus = [...frame.querySelectorAll("form")].find(form => form.getAttribute("action") === action)?.querySelector("button")
        }
      }
      this.element.replaceChildren(...frame.childNodes)
      nextFocus?.focus({ preventScroll: true })
      if (wasActive && !this.activeValue) window.dispatchEvent?.(new CustomEvent("assistant:suggestions-changed", { detail: { runId: this.element.id, meetingId: this.meetingValue } }))
    } catch (_) { /* A temporary network failure leaves the last result available. */ }
    finally {
      let rerun = false
      if (request && this.request === request) {
        this.request = null
        this.delay = Math.min((this.delay || INITIAL_DELAY) * 2, this.delay === THROTTLED_DELAY ? THROTTLED_DELAY : MAX_DELAY)
        rerun = this.stale && generation === this.generation
      }
      if (rerun) this.refresh(generation, true)
      else this.schedule(generation)
    }
  }
}
