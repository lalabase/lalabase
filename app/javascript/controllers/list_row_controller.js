import { Controller } from "@hotwired/stimulus"
import { openSelection, isOpen, canonicalAddress, detailAddress, FULL_PAGE_BELOW_PX } from "list_row/address"
import { readLaneParams, laneParamNames } from "lane/params"

// Opens a row into the lane. ONE controller for the ticket row, the kanban
// card and the knowledge row (doc/wissen_als_bahn_plan.md, S2, D2a): the six
// steps of opening have one owner, and so does the class that marks the open
// row (.selected-row, token --selected-row in layout.css).
//
// The address is the truth. The page address is the index with the live query
// and this row's selection parameter; built from ONE page-level data-index-url
// found with closest(), shared by every mount on the page. A row marks itself
// from the address on connect, by PARAMETER and id: ?document_id=X must not
// mark the note with id X. So a row replaced by a filter reload, an edit or a
// drop re-marks itself, and nobody re-applies anything after the fact.
//
// Values, all server-rendered:
//   url       the DETAIL address the frame fetches (/tickets/A, /notes/A)
//   id        this row's id
//   param     the selection parameter this row writes (ticket_id, note_id)
//   params    every selection parameter of the page; they exclude each other.
//             Since doc/dateivorschau_plan.md (D9) the page wrapper carries the
//             groups (data-lane-params, lib/lane/params) and this value is the
//             fallback for a page without them (the inbox pane)
//   frame     the lane's frame
//   navigate  a row that leaves the page (a meeting hit in the knowledge
//             list): a full visit to url, nothing else
export default class extends Controller {
  static values = {
    url: String,
    id: String,
    param: String,
    params: Array,
    frame: String,
    navigate: Boolean
  }

  static SELECTED_CLASS = "selected-row"
  static FULL_PAGE_BELOW_PX = FULL_PAGE_BELOW_PX

  connect() {
    this.markFromAddress()
    // After Back or Forward the restorer loads the frame and tells the rows;
    // a row that is still on the page re-marks itself from the address.
    this.boundMarkFromAddress = this.markFromAddress.bind(this)
    document.addEventListener("lane:restored", this.boundMarkFromAddress)
  }

  disconnect() {
    document.removeEventListener("lane:restored", this.boundMarkFromAddress)
  }

  // Only when the address names a selection: without one the server's own
  // mark stands (a deep link, before index-page has normalised it).
  markFromAddress() {
    const open = openSelection(window.location.search, this.groups.selection)
    if (open) this.mark(open.param === this.paramValue && open.id === this.idValue)
  }

  // The page's parameter groups (D9): the selection names the open object.
  // Opening an existing object replaces selection, preview and form state;
  // none of those transition parameters travel into the frame fetch.
  get groups() {
    return readLaneParams(this.element, { selection: this.paramsValue, preview: [], form: [] })
  }

  click(event) {
    // Not on links, buttons, forms or anything marked no-click: the row opens
    // the object, its controls do their own thing. A row that IS an anchor is
    // allowed through: project activities use its href as the no-JS and narrow
    // viewport fallback while the desktop click still opens the shared lane.
    const interactive = event.target.closest("a, button, form, .dropdown, .no-click")
    if (interactive && interactive !== this.element) return
    if (interactive === this.element && (event.button > 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)) return

    event.preventDefault()

    if (!this.urlValue || this.urlValue === "undefined") {
      console.error("Invalid row URL:", this.urlValue)
      return
    }

    if (this.navigateValue) {
      window.location.href = this.urlValue
      return
    }

    const groups = this.groups
    const transitionNames = [...new Set([...laneParamNames(groups), ...(groups.form || [])])]
    const current = new URL(window.location.href)
    const address = canonicalAddress({
      current,
      indexUrl: this.indexUrl,
      param: this.paramValue,
      params: transitionNames,
      id: this.idValue
    })

    if (window.innerWidth < this.constructor.FULL_PAGE_BELOW_PX) {
      const fallbackHref = this.element.matches?.("a[href]") ? this.element.href : null
      window.location.href = fallbackHref || address.toString()
      return
    }

    // A click on the open row closes the lane. Read from the address, not
    // from a class: closeContent() does not reliably clear every class.
    if (isOpen(current.search, this.paramValue, this.idValue)) {
      this.layoutToggle?.closeContent()
      return
    }

    document.querySelectorAll(`.${this.constructor.SELECTED_CLASS}`).forEach(element => element.classList.remove(this.constructor.SELECTED_CLASS))
    this.mark(true)

    // pushState for the first selection (the list stays in the history),
    // replaceState for every one after it, whatever its parameter. The entry
    // is the page's own (lane: true): Back restores it (lib/lane/history).
    const isFirstSelection = openSelection(current.search, groups.selection) === null
    window.history[isFirstSelection ? "pushState" : "replaceState"]({ lane: true, [this.paramValue]: this.idValue }, "", address.toString())

    const frame = document.getElementById(this.frameValue)
    if (frame) {
      frame.setAttribute("src", detailAddress({ url: this.urlValue, current: address, frame: this.frameValue, params: transitionNames }))
    }

    this.layoutToggle?.showContent()
  }

  mark(on) {
    this.element.classList.toggle(this.constructor.SELECTED_CLASS, on)
  }

  // ONE page-level data-index-url, read with closest(); a page without one
  // keeps its current path.
  get indexUrl() {
    return this.element.closest("[data-index-url]")?.dataset.indexUrl || null
  }

  get layoutToggle() {
    const element = document.querySelector('[data-controller~="layout-toggle"]')
    return element && this.application.getControllerForElementAndIdentifier(element, "layout-toggle")
  }

}
