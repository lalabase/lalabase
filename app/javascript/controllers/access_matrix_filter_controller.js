import { Controller } from "@hotwired/stimulus"

// Client-side filter for the org access matrix: narrows visible ROWS by member name and
// visible COLUMNS by the project multiselect. Progressive enhancement — the full grid is
// server-rendered and fully usable without JS; this only hides non-matching rows/columns.
export default class extends Controller {
  static targets = ["search", "project", "row", "colhead", "cell"]
  static classes = ["hidden"]

  apply() {
    this.#applyRowFilter()
    this.#applyColumnFilter()
  }

  #applyRowFilter() {
    const term = (this.hasSearchTarget ? this.searchTarget.value : "").trim().toLowerCase()
    this.rowTargets.forEach((row) => {
      const name = row.dataset.userName || ""
      row.classList.toggle(this.hiddenClass, term !== "" && !name.includes(term))
    })
  }

  #applyColumnFilter() {
    const enabled = new Set(
      this.projectTargets.filter((box) => box.checked).map((box) => box.value)
    )
    const toggle = (el) => el.classList.toggle(this.hiddenClass, !enabled.has(el.dataset.projectId))
    this.colheadTargets.forEach(toggle)
    this.cellTargets.forEach(toggle)
  }
}
