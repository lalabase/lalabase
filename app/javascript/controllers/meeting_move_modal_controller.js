import { Controller } from "@hotwired/stimulus"
import { trapTabKey } from "dialog_a11y"

/**
 * Meeting Move Modal Controller
 *
 * The "move" dialog of a meeting (doc/meeting_verschieben_plan.md). It is the CONTENT of
 * the frame #meeting-move-modal-<id> in the lane head: the trigger loads
 * meetings#move_preflight into the frame, and this controller connecting is the dialog
 * opening. Each opening has a token of its own: a refused move replaces exactly this
 * element, and a late answer to a dialog closed meanwhile finds nothing.
 *
 * Built after README_MODAL_PATTERN.md from its reference implementation,
 * ticket_relation_modal_controller.js, without that dialog's own fields. The frame keeps
 * where the focus goes back, because a refused move swaps the instance.
 */
export default class extends Controller {
  static targets = ["card", "first"]
  // returnId: the trigger in the lane head, when the focused element has no id.
  static values = { returnId: String }

  connect() {
    this.frame = this.element.closest("turbo-frame")
    // The lane was closed while the dialog was loading: nobody could see or close it,
    // and it would still lock the page's scrolling. It discards itself instead.
    if (!this.shown()) {
      this.discarded = true
      this.close()
      return
    }
    if (this.frame && !this.frame.dataset.moveModalReturn) {
      this.frame.dataset.moveModalReturn = (document.activeElement && document.activeElement.id) || this.returnIdValue
    }
    document.body.classList.add("overflow-hidden")
    if (this.hasFirstTarget) this.firstTarget.focus()
  }

  // Removed by a close or by a refused move that brings the next instance.
  disconnect() {
    if (this.discarded) return

    document.body.classList.remove("overflow-hidden")
    const frame = this.frame
    if (!frame) return

    // The next trigger loads the dialog fresh.
    frame.removeAttribute("src")
    // After the mutation is done: a refused move has put its new instance in by then.
    setTimeout(() => this.returnFocus(frame), 0)
  }

  // On screen means: the block around the frame is rendered AND has a size. A shut lane
  // is a 0px grid track with overflow hidden, which checkVisibility() alone takes for
  // visible (see ticket_relation_modal_controller.js).
  shown() {
    const host = this.frame ? this.frame.parentElement : this.element.parentElement
    if (!host) return false
    if (typeof host.checkVisibility === "function" && !host.checkVisibility({ visibilityProperty: true })) return false

    const box = host.getBoundingClientRect()
    return box.width > 0 && box.height > 0
  }

  returnFocus(frame) {
    if (frame.querySelector('[data-controller~="meeting-move-modal"]')) return

    const id = frame.dataset.moveModalReturn
    delete frame.dataset.moveModalReturn
    const lost = !document.activeElement || document.activeElement === document.body
    const target = id && document.getElementById(id)
    if (lost && target) target.focus()
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
  // The dialog is the content of its frame: it stands in the page only while open.
  ownsEscape() {
    return true
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && !event.defaultPrevented) this.close()
  }

  // Keyboard must not wander into the page behind an aria-modal dialog.
  trapFocus(event) {
    if (this.hasCardTarget) trapTabKey(event, this.cardTarget)
  }
}
