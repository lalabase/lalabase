import { Controller } from "@hotwired/stimulus"

// Gmail-style bulk select for the inbox master list.
//
// Connects a checkbox per notification item to a sticky action bar that
// shows "X selected · Mark as read · Archive · Cancel" as soon as at least
// one item is selected. Existing single-item actions (click to the detail
// view) remain untouched — the checkbox only stops its own click, so that
// the enclosing link_to does not fire.
//
// Backend: extends the existing mark_all_read / archive_all routes with
// params[:ids][]. See doc/inbox_v1_plan.md PR-2.
export default class extends Controller {
  static targets = ["row", "checkbox", "bar", "count", "selectAll", "form"]
  static values  = { selectedIds: Array }

  connect() {
    this.selectedIdsValue = []
    this._render()
  }

  toggle(event) {
    const id = event.target.dataset.notificationId
    if (!id) return
    const current = new Set(this.selectedIdsValue)
    if (event.target.checked) {
      current.add(id)
    } else {
      current.delete(id)
    }
    this.selectedIdsValue = Array.from(current)
    this._render()
  }

  // Prevents a click on the checkbox from triggering the enclosing link.
  stopRowClick(event) {
    event.stopPropagation()
  }

  toggleAll(event) {
    const checked = event.target.checked
    const ids = new Set()
    this.checkboxTargets.forEach((cb) => {
      cb.checked = checked
      if (checked && cb.dataset.notificationId) {
        ids.add(cb.dataset.notificationId)
      }
    })
    this.selectedIdsValue = checked ? Array.from(ids) : []
    this._render()
  }

  clear() {
    this.checkboxTargets.forEach((cb) => { cb.checked = false })
    this.selectedIdsValue = []
    if (this.hasSelectAllTarget) this.selectAllTarget.checked = false
    this._render()
  }

  // After a successful bulk submit (mark_all_read / archive_all): clear the
  // selection, so that the action bar disappears and no longer shows
  // "3 selected" even though the items have since left the list.
  onBulkSubmit(event) {
    if (event?.detail?.success === false) return
    this.clear()
  }

  _render() {
    const count = this.selectedIdsValue.length
    if (this.hasBarTarget) {
      this.barTarget.classList.toggle("hidden", count === 0)
    }
    if (this.hasCountTarget) {
      this.countTarget.textContent = count
    }
    this._syncSelectAll(count)
    this._syncHiddenInputs()
    this._highlightRows()
  }

  // Select-all checkbox mirrors the selection state: empty / partial
  // (indeterminate) / all.
  _syncSelectAll(count) {
    if (!this.hasSelectAllTarget) return
    const total = this.checkboxTargets.length
    this.selectAllTarget.checked = count > 0 && count === total
    this.selectAllTarget.indeterminate = count > 0 && count < total
  }

  // Writes the selected IDs as hidden inputs into all bulk action forms,
  // so that submit sends the correct IDs.
  _syncHiddenInputs() {
    this.formTargets.forEach((form) => {
      // Remove previously existing ids[] inputs
      form.querySelectorAll('input[data-bulk-id="true"]').forEach((el) => el.remove())
      this.selectedIdsValue.forEach((id) => {
        const input = document.createElement("input")
        input.type = "hidden"
        input.name = "ids[]"
        input.value = id
        input.dataset.bulkId = "true"
        form.appendChild(input)
      })
    })
  }

  _highlightRows() {
    const selected = new Set(this.selectedIdsValue)
    this.rowTargets.forEach((row) => {
      const id = row.dataset.notificationId
      // Warm-Editorial: bulk selection = warm value step (cream-200), no yellow (Part G).
      row.classList.toggle("bg-cream-200", selected.has(id))
    })
  }
}
