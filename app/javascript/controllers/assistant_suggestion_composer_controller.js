import { Controller } from "@hotwired/stimulus"

// Explicit, visible intent in the existing composer. Page context is never a target.
export default class extends Controller {
  static targets = ["tools", "mode", "meeting", "intent", "status", "retry"]
  static values = {
    url: String, prompt: String, choose: String, error: String, unavailable: String,
    appended: String, pending: String
  }

  connect() {
    this.root = this.element.closest("#assistant_panel_body") || this.element.parentElement
    this.observer = new MutationObserver(() => this.references())
    this.observer.observe(this.root, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-reference-keys"] })
    this.onInput = event => {
      if (event.target !== this.field) return
      if (!this.field.value.trim()) this.cancel()
      this.sync()
    }
    this.onNormal = () => this.cancel()
    this.onRequested = event => this.prepareForMeeting(event.detail?.meetingId)
    this.onSubmit = event => {
      // ⚠️ Blocked only while the options that DECIDE the explicit request are
      // actually on their way. Blocking on `requestedMeetingId` alone held every
      // message hostage after a failed eligible-meetings fetch: only a successful
      // load or cancel() cleared it, the retry button stood next to a composer
      // that refused to send, and the pending text overwrote the load error that
      // explained why. A request nothing is loading for cannot become ready by
      // waiting, so it must not stop an ordinary message.
      if (this.awaitingRequestedMeeting()) {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.statusTarget.textContent = this.pendingValue
      } else if (this.intentTarget.value && !this.meetingTarget.value) {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.meetingTarget.reportValidity()
      }
    }
    this.element.addEventListener("input", this.onInput)
    this.element.addEventListener("assistant:normal-request", this.onNormal)
    this.element.addEventListener("assistant:suggestion-request", this.onRequested)
    this.element.addEventListener("submit", this.onSubmit)
    this.references()
    this.sync()
  }

  disconnect() {
    this.observer.disconnect()
    this.request?.abort()
    this.request = null
    this.signature = this.pendingSignature = this.failedSignature = null
    this.element.removeEventListener("input", this.onInput)
    this.element.removeEventListener("assistant:normal-request", this.onNormal)
    this.element.removeEventListener("assistant:suggestion-request", this.onRequested)
    this.element.removeEventListener("submit", this.onSubmit)
  }

  get field() { return this.element.querySelector("textarea") }

  referencedMeetingIds() {
    return [...new Set([...this.root.querySelectorAll("[data-reference-keys]")]
      .flatMap(node => (node.dataset.referenceKeys || "").split(/\s+/))
      .filter(key => key.startsWith("Meeting:")).map(key => key.slice(8)))]
  }

  async references() {
    const ids = this.referencedMeetingIds()
    const signature = ids.join(" ")
    if (this.pendingSignature === signature) return
    // A reference can disappear while a request for the previous row is still
    // running. Even when the remaining row matches the last successful signature,
    // that in-flight response is no longer allowed to restore the removed meeting.
    if (this.pendingSignature) {
      this.request?.abort()
      this.request = null
      this.pendingSignature = null
    }
    if ([this.signature, this.failedSignature].includes(signature)) return
    this.request?.abort()
    const request = this.request = new AbortController()
    this.pendingSignature = signature
    if (!ids.length) { this.signature = signature; this.pendingSignature = null; this.toolsTarget.hidden = true; this.cancel(); return }
    try {
      const url = new URL(this.urlValue, location.origin)
      ids.forEach(id => url.searchParams.append("meeting_ids[]", id))
      const response = await fetch(url, { signal: request.signal, headers: { Accept: "application/json" } })
      if (!response.ok) throw new Error()
      const meetings = await response.json()
      if (request !== this.request || !this.element.isConnected) return
      this.signature = signature
      if (this.statusTarget.textContent === this.errorValue) this.statusTarget.textContent = ""
      this.failedSignature = null
      this.retryTarget.hidden = true
      this.meetings = meetings
      this.meetingTarget.replaceChildren(new Option(this.chooseValue, ""), ...meetings.map(m => new Option(`${m.title} · ${m.project}`, m.id)))
      this.toolsTarget.hidden = !meetings.length
      this.applyRequestedMeeting()
      if (this.intentTarget.value && this.intentTarget.value !== "choose" && !meetings.some(m => m.id === this.intentTarget.value)) {
        this.cancel()
        this.statusTarget.textContent = this.unavailableValue
      }
      this.sync()
    } catch (error) {
      if (request !== this.request) return
      if (error.name !== "AbortError") {
        this.failedSignature = signature
        // ⚠️ The failed load was the one that would have decided the explicit
        // request, so the request dies with it -- but ONLY if this signature
        // contains the requested meeting. A request for a meeting outside it is
        // not answered by this failure at all: its reference has not reached the
        // row this fetch was built from (a new chat's pill lands a microtask
        // before the observer starts its fetch), and the NEXT references() run
        // is the one that decides it. Dropping it here would lose a click that
        // is still perfectly serviceable.
        //
        // The error and the retry stay: they explain why task mode did not open,
        // and pressing the button (or the meeting entry again, see
        // prepareForMeeting) is the way back into it. Nothing resurrects the
        // dropped request behind the user's back after an automatic reload.
        if (this.requestedMeetingId && ids.includes(this.requestedMeetingId)) this.requestedMeetingId = null
        this.toolsTarget.hidden = false
        this.retryTarget.hidden = false
        this.statusTarget.textContent = this.errorValue
      }
    } finally {
      if (request === this.request) this.pendingSignature = null
    }
  }

  reloadOptions() { this.signature = this.failedSignature = null; return this.references() }

  // Whether an eligible-meetings fetch that can decide `requestedMeetingId` is in
  // flight right now. `pendingSignature` is the id list of exactly that fetch and
  // is cleared in its `finally` (or by disconnect, which aborts it), so this goes
  // false the moment the answer is in -- success applies the request, failure
  // drops it.
  awaitingRequestedMeeting() {
    if (!this.requestedMeetingId || !this.pendingSignature) return false
    return this.pendingSignature.split(" ").includes(this.requestedMeetingId)
  }

  prepare() {
    if (!this.meetings?.length) return
    this.element.querySelector('[data-meeting-analysis-composer-target="revisionId"]')?.setAttribute("value", "")
    const analysis = window.Stimulus?.getControllerForElementAndIdentifier(this.element, "meeting-analysis-composer")
    analysis?.cancelRevision()
    if (!this.intentTarget.value) {
      const draft = this.field.value
      this.field.value = draft.trim() ? `${draft}\n\n${this.promptValue}` : this.promptValue
      this.statusTarget.textContent = draft.trim() ? this.appendedValue : ""
      this.intentTarget.value = this.meetings?.length === 1 ? this.meetings[0].id : "choose"
    }
    this.sync()
    this.field.dispatchEvent(new Event("input", { bubbles: true }))
    this.field.focus()
  }

  prepareForMeeting(meetingId) {
    if (!meetingId) return
    this.requestedMeetingId = meetingId
    // ⚠️ The options for this meeting last FAILED and nothing is loading them:
    // references() returns early on `failedSignature`, so without this the
    // request would sit undecided -- not blocking any more (see onSubmit), but
    // waiting to open task mode on whatever unrelated reload succeeds next. An
    // explicit entry click is the same user intent as the retry button next to
    // the error, so it IS the retry.
    const failed = (this.failedSignature || "").split(" ").includes(meetingId)
    if (failed && !this.awaitingRequestedMeeting()) return this.reloadOptions()
    this.applyRequestedMeeting()
  }

  applyRequestedMeeting() {
    if (!this.requestedMeetingId || !this.meetings) return
    const meetingId = this.requestedMeetingId
    // The user may remove the newly requested reference while eligibility is
    // loading. Drop that intent immediately so adding the same reference later
    // cannot unexpectedly resurrect an old task-mode request.
    if (!this.referencedMeetingIds().includes(meetingId)) {
      this.requestedMeetingId = null
      return
    }
    // A scope write replaces the reference row before the eligible-meetings
    // request settles. Keep the explicit intent pending while `this.meetings`
    // still describes the previous row; otherwise a click for meeting B can be
    // rejected against meeting A's stale options and silently lost.
    const loadedReferenceIds = (this.signature || "").split(" ").filter(Boolean)
    if (!loadedReferenceIds.includes(meetingId)) return
    this.requestedMeetingId = null
    if (!this.meetings.some(meeting => meeting.id === meetingId)) {
      this.cancel()
      this.statusTarget.textContent = this.unavailableValue
      return
    }

    this.element.querySelector('[data-meeting-analysis-composer-target="revisionId"]')?.setAttribute("value", "")
    const analysis = window.Stimulus?.getControllerForElementAndIdentifier(this.element, "meeting-analysis-composer")
    analysis?.cancelRevision()
    if (!this.intentTarget.value) {
      const draft = this.field.value
      this.field.value = draft.trim() ? `${draft}\n\n${this.promptValue}` : this.promptValue
      this.statusTarget.textContent = draft.trim() ? this.appendedValue : ""
    }
    this.intentTarget.value = meetingId
    this.sync()
    this.field.dispatchEvent(new Event("input", { bubbles: true }))
    this.field.focus()
  }

  select() { this.intentTarget.value = this.meetingTarget.value || "choose"; this.sync() }
  sync() {
    const active = Boolean(this.intentTarget.value)
    this.modeTarget.hidden = !active
    this.meetingTarget.required = active
    this.meetingTarget.value = this.intentTarget.value === "choose" ? "" : this.intentTarget.value
  }
  cancel() { this.requestedMeetingId = null; this.intentTarget.value = ""; this.sync() }
}
