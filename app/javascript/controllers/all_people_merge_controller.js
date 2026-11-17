import { Controller } from "@hotwired/stimulus"

// The ticks of the people list above the organisations and the bar that merges the ticked
// rows (all_people/_results). The page works without this controller: the checkboxes
// belong to the bar's form, the stylesheet shows the bar once a row is ticked, and the
// server refuses a merge of fewer than two rows. What is added here is what only the
// browser knows: how many rows are ticked, a button that waits for the second one, and
// the way out.
//
// The search redraws the rows, and new rows come unticked: every row that comes or goes
// counts again.
export default class extends Controller {
  static targets = ["tick", "counter", "count", "submit"]

  connect() {
    this.count()
  }

  tickTargetConnected() {
    this.count()
  }

  tickTargetDisconnected() {
    this.count()
  }

  count() {
    const ticked = this.tickTargets.filter((tick) => tick.checked).length
    this.countTargets.forEach((element) => { element.textContent = ticked })
    // The number stays out of sight until somebody counts: without this controller the
    // bar says only what it does.
    this.counterTargets.forEach((element) => { element.hidden = false })
    this.submitTargets.forEach((button) => { button.disabled = ticked < 2 })
  }

  clear() {
    this.tickTargets.forEach((tick) => { tick.checked = false })
    this.count()
  }
}
