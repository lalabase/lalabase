import { Controller } from "@hotwired/stimulus"
import { dayCount } from "custom_period"

// The custom period of the time list's filter line: two dates, the span they
// describe, and the button that applies them.
//
// The count is rendered by the server as well, from the bounds actually in
// force, so without JavaScript the panel is complete and merely static: you
// type two dates, press "übernehmen", and the number is right again on the
// answer. This only keeps it honest WHILE typing.
//
// The two fields carry data-auto-submit-skip. A range is one decision made out
// of two controls, and submitting on the first of them applies a span half of
// which the reader has not chosen (see lib/auto_submit.js).
export default class extends Controller {
  static targets = ["start", "end", "days", "apply"]

  connect() {
    this.refresh()
  }

  refresh() {
    const days = dayCount(this.startTarget.value, this.endTarget.value)

    if (this.hasDaysTarget) {
      this.daysTarget.textContent = days === null ? "" : this.daysTarget.dataset.template.replace("%{count}", days)
    }

    // An end before its start is not a short range, it is no range: the server
    // would swap or ignore it and the reader would not know which. The button
    // says so before the request rather than after it.
    if (this.hasApplyTarget) this.applyTarget.disabled = days !== null && days < 1
  }
}
