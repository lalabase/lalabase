import { Controller } from "@hotwired/stimulus"
import { TicketSelection, normalizeAddress } from "ticket_selection"

// The selection of the ticket list (doc/ticket_bulk_edit_plan.md, slices 1
// and 2; designer template 29a). Mounted on the list column AROUND the head
// and the list frame, so it survives every reload of the frame. The state
// lives in lib/ticket_selection.js and is rendered into the boxes after each
// turbo:frame-load; the DOM never holds it.
//
// Slice 1: the boxes, the head box with its three states, shift-click ranges,
// the selection row in the filter sentence's place. Slice 2: "alle N
// auswählen" as the second step after the head box, with the cap the server
// enforces too. Slice 3: the lane. The first tick loads the panel's shell
// into the lane's frame, the last untick closes the lane again; a ticket and
// the panel take turns in that frame, and a tick with a ticket open brings
// the panel back. The panel talks to this controller over window events
// (ticket-bulk-panel:ready / :close, ticket-selection:change), because the
// two live in different frames.
export default class extends Controller {
  static targets = ["box", "headBox", "row", "count", "note", "all", "allReason", "result"]
  static values = {
    frame: String,
    mobile: Boolean,
    countOne: String,
    countOther: String,
    countAllOne: String,
    countAllOther: String,
    selectAllLabel: String,
    tooMany: String,
    max: Number,
    panelUrl: String,
    displayFrame: String,
    noteDelay: { type: Number, default: 6000 }
  }

  connect() {
    this.selection = new TicketSelection({ address: normalizeAddress(window.location.search) })
    this._noteVisible = false
    // The panel's draft, kept here because the panel leaves the lane whenever
    // a ticket takes it (slice 4): serialised entries, handed back on "ready".
    this.draft = []
    this._boundFrameLoad = this.onFrameLoad.bind(this)
    this._boundBeforeFrameRender = this.onBeforeFrameRender.bind(this)
    // Capture phase on the mount, not a bubble listener on document: measured
    // on 08.09.2026, turbo:frame-load reaches the frame element and never the
    // document on this page (every other frame event does), so a document
    // listener sees nothing. The frame is inside the mount, and a capturing
    // listener above it runs before anything on the way can stop the event.
    this.element.addEventListener("turbo:frame-load", this._boundFrameLoad, true)
    this.element.addEventListener("turbo:before-frame-render", this._boundBeforeFrameRender, true)
    // The lane's own close button: with the panel shown it clears the
    // selection (like the panel's ✕), with a ticket shown over a standing
    // selection it brings the panel back. Capture phase on the document, so
    // the button's own action never runs in those two cases.
    this._boundLaneClose = this.onLaneClose.bind(this)
    document.addEventListener("click", this._boundLaneClose, true)
    // A run (and its undo) answers with a stream that updates the list
    // frame's children; no frame-load fires for that, so the boxes of the new
    // rows are ticked again once the stream has rendered.
    this._boundStreamRender = this.onStreamRender.bind(this)
    document.addEventListener("turbo:before-stream-render", this._boundStreamRender)
    this.render()
  }

  disconnect() {
    this.element.removeEventListener("turbo:frame-load", this._boundFrameLoad, true)
    this.element.removeEventListener("turbo:before-frame-render", this._boundBeforeFrameRender, true)
    document.removeEventListener("click", this._boundLaneClose, true)
    document.removeEventListener("turbo:before-stream-render", this._boundStreamRender)
    if (this._noteTimer) clearTimeout(this._noteTimer)
    if (this._departingPageTimer) clearTimeout(this._departingPageTimer)
  }

  // Stimulus reports every old box as disconnected when the entire frame is
  // rendered. Remember that page for one task so boxTargetDisconnected does
  // not mistake pagination for individual row removal.
  onBeforeFrameRender(event) {
    if (event.target?.id !== this.frameValue) return

    // Turbo may wait for a repaint before rendering. Start the guard at the
    // actual render, and retain it until its DOM mutation callbacks have run.
    const render = event.detail.render
    event.detail.render = async (...args) => {
      this._departingPageIds = new Set(this.pageIds)
      if (this._departingPageTimer) clearTimeout(this._departingPageTimer)
      try {
        await render(...args)
      } finally {
        this._departingPageTimer = setTimeout(() => {
          this._departingPageIds = null
          this._departingPageTimer = null
        }, 0)
      }
    }
  }

  onStreamRender(event) {
    const target = event.target?.getAttribute?.("target")
    if (target !== this.frameValue && target !== this.resultTarget?.id) return
    // Turbo applies the stream on the next repaint; rendering earlier would
    // tick the rows that are about to be swapped out (or miss the result
    // line that decides whether the sentence shows).
    const apply = event.detail.render
    event.detail.render = async (stream) => {
      await apply(stream)
      this.render()
    }
  }

  // The list frame came back. Under a new address the selection lapses (D14)
  // and the row says so; under the same address (paging, an opened ticket)
  // the boxes are simply ticked again.
  onFrameLoad(event) {
    if (event.target?.id !== this.frameValue) return

    if (this.selection.reconcile(normalizeAddress(window.location.search))) {
      this.mobileActive = false
      this.draft = []
      this.clearResult()
      this.showNote()
    } else this.render()
  }

  // Row-level Turbo Streams do not emit turbo:frame-load. Stimulus target
  // callbacks are the scoped seam: a replacement box inherits the model's
  // state, while a genuinely removed row leaves the selection after the
  // replacement target has had one microtask to connect.
  boxTargetConnected() {
    if (this.selection) this.render()
  }

  boxTargetDisconnected(box) {
    if (!this.selection || this._departingPageIds?.has(box.value)) return

    const id = box.value
    queueMicrotask(() => {
      if (!this.element.isConnected) return
      if (this.boxTargets.some((candidate) => candidate.value === id)) return
      if (this.selection.remove(id)) this.render()
    })
  }

  // click, not change: the shift key is on the mouse event, and Space on a
  // focused box fires a click as well. The box is already in its new state.
  toggle(event) {
    const box = event.currentTarget
    if (event.shiftKey) this.selection.range(box.value, this.pageIds, box.checked)
    else this.selection.set(box.value, box.checked, this.pageIds)
    this.afterTick()
  }

  togglePage(event) {
    this.selection.setPage(this.pageIds, event.currentTarget.checked)
    this.afterTick()
  }

  // The second step: every hit of the address, as many as the list counted.
  selectAll() {
    if (this.hitsTotal > this.maxValue) return
    this.selection.selectAll(this.hitsTotal)
    this.afterTick()
  }

  clear() {
    this.mobileActive = false
    this.displayFrame?.closest("dialog")?.close()
    this.selection.clear()
    this._noteVisible = false
    if (this._noteTimer) clearTimeout(this._noteTimer)
    this.draft = []
    if (!this.mobileValue) this.clearResult()
    this.render()
    this.closePanelIfShown()
  }

  // The run is through: the selection becomes the changed tickets, the
  // draft is gone (the panel emptied itself), the panel stays for the next
  // change (29a §1: the selection stays, so one can go on). After a move or
  // a delete (slice 7) the tickets have left the list: the selection is
  // cleared and the lane closes, the result line stays until dismissed.
  afterRun(event) {
    const ids = Array.isArray(event.detail?.ids) ? event.detail.ids : []
    this.draft = []
    if (event.detail?.clear) {
      this.mobileActive = false
      this.selection.clear()
      this.render()
      this.closePanelIfShown()
      return
    }
    if (ids.length > 0) this.selection.setIds(ids)
    this.render()
  }

  clearResult() {
    if (this.hasResultTarget) this.resultTarget.replaceChildren()
  }

  // The ✕ on the result line.
  dismissResult() {
    this.clearResult()
    this.render()
  }

  get hasResult() {
    return this.hasResultTarget && this.resultTarget.childElementCount > 0
  }

  // A tick by the reader: the panel shows for a standing selection, even over
  // an open ticket (29a: one place, not two); the last untick closes the lane
  // if it holds the panel, a ticket in it stays.
  afterTick() {
    this.render()
    if (this.selection.isEmpty()) this.closePanelIfShown()
    else if (!this.mobileValue) this.showPanel()
  }

  // The panel connected in the lane and asks for the state it missed.
  announce() {
    this.dispatchChange()
  }

  // The panel's draft changed; it is kept here across the panel's turns.
  storeDraft(event) {
    this.draft = Array.isArray(event.detail?.draft) ? event.detail.draft : []
  }

  // The panel's ✕: clear and close, both together.
  closePanel() {
    this.clear()
  }

  onLaneClose(event) {
    const button = event.target.closest?.('[data-action*="layout-toggle#closeContent"]')
    if (!button) return
    if (this.panelShown) {
      event.preventDefault()
      event.stopPropagation()
      this.clear()
    } else if (!this.selection.isEmpty()) {
      event.preventDefault()
      event.stopPropagation()
      this.showPanel()
    }
  }

  get displayFrame() {
    return document.getElementById(this.displayFrameValue)
  }

  get panelShown() {
    return Boolean(this.displayFrame?.querySelector('[data-controller~="ticket-bulk-panel"]'))
  }

  get layoutToggle() {
    const element = document.querySelector('[data-controller~="layout-toggle"]')
    return element && this.application.getControllerForElementAndIdentifier(element, "layout-toggle")
  }

  // The panel into the lane: once. A ticket that was open leaves the frame
  // and the address (a reload must not bring it back over the panel), its row
  // loses the "opened" tint; the selection's tint stays.
  showPanel() {
    if (!this.hasPanelUrlValue || !this.displayFrame) return

    // The lane opens either way: after the last untick it closes with the
    // panel still inside the frame, and the next tick must open it again
    // without a second load. The lane opens BEFORE the frame is asked to
    // load, so the frame is never asked while it is hidden.
    if (!this.mobileValue) this.layoutToggle?.showContent()
    if (this.panelShown) return

    const frame = this.displayFrame
    // A load already on its way (two ticks in one breath): let it arrive.
    if (!frame.complete) return

    const url = new URL(window.location.href)
    if (url.searchParams.has("ticket_id")) {
      url.searchParams.delete("ticket_id")
      window.history.replaceState({}, "", url.toString())
    }
    document.querySelectorAll("tr.selected-row").forEach((row) => row.classList.remove("selected-row"))

    // Turbo loads on a CHANGE of src. The same address a second time (a load
    // that was cancelled, a frame that already carries it) is a reload.
    const current = frame.getAttribute("src")
    if (current && new URL(current, window.location.origin).pathname === new URL(this.panelUrlValue, window.location.origin).pathname) {
      frame.reload()
    } else {
      frame.setAttribute("src", this.panelUrlValue)
    }
  }

  closePanelIfShown() {
    if (!this.panelShown) return
    if (this.mobileValue) this.displayFrame?.closest("dialog")?.close()
    else this.layoutToggle?.closeContent()
  }

  get pageIds() {
    return this.boxTargets.map((box) => box.value)
  }

  // What the list found under the current address; the results partial puts
  // the pager's count into the frame, so nothing is asked twice.
  get hitsTotal() {
    const found = document.querySelector(`#${CSS.escape(this.frameValue)} [data-fb-hits-total]`)
    return Number(found?.dataset.fbHitsTotal) || 0
  }

  render() {
    const selection = this.selection

    this.boxTargets.forEach((box) => {
      const ticked = selection.has(box.value)
      box.checked = ticked
      box.closest("[data-ticket-id]")?.classList.toggle("selection-ticked", ticked)
    })

    if (this.hasHeadBoxTarget) {
      const state = selection.pageState(this.pageIds)
      this.headBoxTarget.checked = state === "all"
      this.headBoxTarget.indeterminate = state === "some"
    }

    if (this.mobileValue && !selection.isEmpty()) this.mobileActive = true
    this.element.classList.toggle("mobile-selecting", Boolean(this.mobileValue && this.mobileActive))
    const active = !selection.isEmpty()
    if (active && this._noteVisible) {
      this._noteVisible = false
      if (this._noteTimer) clearTimeout(this._noteTimer)
      this._noteTimer = null
    }
    const noteVisible = !active && this._noteVisible
    if (this.hasCountTarget) this.countTarget.textContent = this.countText(selection)
    this.renderAllStep(selection)
    if (this.hasRowTarget) this.rowTarget.hidden = !active
    if (this.hasNoteTarget) this.noteTarget.hidden = !noteVisible
    // Selection, lapse note and result line each keep the sentence's place.
    // A move or delete leaves its result here until it is dismissed.
    this.sentenceFrame?.toggleAttribute("hidden", active || noteVisible || this.hasResult)
    this.dispatchChange()
  }

  // What the panel needs to write its numbers: bubbles from the mount to the
  // window, where the panel listens.
  dispatchChange() {
    const selection = this.selection
    this.dispatch("change", {
      detail: { count: selection.count, mode: selection.mode, ids: selection.toArray(), total: selection.total, draft: this.draft, mobileActive: Boolean(this.mobileValue && this.mobileActive), hitsTotal: this.hitsTotal, max: this.maxValue }
    })
  }

  // "alle N auswählen" appears once the page is full and there is more; above
  // the cap it stays, disabled, with the reason beside it (off plus a visible
  // reason, never silently gone).
  renderAllStep(selection) {
    if (!this.hasAllTarget) return

    const total = this.hitsTotal
    const offered = selection.canOfferAll(this.pageIds, total)
    this.allTarget.hidden = !offered
    if (!offered) {
      if (this.hasAllReasonTarget) this.allReasonTarget.hidden = true
      return
    }

    const overCap = total > this.maxValue
    this.allTarget.textContent = this.selectAllLabelValue.replace("%{count}", this.formatNumber(total))
    this.allTarget.disabled = overCap
    this.allTarget.setAttribute("aria-disabled", String(overCap))
    if (this.hasAllReasonTarget) {
      this.allReasonTarget.hidden = !overCap
      this.allReasonTarget.textContent = this.tooManyValue.replace("%{max}", this.formatNumber(this.maxValue))
    }
  }

  countText(selection) {
    const count = selection.count
    const one = selection.isAll() ? this.countAllOneValue : this.countOneValue
    const other = selection.isAll() ? this.countAllOtherValue : this.countOtherValue
    return (count === 1 ? one : other).replace("%{count}", this.formatNumber(count))
  }

  formatNumber(number) {
    return new Intl.NumberFormat(document.documentElement.lang || "de").format(number)
  }

  get sentenceFrame() {
    return document.getElementById(`${this.frameValue}_sentence`)
  }

  showNote() {
    if (!this.hasNoteTarget) return

    this._noteVisible = true
    if (this._noteTimer) clearTimeout(this._noteTimer)
    this._noteTimer = setTimeout(() => {
      this._noteVisible = false
      this._noteTimer = null
      this.render()
    }, this.noteDelayValue)
    this.render()
  }
}
