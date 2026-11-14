import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import { listActionAddress } from "inbox_live"

// Delayed mark-as-read, in the inbox pane and in every ticket view
// (organisations/tickets/_ticket_display, Notifications::MarkTicketRead).
//
// Instead of marking a notification as read immediately when the pane
// opens, we give the user ~5 seconds for a quick look.
// If the pane still shows the same notification after the time elapses,
// we fire a PATCH /mark_read. If the pane is closed beforehand
// (another item opened, navigated elsewhere), the timer is aborted
// (disconnect). A lane shut in place (its ✕, Escape) hides the ticket by a
// class on the grid and leaves it in the page, so the timer asks at its end
// whether the ticket is still in view.
export default class extends Controller {
  // followAddress: on the inbox above the organisations the answer redraws the
  // list, so the address takes the list state the page names when the timer
  // fires (a search typed meanwhile, the pages loaded); the open row and quiet
  // stay the ones its own address names.
  static values = {
    url: String,
    delay: { type: Number, default: 5000 },
    followAddress: { type: Boolean, default: false }
  }

  connect() {
    this.connected = true
    if (!this.urlValue) return
    this.timer = setTimeout(() => this.markRead(), this.delayValue)
  }

  disconnect() {
    this.connected = false
    this.request?.abort()
    this.request = null
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }

  async markRead() {
    if (this.element.closest(".layout.hide-content")) return

    const page = window.location.href
    const list = document.getElementById("inbox_master_list")
    const head = document.getElementById("inbox_pane_status_pills")
    const address = this.address
    const request = this.request = new AbortController()
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      const response = await fetch(address, {
        signal: request.signal,
        method: "PATCH",
        headers: {
          "X-CSRF-Token": csrfToken || "",
          "Accept": "text/vnd.turbo-stream.html"
        },
        credentials: "same-origin"
      })
      if (response.ok) {
        const html = await response.text()
        if (!this.connected || !this.element.isConnected || this.request !== request ||
            this.element.closest(".layout.hide-content")) return
        if (!this.followAddressValue) {
          Turbo.renderStreamMessage(html)
          return
        }

        const currentList = window.location.href === page &&
          document.getElementById("inbox_master_list") === list && this.address === address
        const currentHead = document.getElementById("inbox_pane_status_pills") === head
        // Like the live redraw, apply a checked batch synchronously: Turbo's
        // queued rendering would leave another navigation window. A changed
        // search/list may still receive its identity-scoped head, never old rows.
        const template = document.createElement("template")
        template.innerHTML = html
        const streams = [...template.content.querySelectorAll("turbo-stream")].map(stream => document.importNode(stream, true))
        if (streams.some(stream => stream.action !== "replace")) return
        for (const stream of streams) {
          const isHead = stream.targets?.startsWith("#inbox_pane_status_pills[")
          if (isHead ? currentHead : currentList) {
            Turbo.StreamActions.replace.call(stream)
          }
        }
      }
    } catch (e) {
      // Fail silently — no user feedback needed.
      if (e.name !== "AbortError") console.warn("Delayed mark-read failed:", e)
    } finally {
      if (this.request === request) this.request = null
    }
  }

  get address() {
    if (!this.followAddressValue) return this.urlValue
    return listActionAddress(window.location.href, this.urlValue, document.getElementById("inbox_master_list"),
                             { keep: ["notification", "quiet"] })
  }
}
