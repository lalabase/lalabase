import { Controller } from "@hotwired/stimulus"

// Universal copy-to-clipboard controller.
//
// The source is EITHER a form field (its `value`) OR any other node (the text a
// reader sees in it). The second form is what the chat transcript uses: putting
// the message into a hidden field as well would carry every message through the
// page twice, and the rendered text is the better paste anyway — a question
// comes back exactly as it was typed, an answer comes back without its markdown
// scaffolding.
//
// Feedback is EITHER a label swap (a button with a word on it) OR an icon swap
// (a bare icon button), whichever targets are present.
//
// Usage with a field and a label:
//   <div data-controller="clipboard"
//        data-clipboard-success-text-value="Kopiert!">
//     <input data-clipboard-target="source" value="..." />
//     <button data-action="click->clipboard#copy" data-clipboard-target="button">
//       <span data-clipboard-target="buttonLabel">Kopieren</span>
//     </button>
//   </div>
//
// Usage with rendered text and an icon:
//   <div data-controller="clipboard" data-clipboard-success-text-value="Kopiert">
//     <button data-action="click->clipboard#copy" data-clipboard-target="button"
//             title="Kopieren" aria-label="Kopieren">
//       <i class="bi bi-clipboard" data-clipboard-target="icon"></i>
//     </button>
//     <div data-clipboard-target="source">the text the reader sees</div>
//   </div>
export default class extends Controller {
  static targets = ["source", "button", "buttonLabel", "icon"]
  static values = {
    successText: { type: String, default: "Copied!" },
    successIcon: { type: String, default: "bi-check-lg" },
    resetMs: { type: Number, default: 2000 },
  }

  copy() {
    const text = this.sourceText()
    if (!text) return

    // Try the async Clipboard API first; fall back to the legacy execCommand
    // for older browsers and non-secure contexts. The fallback is not
    // hypothetical: the dev server is reached over plain http on a LAN address,
    // which is not a secure context, so navigator.clipboard is absent there.
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text)
        .then(() => this.flashSuccess())
        .catch(() => this.legacyCopy())
    } else {
      this.legacyCopy()
    }
  }

  // A form field carries its text in `value`; anything else carries it as text.
  // innerText, not textContent: it keeps the line breaks the reader sees and
  // drops what is hidden, which is what someone pasting expects.
  sourceText() {
    if (!this.hasSourceTarget) return ""

    const source = this.sourceTarget
    return "value" in source ? source.value : source.innerText
  }

  legacyCopy() {
    if (!this.hasSourceTarget) return

    const source = this.sourceTarget
    if ("value" in source) {
      source.select()
      source.setSelectionRange(0, source.value.length)
      this.runCopyCommand()
      return
    }

    // execCommand copies the SELECTION, so a non-field source has to be selected
    // first — and un-selected afterwards, or the reader is left with a message
    // highlighted for no visible reason.
    // getSelection() is null in a document with no selection support (a detached
    // or hidden browsing context). Without a selection there is nothing for
    // execCommand to copy, so leave rather than throw out of the click handler.
    const selection = window.getSelection()
    if (!selection) return

    const range = document.createRange()
    range.selectNodeContents(source)
    selection.removeAllRanges()
    selection.addRange(range)
    this.runCopyCommand()
    selection.removeAllRanges()
  }

  runCopyCommand() {
    try {
      document.execCommand("copy")
      this.flashSuccess()
    } catch (_err) {
      // Silent fail — user can still copy manually.
    }
  }

  // ⚠️ The "back to normal" closures are captured ONCE per flash. A second click
  // inside the reset window must only push the timer out, never re-capture —
  // what it would capture is the success state, and the button would keep saying
  // "copied" for good.
  flashSuccess() {
    if (!this._restore) {
      const restore = this.swapToSuccess()
      if (restore.length === 0) return

      this._restore = restore
    }

    clearTimeout(this._timer)
    this._timer = setTimeout(() => this.reset(), this.resetMsValue)
  }

  reset() {
    if (!this._restore) return

    this._restore.forEach((undo) => undo())
    this._restore = null
  }

  // reset(), not just clearTimeout: a controller torn down mid-flash would
  // otherwise leave the tick and the "copied" name in the DOM for good — the
  // next instance starts with no restore closures and has nothing to put back.
  // Turbo's cached page preview is where that would show: a button saying
  // "copied" on a page nobody copied from.
  disconnect() {
    clearTimeout(this._timer)
    this.reset()
  }

  swapToSuccess() {
    const restore = []

    if (this.hasButtonLabelTarget) {
      const label = this.buttonLabelTarget
      const original = label.textContent
      label.textContent = this.successTextValue
      restore.push(() => { label.textContent = original })
    }

    if (this.hasIconTarget) {
      const icon = this.iconTarget
      const original = icon.getAttribute("class") || ""
      // Swap only the glyph class, so whatever sizing or colour the icon carries
      // survives the two seconds it spends saying "done".
      icon.setAttribute("class", original.replace(/\bbi-[\w-]+\b/, this.successIconValue))
      restore.push(() => { icon.setAttribute("class", original) })
    }

    // An icon button says nothing to a screen reader when its glyph changes, so
    // the accessible name carries the confirmation instead. `title` moves with
    // it: leaving the tooltip on "copy" while the accessible name says "copied"
    // is two different answers to the same question for those two seconds.
    if (this.hasButtonTarget && !this.hasButtonLabelTarget) {
      const button = this.buttonTarget
      for (const attribute of ["aria-label", "title"]) {
        const original = button.getAttribute(attribute)
        if (!original) continue

        button.setAttribute(attribute, this.successTextValue)
        restore.push(() => { button.setAttribute(attribute, original) })
      }
    }

    return restore
  }
}
