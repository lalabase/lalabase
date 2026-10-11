import { Controller } from "@hotwired/stimulus"

// Click-to-edit for the ticket title and description (designer round 8a,
// 05.09.2026): a click on the text opens the same editor the pencil button
// opens, loaded into the writing_surface turbo frame. The pencil stays for
// those who look for it; nobody has to find it to fix a typo.
//
// Clicks that mean something else keep their meaning: interactive elements
// (links, lightbox images, buttons, disclosure summaries) and an actual
// text selection never trigger the editor.
export default class extends Controller {
  static values = {
    url: String,
    frame: { type: String, default: "writing_surface" },
  }

  open(event) {
    if (event.target.closest("a, button, img, summary, input, textarea, video, audio")) return

    const selection = window.getSelection()
    if (selection && selection.type === "Range") return

    const frame = document.getElementById(this.frameValue)
    if (frame) {
      frame.src = this.urlValue
    } else {
      window.Turbo?.visit(this.urlValue)
    }
  }
}
