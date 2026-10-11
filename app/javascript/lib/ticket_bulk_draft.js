// The draft of a bulk change: the list of changes the reader has added in the
// panel, as state without a DOM (doc/ticket_bulk_edit_plan.md, slices 4 and
// 5). The panel starts empty and one ADDS changes; only what stands here is
// changed. The draft belongs to the browser, not to the lane's frame: a
// ticket and the panel take turns in that frame, so the selection controller
// keeps the serialised draft and hands it back when the panel returns.
//
// An entry is { field, kind, value } for a single value (select, yes/no), the
// same with { clear: true } for a date that is to be removed, and
// { field, kind: "multi", add: [], remove: [] } for the multi-valued kinds
// (tags, people, a multiselect): plus sets the value on every selected ticket,
// minus removes it from every one, in one row, because it is one field.
//
// The entries keep a fixed order, the catalogue's (the same as the ticket's
// attribute line), whatever the order of adding: a row never jumps when the
// next field is added (designer, 08.09.2026). A row without a value is no
// change: it does not count, it is not sent, and the button waits until at
// least one value stands.

const MULTI = "multi"

export class TicketBulkDraft {
  constructor(entries = [], order = []) {
    this.order = Array.isArray(order) ? order : []
    this.entries = entries.map((entry) => TicketBulkDraft.copy(entry))
    this.sort()
  }

  static from(serialised, order = []) {
    return new TicketBulkDraft(Array.isArray(serialised) ? serialised : [], order)
  }

  static copy(entry) {
    const copy = { ...entry }
    if (Array.isArray(entry.add)) copy.add = [...entry.add]
    if (Array.isArray(entry.remove)) copy.remove = [...entry.remove]
    return copy
  }

  get size() {
    return this.entries.length
  }

  isEmpty() {
    return this.entries.length === 0
  }

  has(field) {
    return this.entries.some((entry) => entry.field === field)
  }

  get(field) {
    return this.entries.find((entry) => entry.field === field) || null
  }

  fields() {
    return this.entries.map((entry) => entry.field)
  }

  // A field is added once; adding it again changes nothing. It takes its
  // place in the fixed order, not the end.
  add(field, kind) {
    if (this.has(field)) return false
    if (kind === MULTI) this.entries.push({ field, kind, add: [], remove: [] })
    else this.entries.push({ field, kind, value: null })
    this.sort()
    return true
  }

  // Fields the order does not know keep their order of adding, after the known ones.
  sort() {
    if (this.order.length === 0) return
    const rank = (field) => {
      const index = this.order.indexOf(field)
      return index === -1 ? this.order.length : index
    }
    this.entries = this.entries
      .map((entry, index) => ({ entry, index }))
      .sort((a, b) => rank(a.entry.field) - rank(b.entry.field) || a.index - b.index)
      .map(({ entry }) => entry)
  }

  // Where a field stands in the draft (its row's place in the list).
  indexOf(field) {
    return this.entries.findIndex((entry) => entry.field === field)
  }

  remove(field) {
    const before = this.entries.length
    this.entries = this.entries.filter((entry) => entry.field !== field)
    return this.entries.length !== before
  }

  // A single value. An emptied control is no value; a value ends a "clear".
  setValue(field, value) {
    const entry = this.get(field)
    if (!entry || entry.kind === MULTI) return false
    entry.value = value === "" || value === undefined ? null : value
    delete entry.clear
    return true
  }

  // A date to be removed from every selected ticket: complete without a value.
  setClear(field, clear = true) {
    const entry = this.get(field)
    if (!entry || entry.kind === MULTI) return false
    if (clear) {
      entry.clear = true
      entry.value = null
    } else {
      delete entry.clear
    }
    return true
  }

  // --- the multi-valued kinds ---------------------------------------------

  // What the draft says about one value: "add", "remove" or null.
  valueState(field, value) {
    const entry = this.get(field)
    if (!entry || entry.kind !== MULTI) return null
    if (entry.add.includes(value)) return "add"
    if (entry.remove.includes(value)) return "remove"
    return null
  }

  addValue(field, value) {
    const entry = this.get(field)
    if (!entry || entry.kind !== MULTI) return false
    entry.remove = entry.remove.filter((other) => other !== value)
    if (!entry.add.includes(value)) entry.add.push(value)
    return true
  }

  removeValue(field, value) {
    const entry = this.get(field)
    if (!entry || entry.kind !== MULTI) return false
    entry.add = entry.add.filter((other) => other !== value)
    if (!entry.remove.includes(value)) entry.remove.push(value)
    return true
  }

  clearValue(field, value) {
    const entry = this.get(field)
    if (!entry || entry.kind !== MULTI) return false
    entry.add = entry.add.filter((other) => other !== value)
    entry.remove = entry.remove.filter((other) => other !== value)
    return true
  }

  // The changes that say something: a value, a clear, or at least one plus
  // or minus. A row without any of these is no change.
  changes() {
    return this.entries.filter((entry) => TicketBulkDraft.complete(entry))
  }

  get changeCount() {
    return this.changes().length
  }

  // The button can act once at least one change stands.
  hasChange() {
    return this.changeCount > 0
  }

  // Every added row says something (the panel does not need this to act, a
  // caller that wants to know whether a row is still open does).
  isComplete() {
    return !this.isEmpty() && this.entries.every((entry) => TicketBulkDraft.complete(entry))
  }

  static complete(entry) {
    if (entry.kind === MULTI) return entry.add.length > 0 || entry.remove.length > 0
    if (entry.clear) return true
    return entry.value !== null && entry.value !== undefined && entry.value !== ""
  }

  // The whole draft for keeping (rows without a value included, so they come
  // back after a turn); `changesOnly` for the run, where an empty row is nothing.
  serialize(changesOnly = false) {
    return (changesOnly ? this.changes() : this.entries).map((entry) => TicketBulkDraft.copy(entry))
  }
}
