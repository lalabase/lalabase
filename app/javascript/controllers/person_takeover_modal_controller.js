import TicketRelationModalController from "controllers/ticket_relation_modal_controller"

/**
 * Person Takeover Modal Controller
 *
 * The dialog "In andere Organisation übernehmen" of a contact's card (People S0, markup in
 * organisations/person_takeovers/_dialog.html.erb). The same frame-content modal as the
 * ticket relation modal, so it IS that controller: opening on connect, one id per opening,
 * focus trap, closing on the backdrop and on Escape. What differs:
 *
 * - the first field is the target organisation, and the sentence "visible to everyone with
 *   the people right in <target>" names the one chosen;
 * - a duplicate question holds for the target it was asked for: choosing another one hides
 *   it and the button says "Übernehmen" again (the server asks again for the new target).
 *   The offers to merge instead stand inside the question; hidden with it they are disabled
 *   too, because a form sends a hidden submit button as readily as a shown one;
 * - the menu entry that opened it sits in a <details> menu, which this controller closes on
 *   opening (a click inside does not close it, and Escape belongs to the modal), so the focus
 *   goes back to the "···" button (returnId), never to the hidden entry.
 */
export default class extends TicketRelationModalController {
  static targets = ["card", "organisation", "organisationName", "question", "submit", "merge"]

  connect() {
    super.connect()
    if (this.discarded) return

    const trigger = this.returnIdValue && document.getElementById(this.returnIdValue)
    const menu = trigger && trigger.closest("details")
    if (menu) menu.open = false
    if (!this.hasOrganisationTarget) return

    this.organisationChanged()
    this.organisationTarget.focus()
  }

  organisationChanged() {
    if (!this.hasOrganisationTarget) return

    const option = this.organisationTarget.selectedOptions[0]
    if (this.hasOrganisationNameTarget) this.organisationNameTarget.textContent = option ? option.text : ""
    if (!this.hasQuestionTarget) return

    const asked = this.organisationTarget.value === this.questionTarget.dataset.confirmTarget
    this.questionTarget.hidden = !asked
    this.mergeTargets.forEach((button) => { button.disabled = !asked })
    if (this.hasSubmitTarget) {
      this.submitTarget.textContent = asked ? this.submitTarget.dataset.confirmLabel : this.submitTarget.dataset.submitLabel
    }
  }

  // The "···" button, not the entry inside the closed menu.
  returnIdFor() {
    return null
  }
}
