import { Controller } from "@hotwired/stimulus"
import { readLaneParams, laneParamNames, listPart } from "lane/params"
import { restoration, previewAddress } from "lane/history"
import { detailAddress } from "list_row/address"

/**
 * Index Page Controller (generic)
 *
 * Keeps an index/detail split page ("labor-layout-view") clean: resets the
 * detail frame to the placeholder and hides the detail column when no entry
 * is selected. Replaces the earlier, nearly identical
 * documents-page / notes-page / tickets-page controllers.
 *
 * Values:
 *   param-name            Query param(s) that signal a selection —
 *                         comma-separated for pages with multiple object types
 *                         (e.g. "ticket_id" or "note_id,document_id")
 *   frame-id              ID of the detail frame (e.g. "ticket_display_frame")
 *   content-selector      Selector for real content in the frame (e.g. ".ticket-content")
 *   placeholder-{title,body,id,class}  Placeholder markup (id/class optional)
 *   skip-params           comma-separated params whose presence suppresses the cleanup
 *   skip-param-equals     "key:value" – suppresses the cleanup when param == value
 *   selected-row-selector suppresses the cleanup when such an element exists
 *   skip-if-content-visible  suppresses the cleanup when the page already has "show-content"
 *
 * Since doc/dateivorschau_plan.md the wrapper carries the page's parameter
 * groups (data-lane-params, lib/lane/params): the selection names the open
 * object (param-name stays the fallback for a page without groups), a form
 * state keeps the content too. And this is the page's HISTORY RESTORER (D2):
 * Back and Forward pop an address; the restorer compares its list part with
 * the one the page shows (data-list-query, written on connect and by every
 * list reload) and restores the page when it moved, the frame when only the
 * lane did, the closed lane when nothing is open. Every entry, Turbo's own
 * included (its restoration on this page is a reload or nothing); the
 * restorer pushes nothing.
 */
const UUID_DETAIL = /\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export default class extends Controller {
  static targets = ["layout"]
  static values = {
    paramName: String,
    frameId: String,
    contentSelector: String,
    placeholderTitle: String,
    placeholderBody: String,
    placeholderId: String,
    placeholderClass: { type: String, default: "" },
    skipParams: { type: String, default: "" },
    skipParamEquals: { type: String, default: "" },
    selectedRowSelector: { type: String, default: "" },
    skipIfContentVisible: { type: Boolean, default: false }
  }

  connect() {
    this.normaliseDeepLink()
    this.rememberListPart()
    this.boundRememberListPart = this.rememberListPart.bind(this)
    this.element.addEventListener("lane:list-changed", this.boundRememberListPart)
    this.boundClearDetail = this.clearDetail.bind(this)
    this.element.addEventListener("lane:clear-detail", this.boundClearDetail)
    this.boundRestore = this.restore.bind(this)
    window.addEventListener("popstate", this.boundRestore)
    if (this.shouldKeepContent()) return
    this.cleanFrame()
    this.cleanLayout()
    this.cleanHighlights()
  }

  disconnect() {
    this.element.removeEventListener("lane:list-changed", this.boundRememberListPart)
    this.element.removeEventListener("lane:clear-detail", this.boundClearDetail)
    window.removeEventListener("popstate", this.boundRestore)
  }

  get groups() {
    const selection = this.paramNameValue.split(",").map((s) => s.trim()).filter(Boolean)
    return readLaneParams(this.element, { selection, preview: [], form: [] })
  }

  // The list part the page shows now: the address on connect, and again after
  // every list reload (the filter bar, a page turn). The path with it: a list
  // reload keeps it, another page has another one.
  rememberListPart() {
    this.element.dataset.listQuery = listPart(window.location.search, this.groups)
    this.element.dataset.listPath = window.location.pathname
  }

  // Every popped entry, Turbo's included (lib/lane/history says why), except
  // Turbo's own entry of another page: that one Turbo restores itself.
  restore(event) {
    const address = new URL(window.location.href)
    const outcome = restoration({
      shownPath: this.element.dataset.listPath,
      shownListQuery: this.element.dataset.listQuery,
      address,
      groups: this.groups,
      turboEntry: Boolean(event && event.state && event.state.turbo)
    })

    if (outcome.kind === "turbo") return

    if (outcome.kind === "page") {
      window.Turbo.visit(address.toString(), { action: "replace" })
      return
    }

    const toggle = this.layoutToggle
    if (outcome.kind === "close") {
      if (toggle) toggle.closeContent({ history: false })
      this.cleanFrame()
      this.cleanLayout()
      this.cleanHighlights()
      return
    }

    // The frame fetches the DETAIL address the page knows for the state: the
    // row of the selection (its list-row url) or, for a preview, the wrapper's
    // preview route with the two ids filled in (lib/lane/history). A state the
    // page has no road to (the row is on another page of the list, a page
    // without the preview route) restores as a page. Not the page address into
    // the frame: this page says turbo-visit-control reload, and Turbo turns a
    // frame response that is not visitable into a full visit.
    const url = this.frameAddressFor(outcome)
    if (!url) {
      window.Turbo.visit(address.toString(), { action: "replace" })
      return
    }
    const frame = document.getElementById(this.frameIdValue)
    if (frame) frame.setAttribute("src", detailAddress({ url, current: address, frame: this.frameIdValue, params: laneParamNames(this.groups) }))
    if (toggle) toggle.showContent()
    document.dispatchEvent(new CustomEvent("lane:restored"))
  }

  frameAddressFor({ selection, preview }) {
    if (preview) return previewAddress(this.element.dataset.lanePreviewUrl, { selection, preview })
    const row = document.querySelector(`[data-list-row-param-value="${selection.param}"][data-list-row-id-value="${selection.id}"]`)
    return row ? row.dataset.listRowUrlValue : null
  }

  get layoutToggle() {
    return this.application.getControllerForElementAndIdentifier(this.element, "layout-toggle")
  }

  // D7 of doc/kanban_ticket_als_bahn_plan.md: /tickets/A renders as a page
  // with the ticket open and then becomes /tickets?ticket_id=A in the address
  // bar, so every later open, close, reload and view switch works on ONE
  // address, the index with ticket_id. Only on a page that names its index
  // (data-index-url on this element); the other index pages keep their paths.
  normaliseDeepLink() {
    const indexUrl = this.element.dataset.indexUrl
    const match = window.location.pathname.match(UUID_DETAIL)
    if (!indexUrl || !match) return

    const address = new URL(indexUrl, window.location.origin)
    address.search = window.location.search
    address.searchParams.set(this.groups.selection[0], match[0].slice(1))
    window.history.replaceState(window.history.state, "", address.toString())
  }

  shouldKeepContent() {
    const params = new URLSearchParams(window.location.search)

    const groups = this.groups
    if ([...groups.selection, ...groups.form].some((p) => params.has(p))) return true
    if (UUID_DETAIL.test(window.location.pathname)) return true

    const skip = this.skipParamsValue.split(",").map((s) => s.trim()).filter(Boolean)
    if (skip.some((p) => params.has(p))) return true

    if (this.skipParamEqualsValue) {
      const [key, value] = this.skipParamEqualsValue.split(":")
      if (key && params.get(key) === value) return true
    }

    if (this.selectedRowSelectorValue && document.querySelector(this.selectedRowSelectorValue)) return true
    if (this.skipIfContentVisibleValue && this.element.classList.contains("show-content")) return true

    return false
  }

  cleanFrame() {
    const frame = document.getElementById(this.frameIdValue)
    if (!frame || !frame.querySelector(this.contentSelectorValue)) return

    const wrapper = document.createElement("div")
    if (this.placeholderIdValue) wrapper.id = this.placeholderIdValue
    if (this.placeholderClassValue) wrapper.className = this.placeholderClassValue

    const heading = document.createElement("h1")
    heading.textContent = this.placeholderTitleValue
    const body = document.createElement("p")
    body.textContent = this.placeholderBodyValue

    wrapper.append(heading, body)
    frame.replaceChildren(wrapper)
  }

  clearDetail(event) {
    if (event.detail?.frameId !== this.frameIdValue) return

    const frame = document.getElementById(this.frameIdValue)
    if (!frame) return

    frame.removeAttribute("src")
    this.cleanFrame()
  }

  cleanLayout() {
    this.element.classList.remove("show-content")
    if (this.hasLayoutTarget) {
      this.layoutTarget.classList.add("hide-content")
      this.layoutTarget.classList.remove("show-content")
    }
  }

  cleanHighlights() {
    // .selected-row: row or card, tickets and knowledge (list_row_controller);
    // tr.bg-lime-100: the meetings row until that page moves to the opener.
    document.querySelectorAll(".selected-row, tr.bg-lime-100").forEach((element) => {
      element.classList.remove("selected-row", "bg-lime-100")
    })
  }
}
