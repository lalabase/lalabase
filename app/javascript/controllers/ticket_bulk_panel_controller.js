import { Controller } from "@hotwired/stimulus"
import { TicketBulkDraft } from "ticket_bulk_draft"
import { listPosition, namesToList, newTagOffer } from "new_tag_name"

// The bulk panel in the lane (doc/ticket_bulk_edit_plan.md, slices 3 and 4).
// The shell is server rendered once; this controller adds and removes the
// change rows, writes every number, and talks to the selection controller only
// over window events, because the two live in different frames: the selection
// around the list, the panel in the lane.
//
// On connect it says "ready", the selection answers with its state and the
// draft it kept while a ticket had the lane; every later change of the
// selection arrives the same way. Every change of the draft goes back the
// same way, so the draft survives the next turn. The stock lines come from
// GET bulk_summary, fetched after every change of the selection: the number
// of tickets that already carry a value is the basis of the decision, and it
// is never a constant.
//
// Slice 5: the multi-valued kinds (tags, people, a multiselect). One row
// holds both plus and minus, because it is one field: a chip "+ Backend" sets
// the value on every selected ticket, "− Doku" removes it from every one, and
// the layer behind "+ Tag" lists every value with a three-state box (nobody,
// some, all of the selected carry it) that one click turns to all and the
// next to none. A date can also be cleared ("kein Datum").
//
// Slice 7: the other actions under the button, each with its own dialog. A
// move asks for the target and names what the move takes with it, a delete
// names what goes with the tickets (D15), both counted from the live
// selection by POST bulk_impact. Both answer like a run, with a result line;
// the tickets have left the list, so the selection is cleared ("done" with
// clear).
export default class extends Controller {
  static targets = [
    "title", "executeLabel", "execute", "cancel", "summary", "changes",
    "picker", "pickerButton", "pickerMenu", "pickerSearch", "pickerEmpty", "pickerOption", "rowTemplate",
    "other", "moveLabel", "deleteLabel",
    "moveDialog", "moveTitle", "moveTarget", "moveImpact", "moveConfirm", "moveConfirmLabel",
    "deleteDialog", "deleteTitle", "deleteImpact", "deleteConfirm", "deleteConfirmLabel"
  ]
  static values = {
    summaryUrl: String,
    updateUrl: String,
    impactUrl: String,
    moveUrl: String,
    destroyUrl: String,
    texts: Object,
    summaryDelay: { type: Number, default: 250 }
  }

  connect() {
    this.draft = new TicketBulkDraft([], this.fieldOrder)
    this.state = { count: 0, mode: "ids", ids: [], total: 0 }
    this.summary = null
    this.dispatch("ready")
  }

  disconnect() {
    if (this._summaryTimer) clearTimeout(this._summaryTimer)
    this._abort?.abort()
    this._impactAbort?.abort()
  }

  // The selection's state: { count, mode, ids, total, draft }. A draft that
  // arrives into an empty panel is the one kept across the turn; it is
  // rebuilt row by row.
  update(event) {
    const detail = event.detail || {}
    this.state = {
      count: Number(detail.count) || 0,
      mode: detail.mode || "ids",
      ids: Array.isArray(detail.ids) ? detail.ids : [],
      total: Number(detail.total) || 0
    }
    if (this.draft.isEmpty() && Array.isArray(detail.draft) && detail.draft.length > 0) {
      this.draft = TicketBulkDraft.from(detail.draft, this.fieldOrder)
      this.renderRows()
    }
    this.renderHead()
    this.renderFoot()
    this.scheduleSummary()
  }

  close() {
    this.dispatch("close")
  }

  // --- the run ------------------------------------------------------------

  // Nothing acts before this. The selection, the list's address (for "all"),
  // the draft and the stock digests the reader decided on go to the server as
  // JSON; the answer is a Turbo stream that re-renders the list and writes
  // the result line. On success the draft is gone and the selection controller
  // takes over the changed ids; a refusal leaves the draft and refreshes the
  // stock, so the reader can look and press again.
  runTicketIds(html) {
    const doc = new DOMParser().parseFromString(html, "text/html")
    const line = [...doc.querySelectorAll("turbo-stream template")]
      .map((template) => template.content.querySelector("[data-run-ticket-ids]"))
      .find(Boolean)
    return (line?.dataset.runTicketIds || "").split(",").filter(Boolean)
  }

  // The address of the list without its paging, so mode "all" means the same
  // set the table shows; the selection as the server resolves it.
  addressed(path) {
    const url = new URL(path, window.location.origin)
    const address = new URLSearchParams(window.location.search)
    ;["page", "items", "ticket_id"].forEach((key) => address.delete(key))
    address.forEach((value, key) => url.searchParams.append(key, value))
    // Turbo can render the mobile list from X-Viewport without changing the
    // address. These plain fetch requests must carry that presentation too.
    if (this.element.closest('[data-ticket-selection-mobile-value="true"]')) {
      url.searchParams.set("viewport", "mobile")
    }
    return url
  }

  get selectionPayload() {
    const selection = { mode: this.state.mode }
    if (this.state.mode === "all") selection.expected_count = this.state.total
    else selection.ids = this.state.ids
    return selection
  }

  jsonRequest(method, body, accept, signal = undefined) {
    return {
      method,
      credentials: "same-origin",
      signal,
      headers: {
        "Content-Type": "application/json",
        Accept: accept,
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
      },
      body: JSON.stringify(body)
    }
  }

  // Only the rows that say something go: a row without a value is no change
  // (designer, 08.09.2026), and the server would refuse an empty value anyway.
  async execute() {
    if (!this.hasUpdateUrlValue || this.executeTarget.disabled || this._running) return
    this._running = true
    this.executeTarget.disabled = true

    const url = this.addressed(this.updateUrlValue)
    const selection = this.selectionPayload
    const changes = this.draft.serialize(true)
    const stock = {}
    changes.forEach((entry) => {
      const digest = this.summary?.fields?.[entry.field]?.digest
      if (digest) stock[entry.field] = digest
    })

    try {
      const response = await fetch(url, this.jsonRequest("PATCH", { selection, changes, stock }, "text/vnd.turbo-stream.html"))
      const html = await response.text()
      if (html) window.Turbo.renderStreamMessage(html)
      if (response.ok) {
        this.listCreatedValues(changes)
        this.draft = new TicketBulkDraft([], this.fieldOrder)
        this.changesTarget.replaceChildren()
        // Turbo applies the streams on the next repaint, so the run's ticket
        // ids are read from the answer itself, not from the page.
        const ids = this.runTicketIds(html)
        this.dispatch("draft", { detail: { draft: [] } })
        this.dispatch("done", { detail: { ids } })
      } else {
        this.scheduleSummary()
      }
    } finally {
      this._running = false
      this.renderFoot()
    }
  }

  // A run that gave a tag nobody had made has made it: the field's template
  // lists it from now on like any other, so the next row offers it as a tag
  // to set or take off, not as a new one (review of #926). Only fields that
  // take new values carry the prototype.
  listCreatedValues(changes) {
    changes.forEach((entry) => {
      const template = this.templateFor(entry.field)
      const prototype = template?.content.querySelector("[data-option-prototype]")
      if (!prototype || !entry.add?.length) return
      const listbox = template.content.querySelector('[role="listbox"]')
      namesToList(this.listedValues(listbox), entry.add).forEach((name) => {
        const option = prototype.content.firstElementChild.cloneNode(true)
        Object.assign(option.dataset, { value: name, label: name, search: name })
        option.querySelector("[data-option-label]").textContent = name
        const listed = this.listedValues(listbox)
        listbox.insertBefore(option, listbox.querySelectorAll(".tbp-option")[listPosition(listed, name)] || null)
      })
    })
  }

  listedValues(listbox) {
    return [...listbox.querySelectorAll(".tbp-option")].map((option) => option.dataset.value)
  }

  // --- the other actions (slice 7) ----------------------------------------

  openMove() {
    if (this.state.count === 0 || !this.hasMoveDialogTarget) return
    this.closePicker()
    this.moveTitleTarget.textContent = this.plural(this.textsValue.move?.title, this.state.count)
    if (this.hasMoveTargetTarget) this.moveTargetTarget.value = ""
    if (this.hasMoveImpactTarget) this.moveImpactTarget.textContent = ""
    if (this.hasMoveConfirmTarget) {
      this.moveConfirmTarget.disabled = true
      this.moveConfirmLabelTarget.textContent = this.plural(this.textsValue.move?.confirm, this.state.count)
    }
    this.moveDialogTarget.showModal()
    if (this.hasMoveTargetTarget) this.moveTargetTarget.focus()
  }

  // The target is chosen: what the move takes with it, then the button.
  async targetChanged() {
    const target = this.moveTargetTarget.value
    this.moveConfirmTarget.disabled = true
    if (!target) {
      this.moveImpactTarget.textContent = ""
      return
    }
    const texts = this.textsValue.move || {}
    this.moveImpactTarget.textContent = texts.pending || ""
    const impact = await this.fetchImpact(target)
    if (this.moveTargetTarget.value !== target) return
    this.moveImpactTarget.textContent = impact ? this.moveImpactText(impact, texts) : (texts.failed || "")
    this.moveConfirmTarget.disabled = false
  }

  moveImpactText(impact, texts) {
    const parts = []
    const move = impact.move || {}
    if (move.lost_assignments > 0) parts.push(this.plural(texts.lost_assignments, move.lost_assignments))
    if (move.lost_subscriptions > 0) parts.push(this.plural(texts.lost_subscriptions, move.lost_subscriptions))
    if (impact.time_sessions > 0) parts.push(this.plural(texts.time_sessions, impact.time_sessions))
    if (impact.hierarchy > 0) parts.push(this.plural(texts.hierarchy, impact.hierarchy))
    if (parts.length === 0) parts.push(texts.clean || "")
    return parts.join(" ")
  }

  async openDelete() {
    if (this.state.count === 0 || !this.hasDeleteDialogTarget) return
    this.closePicker()
    const texts = this.textsValue.delete || {}
    this.deleteTitleTarget.textContent = this.plural(texts.title, this.state.count)
    this.deleteConfirmLabelTarget.textContent = this.plural(texts.confirm, this.state.count)
    this.deleteConfirmTarget.disabled = true
    this.deleteImpactTarget.textContent = texts.pending || ""
    this.deleteDialogTarget.showModal()
    const impact = await this.fetchImpact(null)
    if (!this.deleteDialogTarget.open) return
    this.deleteImpactTarget.textContent = impact ? this.deleteImpactText(impact, texts) : (texts.failed || "")
    this.deleteConfirmTarget.disabled = false
  }

  // What goes with the tickets, what stays behind without them (D15).
  deleteImpactText(impact, texts) {
    const parts = []
    if (impact.posts > 0) parts.push(this.plural(texts.posts, impact.posts))
    if (impact.documents > 0) parts.push(this.plural(texts.documents, impact.documents))
    if (impact.time_sessions > 0) parts.push(this.plural(texts.time_sessions, impact.time_sessions))
    if (impact.children > 0) parts.push(this.plural(texts.children, impact.children))
    if (parts.length === 0) parts.push(texts.clean || "")
    return parts.join(" ")
  }

  async fetchImpact(targetProjectId) {
    if (!this.hasImpactUrlValue) return null
    this._impactAbort?.abort()
    const abort = new AbortController()
    this._impactAbort = abort
    const body = { selection: this.selectionPayload }
    if (targetProjectId) body.target_project_id = targetProjectId
    try {
      const response = await fetch(this.addressed(this.impactUrlValue), this.jsonRequest("POST", body, "application/json", abort.signal))
      return response.ok ? await response.json() : null
    } catch {
      return null
    }
  }

  confirmMove() {
    if (!this.hasMoveUrlValue || this.moveConfirmTarget.disabled) return
    this.runAction(this.moveUrlValue, "POST", { target_project_id: this.moveTargetTarget.value }, this.moveConfirmTarget)
  }

  confirmDelete() {
    if (!this.hasDestroyUrlValue || this.deleteConfirmTarget.disabled) return
    this.runAction(this.destroyUrlValue, "DELETE", {}, this.deleteConfirmTarget)
  }

  // A move or a delete answers like a run: the stream re-renders the list and
  // writes the result line. The tickets have left this list either way, so
  // the selection is cleared, whatever the outcome per ticket.
  async runAction(path, method, extra, button) {
    if (this._running) return
    this._running = true
    button.disabled = true
    try {
      const response = await fetch(this.addressed(path), this.jsonRequest(method, { selection: this.selectionPayload, ...extra }, "text/vnd.turbo-stream.html"))
      const html = await response.text()
      this.closeDialogs()
      if (html) window.Turbo.renderStreamMessage(html)
      if (response.ok) {
        this.draft = new TicketBulkDraft([], this.fieldOrder)
        this.changesTarget.replaceChildren()
        this.dispatch("draft", { detail: { draft: [] } })
        this.dispatch("done", { detail: { ids: [], clear: true } })
      }
    } finally {
      this._running = false
      button.disabled = false
      this.renderFoot()
    }
  }

  closeDialogs() {
    if (this.hasMoveDialogTarget && this.moveDialogTarget.open) this.moveDialogTarget.close()
    if (this.hasDeleteDialogTarget && this.deleteDialogTarget.open) this.deleteDialogTarget.close()
  }

  // --- the picker ---------------------------------------------------------

  togglePicker() {
    if (this.pickerMenuTarget.hidden) this.openPicker()
    else this.closePicker()
  }

  openPicker() {
    this.filterPicker()
    this.pickerMenuTarget.hidden = false
    this.pickerButtonTarget.setAttribute("aria-expanded", "true")
    if (this.hasPickerSearchTarget) this.pickerSearchTarget.focus()
  }

  closePicker() {
    if (this.pickerMenuTarget.hidden) return
    this.pickerMenuTarget.hidden = true
    this.pickerButtonTarget.setAttribute("aria-expanded", "false")
    if (this.hasPickerSearchTarget) this.pickerSearchTarget.value = ""
  }

  // Escape closes what is open: a layer (values or options) first, then the picker.
  closePickerOnEscape(event) {
    if (event.key !== "Escape") return
    const layer = this.openedLayer
    if (layer) {
      this.closeLayer(layer, { focus: true })
      return
    }
    if (this.pickerMenuTarget.hidden) return
    this.closePicker()
    this.pickerButtonTarget.focus()
  }

  closePickerOutside(event) {
    const layer = this.openedLayer
    if (layer && !layer.closest("[data-multi], [data-single]").contains(event.target)) this.closeLayer(layer)
    if (this.pickerMenuTarget.hidden || this.pickerTarget.contains(event.target)) return
    this.closePicker()
  }

  // Fields already in the draft leave the list; the search narrows the rest;
  // a group without a visible field hides with its heading.
  filterPicker() {
    const query = (this.hasPickerSearchTarget ? this.pickerSearchTarget.value : "").trim().toLowerCase()
    let shown = 0
    this.pickerOptionTargets.forEach((option) => {
      const hidden = this.draft.has(option.dataset.field) || (query !== "" && !option.dataset.label.includes(query))
      option.hidden = hidden
      if (!hidden) shown += 1
    })
    this.pickerMenuTarget.querySelectorAll("[data-picker-group]").forEach((group) => {
      group.hidden = ![...group.querySelectorAll("[data-picker-option]")].some((option) => !option.hidden)
    })
    if (this.hasPickerEmptyTarget) this.pickerEmptyTarget.hidden = shown > 0
  }

  // --- the rows -----------------------------------------------------------

  // The row takes the field's place in the fixed order, so the rows already
  // there never jump.
  addField(event) {
    const field = event.currentTarget.dataset.field
    const template = this.templateFor(field)
    if (!template || !this.draft.add(field, template.dataset.kind)) return

    const row = this.appendRow(template, null, this.draft.indexOf(field))
    this.closePicker()
    this.draftChanged()
    row.querySelector(".tbp-control, .tbp-select")?.focus()
  }

  // The catalogue's order, as the templates are rendered (the same order the
  // picker lists and the ticket's attribute line keeps).
  get fieldOrder() {
    return this.rowTemplateTargets.map((template) => template.dataset.field)
  }

  removeField(event) {
    const field = event.currentTarget.dataset.field
    if (!this.draft.remove(field)) return
    this.rowFor(field)?.remove()
    this.draftChanged()
  }

  setValue(event) {
    const control = event.currentTarget
    const row = control.closest(".ticket-bulk-row")
    if (!row) return
    this.draft.setValue(row.dataset.field, control.value)
    this.renderClear(row)
    this.draftChanged()
  }

  // "kein Datum": the date is removed from every selected ticket. Pressed
  // again, the field is back and empty.
  toggleClear(event) {
    const row = event.currentTarget.closest(".ticket-bulk-row")
    if (!row) return
    const entry = this.draft.get(row.dataset.field)
    if (!entry) return
    this.draft.setClear(row.dataset.field, !entry.clear)
    const control = row.querySelector(".tbp-control")
    if (control && entry.clear) control.value = ""
    this.renderClear(row)
    this.draftChanged()
  }

  renderClear(row) {
    const word = row.querySelector("[data-clear-date]")
    if (!word) return
    const entry = this.draft.get(row.dataset.field)
    const clear = Boolean(entry?.clear)
    word.setAttribute("aria-pressed", String(clear))
    const control = row.querySelector(".tbp-control")
    if (control) control.disabled = clear
  }

  // --- the single-valued rows: the panel's own dropdown ---------------------

  toggleSelect(event) {
    const button = event.currentTarget
    const layer = button.closest("[data-single]").querySelector("[data-select-layer]")
    if (layer.hidden) this.openLayer(layer, button)
    else this.closeLayer(layer)
  }

  // An option chosen: the word on the button, the value in the draft.
  chooseOption(event) {
    const option = event.currentTarget
    const row = option.closest(".ticket-bulk-row")
    this.draft.setValue(row.dataset.field, option.dataset.value)
    this.renderSelect(row, option.dataset.value)
    this.closeLayer(option.closest("[data-select-layer]"), { focus: true })
    this.draftChanged()
  }

  renderSelect(row, value) {
    const single = row.querySelector("[data-single]")
    if (!single) return
    const button = single.querySelector(".tbp-select")
    const label = single.querySelector("[data-select-label]")
    const chosen = [...single.querySelectorAll(".tbp-option")].find((option) => option.dataset.value === String(value))
    single.querySelectorAll(".tbp-option").forEach((option) => option.setAttribute("aria-selected", String(option === chosen)))
    button.dataset.value = chosen ? chosen.dataset.value : ""
    label.textContent = chosen ? chosen.dataset.label : (this.textsValue.choose_value || label.dataset.placeholder || label.textContent)
  }

  // --- the multi-valued rows ----------------------------------------------

  toggleValues(event) {
    const button = event.currentTarget
    const layer = button.closest("[data-multi]").querySelector("[data-values-layer]")
    if (layer.hidden) this.openLayer(layer, button)
    else this.closeLayer(layer)
  }

  // One layer at a time, values or options: the other closes, the picker too.
  openLayer(layer, button) {
    const open = this.openedLayer
    if (open && open !== layer) this.closeLayer(open)
    this.closePicker()
    if (layer.hasAttribute("data-values-layer")) this.renderMulti(layer.closest(".ticket-bulk-row"))
    layer.hidden = false
    button.setAttribute("aria-expanded", "true")
    const first = layer.querySelector(".tbp-search") || layer.querySelector('.tbp-option[aria-selected="true"]') || layer.querySelector(".tbp-option")
    first?.focus()
  }

  closeLayer(layer, { focus = false } = {}) {
    layer.hidden = true
    const search = layer.querySelector(".tbp-search")
    if (search) search.value = ""
    layer.querySelectorAll(".tbp-option").forEach((option) => { option.hidden = false })
    layer.querySelectorAll("[data-new-value], [data-new-invalid]").forEach((line) => { line.hidden = true })
    const button = layer.closest("[data-multi], [data-single]").querySelector(".tbp-add-value, .tbp-select")
    button.setAttribute("aria-expanded", "false")
    if (focus) button.focus()
  }

  // The one layer that stands open, if any.
  get openedLayer() {
    return this.changesTarget.querySelector("[data-values-layer]:not([hidden]), [data-select-layer]:not([hidden])")
  }

  filterValues(event) {
    const layer = event.currentTarget.closest("[data-values-layer]")
    const query = event.currentTarget.value.trim().toLowerCase()
    let shown = 0
    layer.querySelectorAll(".tbp-option").forEach((option) => {
      const hidden = query !== "" && !option.dataset.search.includes(query)
      option.hidden = hidden
      if (!hidden) shown += 1
    })
    const offer = this.renderNewValue(layer, event.currentTarget.value)
    const empty = layer.querySelector("[data-values-empty]")
    if (empty) empty.hidden = shown > 0 || offer?.state === "new" || offer?.state === "invalid"
  }

  // The tags layer offers the typed name as a new tag once no tag carries it;
  // a name the server would refuse gets the rule instead. Returns the offer
  // (null where the layer takes no new values).
  renderNewValue(layer, query) {
    const button = layer.querySelector("[data-new-value]")
    if (!button) return null
    const invalid = layer.querySelector("[data-new-invalid]")
    const row = layer.closest(".ticket-bulk-row")
    const existing = [...layer.querySelectorAll(".tbp-option")].map((option) => option.dataset.value)
      .concat(this.draft.get(row.dataset.field)?.add || [])
    const offer = newTagOffer(query, {
      existing, maxLength: Number(button.dataset.maxLength), separator: button.dataset.separator
    })
    button.hidden = offer.state !== "new"
    invalid.hidden = offer.state !== "invalid"
    button.querySelector("[data-new-label]").textContent = button.dataset.template.replace("%{name}", offer.name)
    return offer
  }

  // The offered new tag joins the change as a plus; the run creates it. The
  // offer is worked out again from what the search holds NOW: a name typed,
  // left and the layer reopened must not ride in on an Enter in an empty
  // field (review of #926). The search empties and keeps the focus.
  addNewValue(event) {
    const layer = event.currentTarget.closest("[data-values-layer]")
    const search = layer.querySelector(".tbp-search")
    const offer = this.renderNewValue(layer, search.value)
    if (offer?.state !== "new") return
    const row = layer.closest(".ticket-bulk-row")
    this.draft.addValue(row.dataset.field, offer.name)
    search.value = ""
    search.dispatchEvent(new Event("input"))
    search.focus()
    this.renderMulti(row)
    this.draftChanged()
  }

  // One click turns the value to "all of them", the next to "none of them",
  // against what the selected tickets carry today: adding what everyone has
  // and removing what nobody has is no change and leaves the draft alone.
  cycleValue(event) {
    const option = event.currentTarget
    const row = option.closest(".ticket-bulk-row")
    const field = row.dataset.field
    const value = option.dataset.value
    const stock = this.stockState(field, value)
    const result = this.resultState(field, value, stock)
    if (result === "all") {
      if (stock === "none") this.draft.clearValue(field, value)
      else this.draft.removeValue(field, value)
    } else if (stock === "all") {
      this.draft.clearValue(field, value)
    } else {
      this.draft.addValue(field, value)
    }
    this.renderMulti(row)
    this.draftChanged()
  }

  // A chip: the value leaves the change.
  dropValue(event) {
    const chip = event.currentTarget
    const row = chip.closest(".ticket-bulk-row")
    this.draft.clearValue(row.dataset.field, chip.dataset.value)
    this.renderMulti(row)
    this.draftChanged()
  }

  // How many of the selected carry the value today: "none", "some", "all".
  stockState(field, value) {
    const count = this.stockCount(field, value)
    const total = Number(this.summary?.count) || 0
    if (count <= 0) return "none"
    return count >= total ? "all" : "some"
  }

  stockCount(field, value) {
    const values = this.summary?.fields?.[field]?.values || []
    return Number(values.find((entry) => String(entry.value) === String(value))?.count) || 0
  }

  // What the value's state will be after the run: the draft's word, else the stock.
  resultState(field, value, stock = this.stockState(field, value)) {
    const word = this.draft.valueState(field, value)
    if (word === "add") return "all"
    if (word === "remove") return "none"
    return stock
  }

  renderMulti(row) {
    const entry = this.draft.get(row.dataset.field)
    if (!entry || entry.kind !== "multi") return
    const labels = this.optionLabels(row)
    const chips = row.querySelector("[data-chips]")
    const removeLabel = this.templateFor(row.dataset.field)?.dataset.removeLabel || ""
    chips.replaceChildren()
    const chip = (value, sign, kind) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className = `tbp-chip tbp-chip--${kind}`
      button.dataset.value = value
      button.dataset.action = "click->ticket-bulk-panel#dropValue"
      button.title = removeLabel
      button.textContent = `${sign} ${labels.get(value) || value}`
      chips.appendChild(button)
    }
    entry.add.forEach((value) => chip(value, "+", "add"))
    entry.remove.forEach((value) => chip(value, "\u2212", "remove"))

    row.querySelectorAll(".tbp-option").forEach((option) => {
      const value = option.dataset.value
      const box = option.querySelector("[data-tri]")
      const state = this.resultState(row.dataset.field, value)
      box.classList.toggle("is-all", state === "all")
      box.classList.toggle("is-some", state === "some")
      option.setAttribute("aria-selected", String(state === "all"))
      const count = this.stockCount(row.dataset.field, value)
      const counter = option.querySelector("[data-count]")
      if (counter) counter.textContent = count > 0 ? this.number(count) : ""
    })
  }

  optionLabels(row) {
    const map = new Map()
    row.querySelectorAll(".tbp-option").forEach((option) => map.set(option.dataset.value, option.dataset.label))
    return map
  }

  // "Abbrechen": the draft goes, the selection stays.
  discard() {
    this.draft = new TicketBulkDraft([], this.fieldOrder)
    this.changesTarget.replaceChildren()
    this.draftChanged()
  }

  draftChanged() {
    this.renderFoot()
    this.renderStock()
    this.dispatch("draft", { detail: { draft: this.draft.serialize() } })
  }

  renderRows() {
    this.changesTarget.replaceChildren()
    this.draft.entries.forEach((entry) => {
      const template = this.templateFor(entry.field)
      if (template) this.appendRow(template, entry.value)
    })
    this.renderStock()
  }

  appendRow(template, value, index = -1) {
    const row = template.content.firstElementChild.cloneNode(true)
    const control = row.querySelector(".tbp-control")
    if (control && value !== null && value !== undefined) control.value = String(value)
    if (value !== null && value !== undefined) this.renderSelect(row, value)
    const before = index >= 0 ? this.rows[index] : null
    if (before) this.changesTarget.insertBefore(row, before)
    else this.changesTarget.appendChild(row)
    this.renderClear(row)
    this.renderMulti(row)
    return row
  }

  templateFor(field) {
    return this.rowTemplateTargets.find((template) => template.dataset.field === field) || null
  }

  // The row, not its ✕ (which carries the field too).
  rowFor(field) {
    return this.changesTarget.querySelector(`.ticket-bulk-row[data-field="${CSS.escape(field)}"]`)
  }

  get rows() {
    return [...this.changesTarget.querySelectorAll(".ticket-bulk-row")]
  }

  // --- head and foot ------------------------------------------------------

  renderHead() {
    if (this.hasTitleTarget) this.titleTarget.textContent = this.plural(this.textsValue.title, this.state.count)
  }

  // The button can act once at least one row carries a value and there is
  // something to change; the sentence counts those rows, not the added ones
  // (a row without a value is no change); "Abbrechen" only when there is a
  // draft to discard. The other actions carry the count in their words.
  renderFoot() {
    const count = this.state.count
    if (this.hasExecuteLabelTarget) this.executeLabelTarget.textContent = this.plural(this.textsValue.execute, count)
    if (this.hasExecuteTarget) this.executeTarget.disabled = !(this.draft.hasChange() && count > 0)
    if (this.hasCancelTarget) this.cancelTarget.disabled = this.draft.isEmpty()
    this.otherTargets.forEach((button) => { button.disabled = count === 0 })
    const others = this.textsValue.others || {}
    if (this.hasMoveLabelTarget) this.moveLabelTarget.textContent = this.plural(others.move, count)
    if (this.hasDeleteLabelTarget) this.deleteLabelTarget.textContent = this.plural(others.delete, count)
    if (this.hasSummaryTarget) {
      const fields = this.draft.changeCount
      this.summaryTarget.textContent = fields === 0
        ? (this.textsValue.summary_empty || "")
        : `${this.plural(this.textsValue.summary_fields, fields)} ${this.plural(this.textsValue.summary_tickets, count)}`
    }
  }

  // --- the stock ----------------------------------------------------------

  scheduleSummary() {
    if (this._summaryTimer) clearTimeout(this._summaryTimer)
    if (this.state.count === 0) {
      this.summary = null
      this.renderStock()
      return
    }
    this._summaryTimer = setTimeout(() => this.fetchSummary(), this.summaryDelayValue)
  }

  // The selection as the server resolves it (mode ids or all) in the body
  // (a full page of ids does not fit into a request line), together with the
  // list's address, so "all" means the same set the table shows.
  async fetchSummary() {
    if (!this.hasSummaryUrlValue) return
    this._abort?.abort()
    const abort = new AbortController()
    this._abort = abort

    try {
      const response = await fetch(this.addressed(this.summaryUrlValue),
        this.jsonRequest("POST", { selection: this.selectionPayload }, "application/json", abort.signal))
      this.summary = response.ok ? await response.json() : null
    } catch (error) {
      if (error.name === "AbortError") return
      this.summary = null
    }
    this.renderStock()
  }

  renderStock() {
    this.rows.forEach((row) => {
      const line = row.querySelector("[data-stock]")
      if (line) line.textContent = this.stockText(row.dataset.field, row.dataset.kind)
      if (row.dataset.kind === "multi") this.renderMulti(row)
    })
  }

  // Every number here is the selection's own, in the singular for one ticket.
  stockText(field, kind) {
    const texts = this.textsValue.stock || {}
    if (!this.summary) return texts.pending || ""
    const data = this.summary.fields?.[field]
    if (!data) return ""
    const count = Number(this.summary.count) || 0

    if (kind === "single") {
      const parts = (data.values || []).map((entry) => `${entry.label} ${this.number(entry.count)}`)
      if (data.without > 0) parts.push(this.fill(texts.without, { count: data.without }))
      parts.push(this.plural(texts.overwrite, count))
      return `${texts.prefix} ${parts.join(" · ")}`
    }
    if (kind === "date") {
      if (data.only) return `${texts.prefix} ${this.plural(texts.date_all, count, { date: this.date(data.only) })}`
      const parts = []
      if (data.without > 0) parts.push(this.plural(texts.date_without, data.without))
      if (data.distinct > 0) parts.push(this.plural(texts.date_distinct, data.distinct))
      return `${texts.prefix} ${parts.join(", ")}`
    }
    if (kind === "boolean") {
      const parts = [this.fill(texts.yes, { count: data.yes }), this.fill(texts.no, { count: data.no })]
      if (data.without > 0) parts.push(this.fill(texts.without, { count: data.without }))
      return `${texts.prefix} ${parts.join(" · ")}`
    }
    if (kind === "multi") return this.multiStockText(field, data, count, texts)
    return ""
  }

  // With chips: what each chip's value means for the selection ("Backend: 4
  // von 14 tragen es schon"). Without: the values most of them carry.
  multiStockText(field, data, count, texts) {
    const entry = this.draft.get(field)
    const labels = this.optionLabels(this.rowFor(field) || document.createElement("div"))
    const values = data.values || []
    const chosen = entry ? [...entry.add, ...entry.remove] : []
    if (chosen.length > 0) {
      return chosen.map((value) => {
        const carry = this.stockCount(field, value)
        const label = labels.get(value) || value
        if (count === 1) return this.fill(carry > 0 ? texts.carry_one_yes : texts.carry_one_no, { label })
        if (carry === 0) return this.fill(texts.carry_none, { label, count })
        return this.fill(texts.carry, { label, count: carry, total: this.number(count) })
      }).join(" · ")
    }
    if (values.length === 0) return `${texts.prefix} ${texts.none}`
    return `${texts.prefix} ${values.slice(0, 4).map((v) => `${v.label} ${this.number(v.count)}`).join(" · ")}`
  }

  // --- text helpers -------------------------------------------------------

  plural(texts, count, extra = {}) {
    if (!texts) return ""
    const template = count === 1 ? texts.one : texts.other
    return this.fill(template, { count, ...extra })
  }

  fill(template, vars) {
    return String(template || "").replace(/%\{(\w+)\}/g, (_, key) => {
      if (key === "count") return this.number(vars.count)
      return vars[key] === undefined ? "" : String(vars[key])
    })
  }

  number(value) {
    return new Intl.NumberFormat(this.lang).format(Number(value) || 0)
  }

  date(iso) {
    try {
      return new Intl.DateTimeFormat(this.lang, { dateStyle: "medium" }).format(new Date(iso))
    } catch {
      return iso
    }
  }

  get lang() {
    return document.documentElement.lang || "de"
  }
}
