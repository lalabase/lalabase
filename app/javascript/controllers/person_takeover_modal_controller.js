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
 * - while the form is sent, none of its buttons sends it again (lock, unlock). Turbo
 *   disables the button that sent it and no other, and Enter sends through the default
 *   button nobody sees: "Übernehmen" and the offers stayed live, and a click on one of
 *   them made a second copy;
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

  // turbo:submit-start of the form. What is sent was read from the form before this
  // event, so disabling a button here takes nothing out of the request. The button that
  // sent the form is Turbo's own and disabled already; a hidden offer is too.
  lock(event) {
    this.locked = Array.from(event.target.querySelectorAll('button[type="submit"]')).filter((button) => !button.disabled)
    this.locked.forEach((button) => { button.disabled = true })
  }

  // turbo:submit-end. After a success the page is on its way to another one, and the
  // buttons stay as they are until it comes. Anything else that leaves this dialog
  // standing (the connection failed) gives them back.
  unlock(event) {
    if (event.detail && event.detail.success) return

    const locked = this.locked || []
    this.locked = []
    locked.forEach((button) => { button.disabled = false })
  }

  // The "···" button, not the entry inside the closed menu.
  returnIdFor() {
    return null
  }
}
