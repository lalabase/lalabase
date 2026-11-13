import { Controller } from "@hotwired/stimulus"
import { redrawAddress } from "inbox_live"

// Gmail-style bulk select for the inbox master list.
//
// Connects a checkbox per notification item to an action bar over the tools
// row that shows "X selected · All · Mark as read · Archive · ×" as soon as at
// least one item is selected. The checkboxes show on hover (CSS); while the
// element carries `inbox-selecting` they show on every row: from the first
// tick on, and after "Auswählen" in the "···" menu, the way in on a phone,
// which has no hover. Existing single-item actions (click to the detail
// view) remain untouched — the checkbox only stops its own click, so that
// the enclosing link_to does not fire.
//
// Backend: extends the existing mark_all_read / archive_all routes with
// params[:ids][]. See doc/inbox_v1_plan.md PR-2.
//
// The same bar serves the inbox above the organisations (all_inboxes/index,
// followAddress), on routes that take a selection and nothing else. Two things
// differ there. The address of a submit carries the list state, read from the
// page's address when the form leaves. And a selection that crosses
// organisations is questioned first (number of rows, names of the
// organisations, from the ticked checkboxes).
export default class extends Controller {
  static targets = ["row", "checkbox", "bar", "count", "form"]
  static values  = { selectedIds: Array, followAddress: Boolean }

  connect() {
    this.selectedIdsValue = []
    this.selecting = false
    this.connected = true
    this._render()
  }

  disconnect() {
    this.connected = false
  }

  // The list is redrawn while a selection stands: every state change answers
  // with the whole list as a stream (the delayed mark-read of the open ticket
  // does so five seconds after a click), and the endless scroll adds rows.
  // The new checkboxes come unticked, while the selection lives on here: the
  // bar said "3 ausgewählt" over rows without a tick, and its forms kept the
  // ids of rows that had left the list. So after every change of the rows the
  // ticks are set from the selection, and the selection drops what is gone.
  checkboxTargetConnected() {
    this._reconcileSoon()
  }

  checkboxTargetDisconnected() {
    this._reconcileSoon()
  }

  // Once per redraw, after it: a stream takes every old row out and puts
  // every new one in, and each of them calls in here.
  _reconcileSoon() {
    if (!this.connected || this.reconcilePending) return
    this.reconcilePending = true
    Promise.resolve().then(() => {
      this.reconcilePending = false
      if (this.connected) this._reconcile()
    })
  }

  _reconcile() {
    const shown = new Set(this.checkboxTargets.map((cb) => cb.dataset.notificationId))
    const kept = this.selectedIdsValue.filter((id) => shown.has(id))
    if (kept.length !== this.selectedIdsValue.length) this.selectedIdsValue = kept
    const selected = new Set(kept)
    this.checkboxTargets.forEach((cb) => { cb.checked = selected.has(cb.dataset.notificationId) })
    this._render()
  }

  // "Auswählen" in the "···" menu: show every checkbox without ticking one,
  // and close the menu it was chosen from. The menu item leaves the
  // rendering with the menu, so focus moves on to the first checkbox.
  startSelecting(event) {
    event?.target?.closest("details")?.removeAttribute("open")
    this.selecting = true
    this._render()
    this.checkboxTargets[0]?.focus()
  }

  // "Alle" in the bulk bar: tick every row the list shows.
  selectAll() {
    const ids = []
    this.checkboxTargets.forEach((cb) => {
      cb.checked = true
      if (cb.dataset.notificationId) ids.push(cb.dataset.notificationId)
    })
    this.selectedIdsValue = Array.from(new Set(ids))
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

  // The way out. Focus that sat in the bar would be lost with it, so it goes
  // back to the "···" trigger of the head the mode was entered from (a
  // summary in the head: the "?" beside it wears the same class as a button,
  // and every row has a "···" of its own).
  clear() {
    if (this.hasBarTarget && this.barTarget.contains(document.activeElement)) {
      this.element.querySelector(".people-head summary.more-menu__trigger")?.focus()
    }
    this.checkboxTargets.forEach((cb) => { cb.checked = false })
    this.selectedIdsValue = []
    this.selecting = false
    this._render()
  }

  // ⚠️ Without ids, mark_all_read and archive_all act on EVERY notification.
  // The buttons are disabled while nothing is ticked, but Turbo re-enables a
  // submitter once its request has ended, so a submit that would leave
  // without ids is stopped here, whatever the buttons say.
  guardSubmit(event) {
    if (this.selectedIdsValue.length === 0) {
      event.preventDefault()
      return
    }
    const form = event.target
    if (!form) return
    if (this.followAddressValue) this._carryListState(form)
    this._question(form, event.params?.confirm)
  }

  // The bar lies outside the list and outside the frame the search reloads,
  // so an address written into its forms can be older than the list below.
  // The answer redraws the list from the address of the action: it takes the
  // state the page's address names now and the pages the endless scroll has
  // loaded, the rule of the live redraw (lib/inbox_live).
  _carryListState(form) {
    const list = document.getElementById("inbox_master_list")
    form.action = redrawAddress(window.location.href, {
      path: new URL(form.action, window.location.origin).pathname,
      firstPage: list?.dataset.neoEndlessScrollFirstPageValue,
      throughPage: list?.dataset.neoEndlessScrollPageValue
    })
  }

  // Across organisations Turbo asks before the form leaves: this runs on the
  // form, before Turbo reads data-turbo-confirm from it. Within one
  // organisation no question, as the inbox of an organisation acts.
  _question(form, template) {
    const names = this._selectedOrganisations()
    if (!template || names.length < 2) {
      delete form.dataset.turboConfirm
      return
    }
    form.dataset.turboConfirm = template
      .replace("{number}", this.selectedIdsValue.length)
      .replace("{organisations}", this._sentence(names))
  }

  // The names of the organisations the ticked rows belong to, each
  // organisation once (two can share a name). Empty inside an organisation,
  // where a row names none.
  _selectedOrganisations() {
    const selected = new Set(this.selectedIdsValue)
    const names = new Map()
    this.checkboxTargets.forEach((cb) => {
      const { notificationId, organisationId, organisationName } = cb.dataset
      if (selected.has(notificationId) && organisationId && organisationName) names.set(organisationId, organisationName)
    })
    return Array.from(names.values())
  }

  // "A, B und C" in the language of the page.
  _sentence(names) {
    if (typeof Intl === "undefined" || !Intl.ListFormat) return names.join(", ")
    return new Intl.ListFormat(document.documentElement.lang || undefined, { style: "long", type: "conjunction" }).format(names)
  }

  // After a bulk submit (mark_all_read / archive_all): a success clears the
  // selection, so that the bar no longer says "3 selected" over rows that
  // have left the list; a failure redraws the bar, so that the buttons show
  // the state of the selection again (Turbo re-enabled the submitter).
  onBulkSubmit(event) {
    if (event?.detail?.success === false) {
      this._render()
      return
    }
    this.clear()
  }

  _render() {
    const count = this.selectedIdsValue.length
    const selecting = this.selecting || count > 0
    this.element.classList.toggle("inbox-selecting", selecting)
    if (this.hasBarTarget) {
      this.barTarget.classList.toggle("hidden", !selecting)
    }
    if (this.hasCountTarget) {
      this.countTarget.textContent = count
    }
    // ⚠️ Without ids, mark_all_read and archive_all act on EVERY notification:
    // the bar is open in selection mode before anything is ticked, so its
    // actions stay disabled until a row is.
    this.formTargets.forEach((form) => {
      form.querySelectorAll('button[type="submit"]').forEach((button) => { button.disabled = count === 0 })
    })
    this._syncHiddenInputs()
    this._highlightRows()
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
      row.classList.toggle("inbox-row--checked", selected.has(id))
    })
  }
}
