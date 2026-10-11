import { Controller } from "@hotwired/stimulus"

// S3a T4: the sidebar row that opens the assistant (plan §7.1, entry 1).
//
// It exists as its own controller for one structural reason: the panel lives at
// body level (it must, to be data-turbo-permanent and to escape the sidebar's
// transform/overflow), so the row is NOT inside the panel controller's scope and
// cannot address it with a Stimulus action. A custom event on window is the seam
// between the two; assistant_panel_controller listens for it and also syncs this
// row's active look back.
//
// S4 T2 step 5 (§7.3) added a SECOND thing to say over that seam: "the page you
// are on is about this object". Same reason for the same shape -- the button
// sits in an object's header, which is as far outside the panel as the sidebar
// row.
//
// TYPE and ID since the Bezugs-Sammlung (S1, §8.3), no longer a bare ticket id:
// the reference collection identifies an entry by the composite key
// "Ticket:<uuid>" (§7.1), and that key is the same value in the URL, in the
// form body, in data-reference-keys and in the panel's dismissed set.
export default class extends Controller {
  static values = { type: String, id: String, intent: String }

  toggle() {
    window.dispatchEvent(new CustomEvent("assistant-panel:toggle"))
  }

  // The optional intent selects an existing assistant mode after the panel has
  // visibly adopted this reference. Whether that can happen, on which thread,
  // and whether the user may reference the object remain panel/server decisions.
  adopt() {
    if (!this.typeValue || !this.idValue) return

    window.dispatchEvent(new CustomEvent("assistant-panel:adopt", {
      detail: {
        referenceKey: `${this.typeValue}:${this.idValue}`,
        intent: this.hasIntentValue ? this.intentValue : null,
      },
    }))
  }
}
