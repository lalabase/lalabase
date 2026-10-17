import { Controller } from "@hotwired/stimulus"
import { trapTabKey } from "dialog_a11y"

/**
 * Ticket Relation Modal Controller
 *
 * The "Link" modal of a ticket page (doc/ticket_relations_plan.md, revision 4, §7). It is
 * the CONTENT of the frame #ticket-relation-modal-<id>: a trigger link loads relations#new
 * into the frame, and this controller connecting is the modal opening. Each opening has an
 * id of its own (a token): a refused save replaces exactly this element, a save removes it,
 * and a late answer to a modal closed meanwhile finds nothing (review of #944).
 *
 * The frame, not the instance, keeps where the focus goes back: a refused save swaps the
 * instance, and the new one must not take the page body for the trigger. When no instance
 * is left in the frame, the focus returns to the trigger, found again by its id when a
 * stream replaced it; a menu entry hands over to its menu button.
 *
 * Shape after docs/dokumentation/modal_pattern.md (reference: meeting_modal_controller.js);
 * the focus trap is the shared lib/dialog_a11y.js.
 */
export default class extends Controller {
  static targets = ["card", "kind", "delay", "delayField"]
  // delayKinds: TicketRelation::DELAY_KINDS, the rule is written once, in the model.
  // returnId: the "..." button, when the element that opened the modal has no id.
  static values = { delayKinds: Array, returnId: String }

  connect() {
    this.frame = this.element.closest("turbo-frame")
    // The lane was closed while the form was loading (display:none around the frame): nobody
    // could see or close the modal, and it would still lock the page's scrolling. It
    // discards itself instead (review round 3 of #944).
    if (!this.shown()) {
      this.discarded = true
      this.close()
      return
    }
    if (this.frame && !this.frame.dataset.relationModalReturn) {
      this.frame.dataset.relationModalReturn = this.returnIdFor(document.activeElement) || this.returnIdValue
    }
    document.body.classList.add("overflow-hidden")
    this.kindChanged()
    if (this.hasKindTarget) this.kindTarget.focus()
  }

  // Removed by a save, a close or a refused save that brings the next instance.
  disconnect() {
    if (this.discarded) return

    document.body.classList.remove("overflow-hidden")
    const frame = this.frame
    if (!frame) return

    // The next trigger loads the form fresh.
    frame.removeAttribute("src")
    // After the mutation is done: a refused save has put its new instance in by then.
    setTimeout(() => this.returnFocus(frame), 0)
  }

  // On screen means: the block around the frame is rendered AND has a size. A shut lane is
  // no display:none but a 0px grid track with overflow hidden (layout.css, it stays laid out
  // to slide in again), which checkVisibility() alone takes for visible. The frame itself is
  // inline and holds only the fixed overlay, so its own box says nothing.
  shown() {
    const host = this.frame ? this.frame.parentElement : this.element.parentElement
    if (!host) return false
    if (typeof host.checkVisibility === "function" && !host.checkVisibility({ visibilityProperty: true })) return false

    const box = host.getBoundingClientRect()
    return box.width > 0 && box.height > 0
  }

  returnFocus(frame) {
    if (frame.querySelector('[data-controller~="ticket-relation-modal"]')) return

    const id = frame.dataset.relationModalReturn
    delete frame.dataset.relationModalReturn
    const lost = !document.activeElement || document.activeElement === document.body
    const target = id && document.getElementById(id)
    if (lost && target) target.focus()
  }

  // An entry of a dropdown menu is hidden once the menu closes; its button is not.
  returnIdFor(element) {
    if (!element || element === document.body) return null

    const menu = element.closest('[data-neo-dropdown-target="menu"]')
    if (menu) {
      const button = menu.parentElement && menu.parentElement.querySelector('[data-neo-dropdown-target="trigger"]')
      return button && button.id ? button.id : null
    }
    return element.id || null
  }

  // The delay field only for "precedes" and "follows"; disabled otherwise, so it is not sent.
  kindChanged() {
    if (!this.hasKindTarget || !this.hasDelayTarget) return

    const applies = this.delayKindsValue.includes(this.kindTarget.value)
    this.delayTarget.classList.toggle("hidden", !applies)
    if (this.hasDelayFieldTarget) this.delayFieldTarget.disabled = !applies
  }

  close() {
    if (this.frame) {
      this.frame.removeAttribute("src")
      this.frame.innerHTML = ""
    } else {
      this.element.remove()
    }
  }

  closeOnBackdrop(event) {
    if (event.target === event.currentTarget) this.close()
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // The modal is the content of its frame: it stands in the page only while open.
  ownsEscape() {
    return true
  }

  // An Escape the ticket picker already used (to close its list) closes nothing else.
  closeOnEscape(event) {
    if (event.key === "Escape" && !event.defaultPrevented) this.close()
  }

  // Keyboard must not wander into the page behind an aria-modal dialog.
  trapFocus(event) {
    if (this.hasCardTarget) trapTabKey(event, this.cardTarget)
  }
}
