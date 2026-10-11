// The selection of the ticket list, as state without a DOM
// (doc/ticket_bulk_edit_plan.md, slices 1 and 2). The controller renders it
// into the boxes after every reload of the list frame; nothing is kept in the
// DOM, and nothing in storage: the designer's template (29a, D14) lets the
// selection lapse whenever the list's address changes, so there is nothing
// worth keeping across a navigation.
//
// Rules: a box ticks one row. Shift-click takes the range between the last box
// touched and this one, in the order of the loaded page. The head box takes the
// loaded page and nothing more; only then can "alle N" be offered, as a second
// step, and it means every hit of the current address. A change of the address
// (filter, view, search) drops everything: what was selected is no longer
// certain.

const ADDRESS_NOISE = ["page", "items", "ticket_id", "viewport"]

// The list's address without what does not change the SET: the page, the page
// size and the opened ticket. Sorted, so two spellings of one address compare
// equal.
export function normalizeAddress(search) {
  const params = new URLSearchParams(search || "")
  ADDRESS_NOISE.forEach((key) => params.delete(key))
  params.sort()
  return params.toString()
}

export class TicketSelection {
  constructor({ address = "" } = {}) {
    this.ids = new Set()
    this.address = address
    this.anchor = null
    // "ids": the ticked rows. "all": every hit of the address, `total` many;
    // the ids of the loaded page are then implied, not listed.
    this.mode = "ids"
    this.total = 0
  }

  get count() {
    return this.mode === "all" ? this.total : this.ids.size
  }

  isEmpty() {
    return this.mode === "ids" && this.ids.size === 0
  }

  isAll() {
    return this.mode === "all"
  }

  has(id) {
    return this.mode === "all" || this.ids.has(id)
  }

  toArray() {
    return Array.from(this.ids)
  }

  // One box. The row becomes the anchor for the next shift-click. Unticking a
  // row while "all" stands drops back to the ticks: the loaded page minus this
  // row. Ticking one while "all" stands changes nothing.
  set(id, checked, pageIds = []) {
    if (this.mode === "all") {
      if (checked) return
      this.dropToPage(pageIds)
    }
    if (checked) this.ids.add(id)
    else this.ids.delete(id)
    this.anchor = id
  }

  // A row removed outside a list reload (for example by a Turbo Stream after
  // deleting the ticket) cannot remain selected invisibly.
  remove(id) {
    const removed = this.ids.delete(id)
    if (this.anchor === id) this.anchor = null
    return removed
  }

  // Shift-click: every row between the anchor and this one, in page order,
  // takes this row's new state. Without an anchor on this page (first tick,
  // or the anchor left with the last reload) it is a plain tick.
  range(id, pageIds, checked) {
    if (this.mode === "all") {
      if (checked) return
      this.dropToPage(pageIds)
    }
    const from = pageIds.indexOf(this.anchor)
    const to = pageIds.indexOf(id)
    if (from === -1 || to === -1) return this.set(id, checked)

    const [start, end] = from < to ? [from, to] : [to, from]
    pageIds.slice(start, end + 1).forEach((rowId) => {
      if (checked) this.ids.add(rowId)
      else this.ids.delete(rowId)
    })
    this.anchor = id
  }

  // The head box: the loaded page, all or none. Ticks on other pages stay.
  // Unticking it while "all" stands ends "all" and the page with it.
  setPage(pageIds, checked) {
    if (this.mode === "all") {
      if (checked) return
      this.dropToPage(pageIds)
    }
    pageIds.forEach((rowId) => {
      if (checked) this.ids.add(rowId)
      else this.ids.delete(rowId)
    })
    this.anchor = null
  }

  // What the head box shows for the loaded page: "none", "some" or "all".
  pageState(pageIds) {
    if (pageIds.length === 0) return "none"
    if (this.mode === "all") return "all"
    const ticked = pageIds.filter((rowId) => this.ids.has(rowId)).length
    if (ticked === 0) return "none"
    return ticked === pageIds.length ? "all" : "some"
  }

  // The second step (29a): offered only once the loaded page is fully ticked
  // and the address has more hits than the page shows. A box that silently
  // takes every hit is the commonest cause of bulk accidents.
  canOfferAll(pageIds, total) {
    return this.mode === "ids" && this.pageState(pageIds) === "all" && total > pageIds.length
  }

  // Every hit of the current address, `total` many, as the list counted them.
  selectAll(total) {
    this.mode = "all"
    this.total = Number(total) || 0
    this.ids.clear()
    this.anchor = null
  }

  // From "all" back to ticks: the loaded page is what the reader can see, so
  // that is what stays ticked.
  dropToPage(pageIds) {
    this.mode = "ids"
    this.total = 0
    this.ids = new Set(pageIds)
  }

  // After a run: exactly these ids, whatever mode stood before. A run in
  // "all" mode changed a set the address may no longer show; keeping the
  // ids lets the next change hit the same tickets.
  setIds(ids) {
    this.mode = "ids"
    this.total = 0
    this.ids = new Set(Array.isArray(ids) ? ids.map(String) : [])
    this.anchor = null
  }

  clear() {
    this.ids.clear()
    this.anchor = null
    this.mode = "ids"
    this.total = 0
  }

  // The list frame came back under an address. The same address keeps the
  // selection (paging, an opened ticket); a different one drops it (D14).
  // Returns whether something was dropped, so the row can say so.
  reconcile(address) {
    if (address === this.address) return false

    const dropped = !this.isEmpty()
    this.clear()
    this.address = address
    return dropped
  }
}
