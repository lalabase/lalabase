import { Controller } from "@hotwired/stimulus"
import { escapeOwned } from "escape_owner"
import { meetingPanelStage } from "lane/meeting_panel_stage"

// The meeting beside the ticket (doc/ticket_meeting_panel_plan.md, S1), mounted on the
// content of turbo-frame#ticket_meeting_panel (tickets/_meeting_panel, and the "not
// available" answer). The lane belongs to layout_toggle; this controller only tells it
// when to open and when to close, as events on its mount:
//   * connect opens it: the frame has just been filled. Not turbo:frame-load: on the
//     ticket page that event does not reliably reach the document (ticket_selection,
//     controllers/CLAUDE.md), and a connect happens for every way content arrives.
//     Unless the lane has moved on to another ticket while the answer was on its way:
//     then it closes at once;
//   * Escape closes it, before the ticket lane behind it (lib/escape_owner.js);
//   * the ticket lane showing another ticket, or none, closes it (decision F3): the
//     meeting belongs to the ticket it was opened from. The lane has eight writers and
//     most are streams that fire no load event, so the lane is watched instead.
// And while it is open it decides how much of it fits (S2): a ResizeObserver on the grid
// writes data-meeting-panel-stage (wide | medium | narrow, lib/lane/meeting_panel_stage)
// for the stylesheet, and at the narrow stage it keeps which of ticket and meeting is in
// front (data-meeting-panel-tab). The grid, not the window: the assistant beside the page
// changes the grid's width without the window changing at all.
export default class extends Controller {
  static targets = ["ticketTab", "meetingTab"]
  static values = { ticketId: String }

  connect() {
    this.grid = this.element.closest(".layout")
    if (this.grid) {
      // Read once: they are the stylesheet's constants (layout.css, :root, in px),
      // and the observer below can fire on every frame of the assistant's drag.
      const style = getComputedStyle(this.grid)
      const number = name => parseFloat(style.getPropertyValue(name))
      this.panelNumbers = {
        panelMin: number("--panel-min"),
        panelShare: number("--panel-share"),
        panelMax: number("--panel-max"),
        gap: number("--lane-gap")
      }
      // The link just clicked to open the panel sits in the ticket and keeps the focus
      // (Safari focuses no clicked link: then nothing needs excusing). Until the focus
      // leaves that link, nobody is working in the ticket (workingInTicket); whoever
      // comes back to it later is moving through the ticket. Only a link that loads
      // this frame: any other focus in the ticket is somebody's work, however the
      // panel came.
      const active = document.activeElement
      const frameId = this.element.closest("turbo-frame")?.id
      const link = frameId && active?.matches?.(`a[data-turbo-frame="${CSS.escape(frameId)}"]`) ? active : null
      this.openingLink = link
      link?.addEventListener("blur", () => { if (this.openingLink === link) this.openingLink = null }, { once: true })
      // Before the lane opens, so its first frame already has the right stage.
      this.select("meeting")
      this.updateStage(this.grid.getBoundingClientRect().width)
      this.resizeObserver = new ResizeObserver(([entry]) =>
        this.updateStage(entry.borderBoxSize?.[0]?.inlineSize ?? entry.contentRect.width))
      this.resizeObserver.observe(this.grid)
    }

    this.dispatch(this.laneShowsTicket() ? "open" : "close")

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
    this.resizeObserver?.disconnect()
    this.openingLink = null
    // A tab of the panel replaces this content and connects a new instance in the
    // same task, which writes both again before anything is painted.
    delete this.grid?.dataset.meetingPanelStage
    delete this.grid?.dataset.meetingPanelTab
  }

  // --- stages (S2) --------------------------------------------------------

  updateStage(gridWidth) {
    const stage = meetingPanelStage({ gridWidth, ...this.panelNumbers })
    const previous = this.grid.dataset.meetingPanelStage
    if (stage === previous) return

    this.grid.dataset.meetingPanelStage = stage
    // Dropping to the tabs shows the meeting first: it is what was opened last (F6).
    // Unless the panel was already open and somebody is working in the ticket (the
    // focus is in it): the grid narrows under their hands (a window or the assistant
    // dragged), and hiding the field they type into would send the next keys
    // nowhere. Not on opening: the link just clicked sits in the ticket, too. And the
    // opening is not one moment: the assistant pushes the page aside in a transition
    // of <main>, so a panel opened during it sees the grid narrow a few frames later.
    if (stage === "narrow") this.select(previous && this.workingInTicket() ? "ticket" : "meeting")
  }

  workingInTicket() {
    const active = document.activeElement
    if (!active || active === document.body || active === this.openingLink) return false
    return Boolean(this.grid.querySelector(":scope > .column.content")?.contains(active))
  }

  showTicket() {
    this.select("ticket")
  }

  showMeeting() {
    this.select("meeting")
  }

  select(tab) {
    if (!this.grid) return

    this.grid.dataset.meetingPanelTab = tab
    if (this.hasTicketTabTarget) this.ticketTabTarget.setAttribute("aria-pressed", String(tab === "ticket"))
    if (this.hasMeetingTabTarget) this.meetingTabTarget.setAttribute("aria-pressed", String(tab === "meeting"))
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

  // A linked ticket of the same project opens in the lane the way its row does, by
  // clicking that row: list_row writes the address, loads the lane and marks the row,
  // and nothing else ends up marked. Off the current page of the list, the ticket
  // page itself (the link's address). A modified click is the browser's (new tab).
  openTicket(event) {
    if (event.button > 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    const id = event.currentTarget.dataset.ticketId
    const row = this.grid?.querySelector(`.column.list [data-controller~="list-row"][data-list-row-id-value="${CSS.escape(id)}"]`)
    event.preventDefault()
    if (row) {
      row.click()
    } else {
      window.Turbo.visit(event.currentTarget.href)
    }
  }

  get lane() {
    return document.getElementById("ticket_display_frame")
  }

  laneShowsTicket() {
    const lane = this.lane
    if (!lane || !this.ticketIdValue) return true

    return Boolean(lane.querySelector(`#ticket-content-${CSS.escape(this.ticketIdValue)}`))
  }

  observeTicketLane() {
    const lane = this.lane
    if (!lane || !this.ticketIdValue) return

    this.laneObserver = new MutationObserver(() => {
      if (!this.laneShowsTicket()) this.close()
    })
    this.laneObserver.observe(lane, { childList: true })
  }
}
