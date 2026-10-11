import { Controller } from "@hotwired/stimulus"

// Inline sub-task quick-add. Empties + refocuses the field the moment a submission starts, so the
// user can type the next sub-task without waiting for the server. At turbo:submit-start the form is
// already serialized, so clearing here does NOT drop the title being sent. In the populated list the
// <li> this lives on is never re-rendered by the append stream, so focus + in-progress typing survive.
//
// autofocus is set by create_first.turbo_stream (the empty -> populated swap re-renders this input),
// so the user keeps typing after the first sub-task without re-clicking.
export default class extends Controller {
  static targets = ["input"]
  static values = { autofocus: Boolean }

  connect() {
    if (this.autofocusValue) this.inputTarget.focus()
  }

  // Skip empty/whitespace submits (the server also guards; this just avoids a pointless round-trip).
  guard(event) {
    if (this.inputTarget.value.trim() === "") event.preventDefault()
  }

  clear() {
    this.inputTarget.value = ""
    this.inputTarget.focus()
  }
}
