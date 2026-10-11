import { Controller } from "@hotwired/stimulus"

// Chat composer behavior. Submit on Enter; Shift+Enter inserts a newline
// (standard chat UX). `isComposing` guards IME input (e.g. CJK) where Enter
// confirms a candidate instead of sending. The controller sits on the <form>,
// so this.element is it.
//
// The textarea starts single-line (rows=1) and grows with its content via
// `autogrow` up to MAX_HEIGHT_PX; beyond that it scrolls internally. The
// icon-only send button inside the field is shown only while there is content
// (`syncSend`). A fresh composer arrives via turbo_stream replace after each
// sent message, so field height and button visibility reset on their own.
const MAX_HEIGHT_PX = 200

export default class extends Controller {
  static targets = ["field", "send"]

  connect() {
    // Browsers may restore form state (back navigation) — sync to the actual
    // content instead of assuming an empty field.
    this.syncSend()
  }

  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return

    event.preventDefault()
    if (this.empty()) return

    this.element.requestSubmit()
  }

  autogrow() {
    const field = this.fieldTarget
    // Collapse first so scrollHeight reflects the actual content height (it
    // never shrinks below the current CSS height otherwise).
    field.style.height = "auto"
    const borders = field.offsetHeight - field.clientHeight
    const fullHeight = field.scrollHeight + borders
    field.style.height = `${Math.min(fullHeight, MAX_HEIGHT_PX)}px`
    field.style.overflowY = fullHeight > MAX_HEIGHT_PX ? "auto" : "hidden"

    this.syncSend()
  }

  syncSend() {
    if (!this.hasSendTarget || !this.hasFieldTarget) return

    this.sendTarget.classList.toggle("hidden", this.empty())
  }

  empty() {
    return !this.hasFieldTarget || this.fieldTarget.value.trim() === ""
  }
}
