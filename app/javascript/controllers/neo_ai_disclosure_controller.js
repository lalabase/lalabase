import { Controller } from "@hotwired/stimulus"

// Enhancement around a NATIVE <details> (review of #625). The disclosure itself is
// the browser's: without this controller the note still opens, which matters
// because the Art. 13 half of the AI notice and the only privacy link on the chat
// surfaces live inside it.
//
// What this adds: the slide, Escape, and a click beside it. All three are comfort.
//
// ⚠️ The element sits inside the assistant panel, which is data-turbo-permanent.
// A Turbo transplant fires disconnect() and connect() on the SAME node with the
// SAME instance, and <details open> survives it. So connect() has to look at the
// element rather than assume a closed start — the first draft registered its
// listeners only when opening, and after any navigation Escape and click-beside
// were silently dead on a note that was still standing open.
export default class extends Controller {
  static targets = ["layer"]

  connect() {
    this.onDocumentClick = (event) => {
      if (!this.element.contains(event.target)) this.close()
    }
    this.onKeydown = (event) => {
      if (event.key !== "Escape" || !this.element.open) return
      // ⚠️ Only while the focus is actually IN here (same guard, same reason as
      // details_autoclose_controller). This listener sits on the document in the
      // capture phase and stops the event, so without the guard an open note would
      // swallow Escape from every other layer in the app — the search overlay, a
      // dropdown, a modal, all of which listen further down. A note nobody is
      // looking at must not own the key.
      if (!this.element.contains(document.activeElement)) return

      // Registered in the CAPTURE phase and stopped here: the panel listens for
      // Escape on its own node, so a key pressed with the focus inside the panel
      // (which is where it is, right after the click that opened this) would close
      // the whole assistant behind the note somebody just unfolded. The innermost
      // FOCUSED thing claims the key; the panel gets it back once this is closed.
      event.stopPropagation()
      this.close()
    }

    // Open across a transplant: pick the listeners back up, and skip the entry
    // animation for a note that was already standing.
    if (this.element.open) {
      this.reveal()
      this.startListening()
    }
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // The same two conditions as its Escape listener in connect().
  ownsEscape() {
    return this.element.open && this.element.contains(document.activeElement)
  }

  disconnect() {
    this.stopListening()
  }

  // Fired by the native toggle event, so it is right whether the fold was moved by
  // a click, by the keyboard, or by find-in-page opening it.
  toggled() {
    if (this.element.open) {
      // Next frame: the browser has to see the layer in its closed position once,
      // otherwise there is nothing to transition from.
      this.revealFrame = requestAnimationFrame(() => this.reveal())
      this.startListening()
    } else {
      // Cancel a reveal still queued from an opening in the same frame — it would
      // fire after conceal() and strip the closed position, and the NEXT opening
      // would then appear without sliding.
      cancelAnimationFrame(this.revealFrame)
      this.conceal()
      this.stopListening()
    }
  }

  close() {
    this.element.open = false // fires `toggle`, which does the rest
    // <details> takes its content out of the layout, so a focus that was on the
    // privacy link inside would land on <body>. Hand it back to the control that
    // owns the fold, like the sibling control does.
    this.element.querySelector("summary")?.focus()
  }

  reveal() {
    this.layerTarget?.classList.remove("translate-y-2", "opacity-0")
  }

  // Back to the closed position, so the next opening slides again. No timer and no
  // `hidden` juggling: <details> takes the layer out of the layout itself, so there
  // is no invisible box left over the composer if this node is transplanted
  // mid-animation.
  conceal() {
    this.layerTarget?.classList.add("translate-y-2", "opacity-0")
  }

  startListening() {
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("keydown", this.onKeydown, true)
  }

  stopListening() {
    document.removeEventListener("click", this.onDocumentClick)
    document.removeEventListener("keydown", this.onKeydown, true)
  }
}
