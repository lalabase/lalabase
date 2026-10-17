import { Controller } from "@hotwired/stimulus"
import { snapshotEntries, VOLATILE_FIELDS } from "form_snapshot"

// The viewport-filling ticket form (doc/inline_bilder_paket_3_plan.md). Rendered into
// turbo-frame#writing_surface by tickets#new / tickets#edit; a successful save clears that frame
// by Turbo Stream, so this controller only has to handle the way OUT without saving:
// Escape and Cancel close an untouched form at once and ask first when the form changed
// (P3-E3). A click beside the surface never closes it. Focus goes to the title.
export default class extends Controller {
  static targets = ["form", "title"]
  static values = { unsavedMessage: String }

  connect() {
    this.snapshot = this.currentSnapshot()
    if (this.hasTitleTarget && !this.titleTarget.value) this.titleTarget.focus()
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // The surface stands in the page only while it is open: closing removes it.
  ownsEscape() {
    return true
  }

  escape(event) {
    // Lexxy and the tag picker use Escape themselves; only react when nothing else did.
    if (event.defaultPrevented) return
    this.cancel(event)
  }

  cancel(event) {
    if (event) event.preventDefault()
    if (this.changed() && !window.confirm(this.unsavedMessageValue)) return
    this.close()
  }

  changed() {
    return this.currentSnapshot() !== this.snapshot
  }

  currentSnapshot() {
    if (!this.hasFormTarget) return ""
    return snapshotEntries(new FormData(this.formTarget).entries(), { ignore: VOLATILE_FIELDS })
  }

  close() {
    const frame = this.element.closest("turbo-frame")
    if (frame) {
      frame.innerHTML = ""
    } else {
      this.element.remove()
    }
  }
}
