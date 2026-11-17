import { Controller } from "@hotwired/stimulus"

// The ticks of the people list above the organisations and the bar that merges the ticked
// rows (all_people/_results). The page works without this controller: the checkboxes
// belong to the bar's form, the stylesheet shows the bar once a row is ticked, and the
// server refuses a merge of fewer than two rows. What is added here is what only the
// browser knows: which rows are chosen, also when they are out of sight.
//
// The search redraws the rows and the bar (they stand in the frame of the list), and two
// rows that are the same human are often found by two different searches. So the choice
// lives here, on the page around the frame, as value => name of every chosen row:
// - a row that comes back is ticked again;
// - the bar counts and names what is chosen, and shows while anything is, also when no
//   chosen row is in the list just now (the attribute on the element, read by the
//   stylesheet);
// - a merge sends every chosen row: the ones in the list through their ticks, the ones
//   out of sight as fields added to the form as it leaves.
// A full visit (another page of the list, another organisation) starts from nothing.
export default class extends Controller {
  static targets = ["tick", "counter", "count", "names", "submit", "carried"]

  initialize() {
    this.chosen = new Map()
  }

  connect() {
    this.show()
  }

  // A row drawn again: ticked when it is chosen.
  tickTargetConnected(tick) {
    tick.checked = this.chosen.has(tick.value)
  }

  // The bar drawn again with the rows.
  countTargetConnected() {
    this.show()
  }

  count(event) {
    const tick = event.target
    if (tick.checked) {
      this.chosen.set(tick.value, tick.dataset.name || "")
    } else {
      this.chosen.delete(tick.value)
    }
    this.show()
  }

  // The form of the bar leaves: the chosen rows the list does not show go along.
  carry(event) {
    this.removeCarried()
    const form = event.target
    const ticked = new Set(this.tickTargets.filter((tick) => tick.checked).map((tick) => tick.value))
    this.chosen.forEach((_name, value) => {
      if (ticked.has(value)) return

      const field = document.createElement("input")
      field.type = "hidden"
      field.name = "rows[]"
      field.value = value
      field.dataset.allPeopleMergeTarget = "carried"
      form.append(field)
    })
  }

  clear() {
    this.removeCarried()
    this.chosen.clear()
    this.tickTargets.forEach((tick) => { tick.checked = false })
    this.show()
  }

  // Turbo keeps the form after a network failure. Each attempt must contain only the
  // current selection, including when the user cleared or unticked rows since then.
  removeCarried() {
    this.carriedTargets.forEach((field) => field.remove())
  }

  show() {
    const number = this.chosen.size
    this.countTargets.forEach((element) => { element.textContent = number })
    this.namesTargets.forEach((element) => { element.textContent = [...this.chosen.values()].join(", ") })
    // The number and the names stay out of sight until somebody counts: without this
    // controller the bar says only what it does.
    this.counterTargets.forEach((element) => { element.hidden = false })
    this.submitTargets.forEach((button) => { button.disabled = number < 2 })
    this.element.toggleAttribute("data-all-people-merge-chosen", number > 0)
  }
}
