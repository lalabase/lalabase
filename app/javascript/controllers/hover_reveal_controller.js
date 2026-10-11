import { Controller } from "@hotwired/stimulus"
import { createRevealTracker, rowFrom, ROW_SELECTOR } from "hover_reveal"

// Reveals the action affordances of the ONE row the pointer is on.
//
// Mounted on the LIST, not on the row: the rule is "at most one", and only
// something that can see all the rows can hold that. See lib/hover_reveal.js
// for why this stopped being pure CSS.
//
// A call site needs three hooks and nothing else:
//   the list  data-controller="hover-reveal"
//   each row  data-hover-reveal-target="row"
//   what appears  data-hover-reveal-target="actions"
// The events are bound HERE rather than in a data-action string, because the
// same seven-event string copied into seven templates is the duplication this
// controller exists to remove.
//
// The reveal class lands on the actions node ITSELF, never on an ancestor: the
// stylesheet switches that node's opacity and nothing else. ⚠️ Switches, not
// fades: the rows that stayed lit in Safari were never a stale class. Safari
// kept the old pixels after an opacity transition had ended (the whole story is
// in components/hover_reveal.css). The class toggle here was right; the
// transition next to it was the defect.
//
// Without JavaScript nothing is hidden at all: components/hover_reveal.css hides
// the actions only under `.hover-reveal-ready`, which this controller adds on
// connect. A broken bundle costs a calm list, not a delete button nobody can reach.
export default class extends Controller {
  connect() {
    this.tracker = createRevealTracker()
    this.pointer = null
    this.frame = null

    this.onPointerMove = (event) => this.point(event)
    this.onPointerLeave = () => this.clear()
    this.onScroll = () => this.repoint()
    this.onWindowBlur = () => this.clear()
    this.onFocusIn = (event) => this.focusRow(event)
    this.onFocusOut = () => this.blurRow()

    this.element.addEventListener("pointermove", this.onPointerMove)
    this.element.addEventListener("pointerleave", this.onPointerLeave)
    this.element.addEventListener("focusin", this.onFocusIn)
    this.element.addEventListener("focusout", this.onFocusOut)
    // The list may scroll in its own box (the assistant panel) or with the page
    // (the chat pages), and both move rows under a pointer that never moved.
    this.element.addEventListener("scroll", this.onScroll, { passive: true })
    window.addEventListener("scroll", this.onScroll, { passive: true })
    // The pointer can leave without a pointerleave: another window takes focus
    // while the mouse is still over a row.
    window.addEventListener("blur", this.onWindowBlur)

    this.element.classList.add("hover-reveal-ready")
  }

  // Turbo transplants and caches these lists. Leaving a row marked would restore
  // a page with an action row lit under a pointer that is somewhere else entirely.
  disconnect() {
    this.element.removeEventListener("pointermove", this.onPointerMove)
    this.element.removeEventListener("pointerleave", this.onPointerLeave)
    this.element.removeEventListener("focusin", this.onFocusIn)
    this.element.removeEventListener("focusout", this.onFocusOut)
    this.element.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("blur", this.onWindowBlur)

    if (this.frame) cancelAnimationFrame(this.frame)
    this.tracker.mark(null)
    this.tracker = null
    this.element.classList.remove("hover-reveal-ready")
  }

  // pointermove, not pointerover: every move re-derives the answer from where the
  // pointer actually IS. That is what makes this self-healing -- a lost enter or
  // leave event is corrected by the next move instead of standing there until the
  // window is resized, which is exactly how the CSS version failed.
  point(event) {
    if (!this.tracker) return

    this.pointer = { x: event.clientX, y: event.clientY }
    this.tracker.mark(rowFrom(event.target, this.element, ROW_SELECTOR))
  }

  clear() {
    if (!this.tracker) return

    this.pointer = null
    this.tracker.mark(null)
  }

  // elementFromPoint forces layout, and scroll fires far more often than the
  // answer can change, so at most one lookup per frame.
  //
  // ⚠️ A keyboard-held row wins here. Tabbing to a row the list had scrolled past
  // makes the browser scroll it into view, which fires this handler, which would
  // then hand the row back to wherever the mouse happens to rest -- the reveal
  // flashed and vanished on the very keypress that asked for it. Caught in the
  // browser on 29.08.2026; the CSS version could not be tested for this at all.
  repoint() {
    if (!this.tracker || this.frame) return
    if (!this.pointer && !this.focusedRow()) return

    this.frame = requestAnimationFrame(() => {
      this.frame = null
      if (!this.tracker) return

      const held = this.focusedRow()
      if (held) { this.tracker.mark(held); return }
      if (!this.pointer) return

      const under = document.elementFromPoint(this.pointer.x, this.pointer.y)
      this.tracker.mark(rowFrom(under, this.element, ROW_SELECTOR))
    })
  }

  // The row the KEYBOARD is on, or null. focus-visible, so a mouse click on the
  // trash does not count as the keyboard holding that row.
  focusedRow() {
    const focused = document.activeElement
    if (!focused || typeof focused.matches !== "function") return null
    if (!focused.matches(":focus-visible")) return null

    return rowFrom(focused, this.element, ROW_SELECTOR)
  }

  // Keyboard reveal, unchanged in meaning from the CSS it replaces: focus-VISIBLE,
  // so tabbing to the delete link shows the row, while clicking it does not leave
  // the row lit behind a pointer that has moved on.
  focusRow(event) {
    if (!this.tracker) return
    if (typeof event.target.matches !== "function") return
    if (!event.target.matches(":focus-visible")) return

    this.tracker.mark(rowFrom(event.target, this.element, ROW_SELECTOR))
  }

  // focusout fires BEFORE the next focusin, so deciding here would unmark a row
  // the focus is only passing through. One frame later document.activeElement has
  // settled and the pointer can take the row back.
  blurRow() {
    requestAnimationFrame(() => {
      if (!this.tracker) return

      const held = this.focusedRow()
      if (held) { this.tracker.mark(held); return }

      if (this.pointer) this.repoint()
      else this.tracker.mark(null)
    })
  }
}
