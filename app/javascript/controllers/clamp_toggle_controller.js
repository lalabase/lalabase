import { Controller } from "@hotwired/stimulus"

// Clamps a long content block to a preview height and toggles the full view.
//
// Progressive enhancement: the server renders the content UNCLAMPED (so a no-JS user
// still gets the whole text) with the toggle button hidden; connect() applies the clamp
// class and reveals the button. Purely client-side — no server round-trip, no preference.
//
// Distinct from the neighbouring collapse-ish controllers, on purpose:
//   * `collapse`                    — toggles `hidden`, shows NO preview
//   * `reveal_more`                 — one-way DOM reveal, no re-collapse
//   * `ticket_description_collapse` — persists a user preference, hardcoded line-clamp-2
// The clamp is a CSS class handed in via the Stimulus classes API, so this controller is
// content-agnostic and reusable for any "preview then expand" block.
//
// Written for the meeting transcript; since Neo::MarkdownPreviewComponent it also drives
// saved analysis results and the ticket summary. The markup lives in that component now —
// reach for it rather than hand-wiring these targets again.
export default class extends Controller {
  static targets = ["content", "toggle", "moreLabel", "lessLabel"]
  static classes = ["clamped"]

  connect() {
    this.contentTarget.classList.add(this.clampedClass)

    // Nothing hidden → nothing to offer. A three-line summary used to get a
    // "weiterlesen" with nothing behind it, which is worse than no affordance at
    // all: it promises the reader something the click cannot deliver.
    if (this.#fitsUnclamped()) {
      this.contentTarget.classList.remove(this.clampedClass)
      return
    }

    this.toggleTarget.classList.remove("hidden")
    this.#syncLabels(true)
  }

  toggle() {
    const clamped = this.contentTarget.classList.toggle(this.clampedClass)
    this.#syncLabels(clamped)
  }

  // Measured WITH the clamp already applied: clientHeight is then the clamp height
  // (or the content height, if that is smaller) and scrollHeight the full one. The
  // 1px slack absorbs sub-pixel rounding on fractional line heights.
  //
  // A block that cannot be measured (clientHeight 0 — its lane is display:none at
  // connect, e.g. a side lane hidden on this viewport) answers false: clamp and
  // button both stay, which is what this controller did before the check existed.
  #fitsUnclamped() {
    const el = this.contentTarget
    if (el.clientHeight === 0) return false

    return el.scrollHeight <= el.clientHeight + 1
  }

  #syncLabels(clamped) {
    if (this.hasMoreLabelTarget) this.moreLabelTarget.classList.toggle("hidden", !clamped)
    if (this.hasLessLabelTarget) this.lessLabelTarget.classList.toggle("hidden", clamped)
  }
}
