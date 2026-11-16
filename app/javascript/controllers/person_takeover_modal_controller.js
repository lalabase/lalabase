import TicketRelationModalController from "controllers/ticket_relation_modal_controller"

/**
 * Person Takeover Modal Controller
 *
 * The dialog "In andere Organisation übernehmen" of a contact's card (People S0, markup in
 * organisations/person_takeovers/_dialog.html.erb). The same frame-content modal as the
 * ticket relation modal, so it IS that controller: opening on connect, one id per opening,
 * focus trap, closing on the backdrop and on Escape. Two things differ:
 *
 * - the first field is the target organisation, and the sentence "visible to everyone with
 *   the people right in <target>" names the one chosen;
 * - the menu entry that opened it hides with its <details> menu, so the focus goes back to
 *   the "···" button (returnId), never to the hidden entry.
 */
export default class extends TicketRelationModalController {
  static targets = ["card", "organisation", "organisationName"]

  connect() {
    super.connect()
    if (this.discarded || !this.hasOrganisationTarget) return

    this.organisationChanged()
    this.organisationTarget.focus()
  }

  organisationChanged() {
    if (!this.hasOrganisationTarget || !this.hasOrganisationNameTarget) return

    const option = this.organisationTarget.selectedOptions[0]
    this.organisationNameTarget.textContent = option ? option.text : ""
  }

  // The "···" button, not the entry inside the closed menu.
  returnIdFor() {
    return null
  }
}
