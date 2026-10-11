import { Controller } from "@hotwired/stimulus"

const CHECK_INTERVAL_MS = 30_000
const ACTIVITY_EVENTS = ["click", "keydown", "scroll", "mousemove"]

// Status polling never extends the session. Only activity or the explicit
// renewal button does. A native dialog blocks mouse AND keyboard input without
// navigating away from unsaved forms when authentication is lost.
export default class extends Controller {
  static targets = ["modal", "countdown", "warning", "expired", "checking", "error", "accountChanged"]
  static values = {
    expiresAt: String,
    warnSeconds: { type: Number, default: 60 },
    touchUrl: String,
    loginUrl: String,
    userId: String,
    touchThrottleMs: { type: Number, default: 5 * 60 * 1000 }
  }

  connect() {
    this.disconnected = false
    this.expiresAt = new Date(this.expiresAtValue)
    this.lastTouchAt = Date.now()
    this.lastCheckAt = 0
    this.lastVerifiedAt = 0
    this.warningVisible = false
    this.state = null
    this.sessionGeneration = (this.sessionGeneration || 0) + 1
    this.rejectedSubmissions = new WeakSet()

    this.boundActivity = this.handleActivity.bind(this)
    this.boundResume = this.resume.bind(this)
    this.boundResponse = this.handleResponse.bind(this)
    this.boundSubmit = this.guardSubmission.bind(this)
    this.boundSubmitEnd = this.handleSubmitEnd.bind(this)
    this.boundKeydown = this.guardEscape.bind(this)
    this.boundCache = this.hideWarning.bind(this)
    for (const name of ACTIVITY_EVENTS) {
      document.addEventListener(name, this.boundActivity, { passive: true, capture: true })
    }
    document.addEventListener("visibilitychange", this.boundResume)
    window.addEventListener("focus", this.boundResume)
    window.addEventListener("pageshow", this.boundResume)
    window.addEventListener("online", this.boundResume)
    document.addEventListener("turbo:before-fetch-response", this.boundResponse)
    document.addEventListener("submit", this.boundSubmit, true)
    document.addEventListener("turbo:submit-end", this.boundSubmitEnd, true)
    document.addEventListener("keydown", this.boundKeydown, true)
    document.addEventListener("turbo:before-cache", this.boundCache)
    this.tickInterval = setInterval(() => this.tick(), 5000)
    this.resume()
  }

  disconnect() {
    this.disconnected = true
    this.abortController?.abort()
    for (const name of ACTIVITY_EVENTS) {
      document.removeEventListener(name, this.boundActivity, { capture: true })
    }
    document.removeEventListener("visibilitychange", this.boundResume)
    window.removeEventListener("focus", this.boundResume)
    window.removeEventListener("pageshow", this.boundResume)
    window.removeEventListener("online", this.boundResume)
    document.removeEventListener("turbo:before-fetch-response", this.boundResponse)
    document.removeEventListener("submit", this.boundSubmit, true)
    document.removeEventListener("turbo:submit-end", this.boundSubmitEnd, true)
    document.removeEventListener("keydown", this.boundKeydown, true)
    document.removeEventListener("turbo:before-cache", this.boundCache)
    clearInterval(this.tickInterval)
    this.hideWarning()
  }

  tick() {
    if (document.hidden) return
    const remaining = Math.floor((this.expiresAt.getTime() - Date.now()) / 1000)
    if (remaining <= 0 && !this.warningVisible) this.showState("checking")
    if (!this.state || this.state === "warning") {
      if (remaining > 0 && remaining <= this.warnSecondsValue) this.showWarning(remaining)
    }
    if (Date.now() - this.lastCheckAt >= CHECK_INTERVAL_MS || remaining <= 0) {
      this.checkSession()
    }
  }

  resume() {
    if (document.hidden) return
    if (this.withinWarningWindow() && !this.warningVisible) this.showState("checking")
    return this.checkSession()
  }

  stale() {
    return Date.now() - this.lastVerifiedAt >= CHECK_INTERVAL_MS || this.expiresAt.getTime() <= Date.now()
  }

  // Blocking the page states something about the session, not about the network.
  // Routine verification therefore stays invisible: staleness repeats every poll
  // interval, so blocking on it flashed the dialog for one round trip on every
  // page load and on the first mouse move after each poll. Only a deadline that
  // is close enough to change what is safe earns the dialog.
  withinWarningWindow() {
    return this.expiresAt.getTime() - Date.now() <= this.warnSecondsValue * 1000
  }

  handleActivity() {
    if (this.warningVisible || document.hidden) return
    if (this.stale()) {
      // A failed check leaves the session unverified, so without this every
      // further mouse move would start another request and amplify an outage.
      // The open dialog used to throttle this by suppressing activity; it is no
      // longer open for a routine check, so the poll interval has to say it.
      if (Date.now() - this.lastCheckAt < CHECK_INTERVAL_MS) return
      this.resume()
      return
    }
    if (Date.now() - this.lastTouchAt < this.touchThrottleMsValue) return
    this.touch()
  }

  guardSubmission(event) {
    if (!this.warningVisible && !this.pending && !this.stale()) return
    event.preventDefault()
    event.stopImmediatePropagation()
    // This swallows the click, so the dialog has to account for it. An in-flight
    // check holds the form back too: it may be about to rotate the CSRF token.
    if (!this.warningVisible) this.showState("checking")
    this.checkSession()
  }

  guardEscape(event) {
    if (!this.warningVisible || event.key !== "Escape") return
    event.preventDefault()
    event.stopImmediatePropagation()
  }

  handleResponse(event) {
    const response = event.detail.fetchResponse?.response
    if (!response) return
    const login = new URL(this.loginUrlValue, window.location.href)
    const target = response.url && new URL(response.url, window.location.href)
    if (response.status === 401 || (response.redirected && target?.origin === login.origin && target.pathname === login.pathname)) {
      event.preventDefault()
      if (event.target) this.rejectedSubmissions.add(event.target)
      this.sessionGeneration += 1
      this.abortController?.abort()
      this.pending = null
      this.showExpired()
    }
  }

  handleSubmitEnd(event) {
    if (!this.rejectedSubmissions.has(event.target)) return
    // A redirected login page has HTTP 200. Turbo otherwise calls this a
    // successful submission, causing existing success handlers to erase drafts.
    event.detail.success = false
    this.rejectedSubmissions.delete(event.target)
  }

  stayLoggedIn(event) {
    event?.preventDefault()
    return this.touch()
  }

  checkSession() {
    return this.requestSession(false)
  }

  touch() {
    return this.requestSession(true)
  }

  async requestSession(extend) {
    if (this.pending) {
      const checking = !this.pendingExtends
      const success = await this.pending
      // An explicit renewal must not be swallowed by an in-flight status poll.
      if (extend && checking && success && !this.disconnected) return this.requestSession(true)
      return success
    }
    this.pendingExtends = extend
    const pending = this.fetchSession(extend)
    this.pending = pending
    try {
      return await pending
    } finally {
      if (this.pending === pending) this.pending = null
    }
  }

  async fetchSession(extend) {
    const url = new URL(this.touchUrlValue, window.location.href)
    if (!extend) url.searchParams.set("check", "1")
    const generation = this.sessionGeneration
    const abortController = new AbortController()
    this.abortController = abortController
    const timeout = setTimeout(() => abortController.abort(), 10000)
    this.lastCheckAt = Date.now()
    try {
      const response = await fetch(url, {
        headers: { Accept: "application/json" }, credentials: "same-origin",
        cache: "no-store", signal: abortController.signal
      })
      if (this.disconnected || generation !== this.sessionGeneration) return false
      if (response.status === 401) {
        this.showExpired()
        return false
      }
      if (!response.ok) throw new Error("Session check failed")
      const data = await response.json()
      if (this.disconnected || generation !== this.sessionGeneration) return false
      if (String(data.user_id) !== this.userIdValue) {
        this.showState("accountChanged")
        return false
      }
      const expiresAt = new Date(data.expires_at)
      if (!Number.isFinite(expiresAt.getTime()) || !data.csrf_token) throw new Error("Invalid session response")
      this.expiresAt = expiresAt
      this.lastVerifiedAt = Date.now()
      if (extend) this.lastTouchAt = Date.now()
      // Signing back in rotates CSRF tokens. Keep existing drafts, but update
      // both Turbo's token and the tokens in already-rendered Rails forms.
      const meta = document.querySelector('meta[name="csrf-token"]')
      if (meta) meta.content = data.csrf_token
      document.querySelectorAll('input[name="authenticity_token"]').forEach(input => { input.value = data.csrf_token })
      const remaining = Math.floor((expiresAt.getTime() - Date.now()) / 1000)
      if (remaining <= 0) this.showExpired()
      else if (remaining <= this.warnSecondsValue) this.showWarning(remaining)
      else this.hideWarning()
      return true
    } catch (_) {
      if (!this.disconnected && generation === this.sessionGeneration && this.warningVisible) this.errorTarget.hidden = false
      return false
    } finally {
      clearTimeout(timeout)
    }
  }

  showWarning(remainingSec) {
    this.showState("warning")
    this.countdownTarget.textContent = remainingSec.toString()
  }

  showExpired() {
    this.showState("expired")
  }

  showState(state) {
    this.state = state
    this.warningVisible = true
    for (const name of ["warning", "expired", "checking", "accountChanged"]) {
      this[`${name}Target`].hidden = name !== state
    }
    this.errorTarget.hidden = true
    if (!this.modalTarget.open) this.modalTarget.showModal()
  }

  preventClose(event) {
    event.preventDefault()
  }

  hideWarning() {
    this.state = null
    this.warningVisible = false
    if (this.modalTarget.open) this.modalTarget.close()
  }
}
