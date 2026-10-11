import { Controller } from "@hotwired/stimulus"

// Keeps a shared meeting section aligned with the same records shown in the
// personal assistant: the ticket proposal list (assistant:suggestions-changed)
// and the stored analyses (assistant:analyses-changed). The server remains the
// source of truth; events only ask this permission-checked meeting page to fetch
// its own current rendering.
//
// ⚠️ The request carries a Turbo-Frame header. MeetingsController#show renders the
// lean detail frame only for `turbo_frame_request? && frame=content`; without the
// header the same URL renders the whole meetings index (layout, every meeting of
// the project) just so two small frames can be cut out of it.
export default class extends Controller {
  static values = {
    meeting: String, url: String, linksFrame: String, announce: Boolean, announceLinks: Boolean,
    event: { type: String, default: "assistant:suggestions-changed" }
  }

  connect() {
    this.generation = (this.generation || 0) + 1
    this.onChanged = event => {
      if (event.detail?.meetingId === this.meetingValue) {
        return this.refresh(this.generation, false, event.detail?.refreshLinks === true)
      }
    }
    window.addEventListener(this.eventValue, this.onChanged)
    // The announcement also reaches this listener on purpose: the accept that
    // re-rendered this section may have created a ticket, and the linked-tickets
    // frame is only refreshed by the fetch it triggers.
    if (this.announceValue) {
      this.announceValue = false
      window.dispatchEvent(new CustomEvent(this.eventValue, {
        detail: { sourceId: this.element.id, meetingId: this.meetingValue, refreshLinks: this.announceLinksValue }
      }))
    }
  }

  disconnect() {
    this.generation += 1
    this.request?.abort()
    this.request = null
    this.queuedGeneration = null
    this.queuedLinks = false
    window.removeEventListener(this.eventValue, this.onChanged)
  }

  async refresh(generation = this.generation, retrying = false, refreshLinks = false) {
    if (this.request) {
      this.queuedGeneration = generation
      this.queuedLinks ||= refreshLinks
      return
    }
    const request = this.request = new AbortController()
    let retryAfterFailure = false
    try {
      const response = await fetch(this.urlValue, {
        signal: request.signal,
        headers: { Accept: "text/html", "Turbo-Frame": "meeting_display_frame" }
      })
      if (response.redirected || generation !== this.generation || !this.element.isConnected) return
      if (!response.ok) throw new Error("Meeting section could not be refreshed")
      const result = new DOMParser().parseFromString(await response.text(), "text/html")
      const frame = result.getElementById(this.element.id)
      if (frame && generation === this.generation && this.element.isConnected) {
        this.element.replaceChildren(...frame.childNodes)
      }
      if (!refreshLinks || !this.linksFrameValue) return
      const currentLinks = document.getElementById(this.linksFrameValue)
      const freshLinks = result.getElementById(this.linksFrameValue)
      if (currentLinks && freshLinks && generation === this.generation && this.element.isConnected) {
        currentLinks.replaceChildren(...freshLinks.childNodes)
      }
    } catch (_) {
      // One immediate retry covers a transient navigation/network failure. More
      // events received meanwhile stay queued instead of being silently lost.
      retryAfterFailure = !retrying
    } finally {
      if (request === this.request) {
        const queued = this.queuedGeneration === generation
        const queuedLinks = this.queuedLinks === true
        this.queuedGeneration = null
        this.queuedLinks = false
        this.request = null
        if (generation === this.generation && this.element.isConnected) {
          // If the failed request itself carried a link-changing accept, a later
          // ordinary event must not downgrade the queued retry and lose that refresh.
          if (queued) this.refresh(generation, false, queuedLinks || (retryAfterFailure && refreshLinks))
          else if (retryAfterFailure) this.refresh(generation, true, refreshLinks)
        }
      }
    }
  }
}
