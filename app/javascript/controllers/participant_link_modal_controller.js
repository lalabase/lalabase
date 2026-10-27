import TicketRelationModalController from "controllers/ticket_relation_modal_controller"

/**
 * Participant Link Modal Controller
 *
 * The dialog "Mit Person verknüpfen" beside the participant chips of a meeting (S2b of the
 * people directory, markup in organisations/meeting_participant_links/_modal.html.erb). The
 * same frame-content modal as the ticket relation modal, so it IS that controller: opening
 * on connect, one id per opening, focus trap, closing on the backdrop and on Escape, the
 * focus back to the chip's link button. Only the first field differs: the search.
 */
export default class extends TicketRelationModalController {
  static targets = ["card", "search"]

  connect() {
    super.connect()
    if (!this.discarded && this.hasSearchTarget) this.searchTarget.focus()
  }
}
