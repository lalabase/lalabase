import { Controller } from "@hotwired/stimulus"
import { escapeOwned } from "escape_owner"

// The meeting beside the ticket (doc/ticket_meeting_panel_plan.md, S1), mounted on the
// content of turbo-frame#ticket_meeting_panel (tickets/_meeting_panel, and the "not
// available" answer). The lane belongs to layout_toggle; this controller only tells it
// when to open and when to close, as events on its mount:
//   * connect opens it: the frame has just been filled. Not turbo:frame-load: on the
//     ticket page that event does not reliably reach the document (ticket_selection,
//     controllers/CLAUDE.md), and a connect happens for every way content arrives;
//   * Escape closes it, before the ticket lane behind it (lib/escape_owner.js);
//   * the ticket lane showing another ticket, or none, closes it (decision F3): the
//     meeting belongs to the ticket it was opened from. The lane has eight writers and
//     most are streams that fire no load event, so the lane is watched instead.
export default class extends Controller {
  static values = { ticketId: String }

  connect() {
    this.dispatch("open")

    this.boundNoteEscape = this.noteEscape.bind(this)
    window.addEventListener("keydown", this.boundNoteEscape, true)
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)
    document.addEventListener("keydown", this.boundCloseOnEscape)

    this.observeTicketLane()
  }

  disconnect() {
    window.removeEventListener("keydown", this.boundNoteEscape, true)
    document.removeEventListener("keydown", this.boundCloseOnEscape)
    this.laneObserver?.disconnect()
  }

  // While the lane shows this panel, the next Escape closes it.
  ownsEscape() {
    return this.isOpen
  }

  get isOpen() {
    const layout = this.element.closest(".layout")
    return Boolean(this.element.closest(".column.panel") && layout && !layout.classList.contains("hide-panel"))
  }

  close() {
    this.dispatch("close")
  }

  // Whether something above the panel (a dialog, a menu, a modal) owns this Escape,
  // asked before any listener has run, as layout_toggle asks for the lane.
  noteEscape(event) {
    if (event.key !== "Escape") return
    this.escapeAtKeydown = { event, ownedAbove: this.ownedAbove() }
  }

  closeOnEscape(event) {
    if (event.key !== "Escape" || event.defaultPrevented || !this.isOpen) return

    const noted = this.escapeAtKeydown
    const ownedAbove = noted?.event === event ? noted.ownedAbove : this.ownedAbove()
    if (ownedAbove) return

    event.preventDefault()
    this.close()
  }

  ownedAbove() {
    const others = (this.application?.controllers || []).filter(controller => controller !== this)
    return escapeOwned(others, document)
  }

  observeTicketLane() {
    const lane = document.getElementById("ticket_display_frame")
    if (!lane || !this.ticketIdValue) return

    this.laneObserver = new MutationObserver(() => {
      if (!lane.querySelector(`#ticket-content-${CSS.escape(this.ticketIdValue)}`)) this.close()
    })
    this.laneObserver.observe(lane, { childList: true })
  }
}
