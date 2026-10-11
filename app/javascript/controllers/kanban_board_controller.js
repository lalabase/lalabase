import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
// Bare specifier, NEVER a relative "../lib/breakpoints" import: relative paths bypass
// importmap resolution and 404 on the undigested URL in production.
import { MOBILE_BREAKPOINT } from "breakpoints"
import { move, HEAD, CARD, ADD } from "kanban/keyboard"

// The gap between columns (layout.css, .kanban-board { gap }): one nav step
// is one column plus this. Change both together.
const COLUMN_GAP_PX = 20
// The grid moves its tracks in 250ms (layout.css, .layout.two-column
// transition). A skipped transition (a browser that cannot animate grid
// tracks, reduced motion) still gets the reveal, after this.
const GRID_TRANSITION_FALLBACK_MS = 300
// The room a revealed stop keeps to the edge of its scroller: its ring
// stands 5px outside it (layout.css, 2px at 3px offset) and must not touch
// the edge (doc/kanban_keyboard_plan.md, S5).
const REVEAL_MARGIN_PX = 8
// The stops of the keyboard, top to bottom in a column: the head, the cards
// (not the keyboard's placeholder, which is a picture), "+ Ticket".
const STOP_SELECTOR = ".kanban-column-header, .kanban-card:not(.kanban-placeholder), .kanban-add-ticket"
const CARD_SELECTOR = ".kanban-card:not(.kanban-placeholder)"

// The board: drag and drop between columns, the arrows over the well, the
// reveal of the chosen card (doc/kanban_ticket_als_bahn_plan.md, rules 4
// and 5), and the keyboard (doc/kanban_keyboard_plan.md): ONE tab stop per
// board, the cursor, that the arrows move over cards, column heads and
// "+ Ticket"; Space carries a card, Escape puts it back; a live line says
// what happened. Opening a ticket is NOT the board's: the card mounts
// ticket-row, the same controller the table row mounts, and Enter is its.
export default class extends Controller {
  static targets = ["column", "cardList", "mobileHint", "board", "nav", "prevBtn", "nextBtn", "live"]
  static values = {
    updateUrl: String,
    attributeName: String,
    readonly: Boolean,
    listUrl: String,
    texts: { type: Object, default: {} }
  }

  connect() {
    if (window.innerWidth < MOBILE_BREAKPOINT) {
      if (this.hasBoardTarget) this.boardTarget.classList.add("hidden")
      if (this.hasMobileHintTarget) this.mobileHintTarget.classList.remove("hidden")
      if (this.hasNavTarget) this.navTarget.classList.add("hidden")
      return
    }

    this.setupNavButtons()
    this.setupReveal()
    this.setupCursor()

    if (this.readonlyValue) return

    this.sortables = []
    this.cardListTargets.forEach(list => {
      this.sortables.push(Sortable.create(list, {
        group: "kanban",
        // Only cards are draggable -- the list also holds the empty-column
        // hint and, while the keyboard carries, a placeholder.
        draggable: CARD_SELECTOR,
        animation: 150,
        // ONE language for the mouse and the keyboard (D2): the marker under
        // the pointer is the left-behind picture, the chosen card the carried
        // one; layout.css styles both pairs alike.
        ghostClass: "kanban-ghost",
        chosenClass: "kanban-carried",
        onEnd: this.handleDragEnd.bind(this)
      }))
    })
  }

  disconnect() {
    if (this.sortables) {
      this.sortables.forEach(s => s.destroy())
    }
    if (this._scrollHandler) {
      this.boardTarget.removeEventListener("scroll", this._scrollHandler)
    }
    this.resizeObserver?.disconnect()
    this.teardownReveal()
    this.teardownCursor()
  }

  // === The arrows over the well ===

  setupNavButtons() {
    if (!this.hasBoardTarget || !this.hasNavTarget) return

    this._scrollHandler = () => this.updateNavButtons()
    this.boardTarget.addEventListener("scroll", this._scrollHandler, { passive: true })

    // The board's width changes without a scroll event: the lane opens and
    // closes, the handle is dragged. Every width change re-checks the arrows,
    // or they stay hidden or wrongly disabled after a squeeze.
    this.resizeObserver = new ResizeObserver(() => this.updateNavButtons())
    this.resizeObserver.observe(this.boardTarget)

    // Initial check after layout settles
    requestAnimationFrame(() => this.updateNavButtons())
  }

  updateNavButtons() {
    if (!this.hasBoardTarget || !this.hasNavTarget) return
    const board = this.boardTarget
    const isScrollable = board.scrollWidth > board.clientWidth
    const atStart = board.scrollLeft <= 1
    const atEnd = board.scrollLeft + board.clientWidth >= board.scrollWidth - 1

    this.navTarget.classList.toggle("hidden", !isScrollable)
    if (!isScrollable) return

    this.prevBtnTarget.disabled = atStart
    this.nextBtnTarget.disabled = atEnd
  }

  // One press moves one column, at whichever width the columns have right
  // now: layout.css narrows them while the lane is open.
  get scrollStep() {
    const column = this.columnTargets[0]
    return column ? column.offsetWidth + COLUMN_GAP_PX : 320
  }

  scrollLeft() {
    this.boardTarget.scrollBy({ left: -this.scrollStep, behavior: "smooth" })
  }

  scrollRight() {
    this.boardTarget.scrollBy({ left: this.scrollStep, behavior: "smooth" })
  }

  // === Drag and drop ===

  handleDragEnd(event) {
    // Dropped in the same column: the server knows no order, nothing to say.
    if (event.from === event.to) return
    this.persistMove(event.item, event.from, event.to, event.oldIndex)
  }

  // A card moved from one list to another, by mouse or by keyboard, told to
  // the server: the column's value through update_kanban_attribute. A refusal
  // puts the card back where it was; the answer's streams replace the card,
  // the head of this ticket and the row (the cursor follows, see
  // keepCursorThrough).
  persistMove(card, fromList, toList, fromIndex) {
    const ticketId = card.dataset.ticketId
    const newValue = toList.dataset.columnValue
    if (!ticketId) return

    const url = this.updateUrlValue.replace(":ticket_id", ticketId)
    const payload = {
      attribute_name: this.attributeNameValue,
      value: newValue === "" ? null : newValue
    }
    const putBack = () => {
      fromList.insertBefore(card, fromList.children[fromIndex] || null)
      this.updateColumnCounts()
    }

    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("[name='csrf-token']").content,
        "Accept": "text/vnd.turbo-stream.html"
      },
      body: JSON.stringify(payload)
    }).then(response => {
      if (!response.ok) {
        console.error("[KANBAN] Update failed:", response.status, response.statusText)
        response.text().then(body => {
          if (body) console.error("[KANBAN] Error details:", body)
        })
        putBack()
      } else {
        response.text().then(html => Turbo.renderStreamMessage(html))
      }
      this.updateColumnCounts()
    }).catch(err => {
      console.error("[KANBAN] Network error:", err)
      putBack()
    })
  }

  updateColumnCounts() {
    this.columnTargets.forEach(col => {
      const list = col.querySelector("[data-kanban-board-target='cardList']")
      const counter = col.querySelector(".kanban-count")
      if (list && counter) counter.textContent = list.querySelectorAll(CARD_SELECTOR).length
    })
  }

  // === The cursor: one tab stop per board (S2) ===

  // The cursor is the open card when there is one, else the first stop. Every
  // stop renders tabindex -1; the cursor alone gets 0, so Tab enters the
  // board once and leaves it once, and comes back to where it was.
  setupCursor() {
    this._onStreamRender = event => this.keepCursorThrough(event)
    document.addEventListener("turbo:before-stream-render", this._onStreamRender)
    // A carried card that loses the focus to something outside the board (a
    // click elsewhere, Tab out) goes back where it was: a lifted card with
    // nobody holding it would stay lifted, with no key that reaches it.
    this._onFocusOut = event => {
      if (!this.carried || this.movingCarried) return
      if (event.relatedTarget && this.element.contains(event.relatedTarget)) return
      this.putBack()
    }
    this.element.addEventListener("focusout", this._onFocusOut)
    const open = this.element.querySelector(".kanban-card.selected-row")
    this.setCursor(open || this.element.querySelector(CARD_SELECTOR) || this.stops()[0] || null, { focus: false })
  }

  teardownCursor() {
    if (this._onStreamRender) document.removeEventListener("turbo:before-stream-render", this._onStreamRender)
    if (this._onFocusOut) this.element.removeEventListener("focusout", this._onFocusOut)
  }

  stops() {
    return Array.from(this.element.querySelectorAll(STOP_SELECTOR))
  }

  setCursor(stop, { focus = true } = {}) {
    if (!stop) return
    this.stops().forEach(element => element.setAttribute("tabindex", element === stop ? "0" : "-1"))
    this.cursorId = stop.dataset.ticketId || null
    if (!focus) return
    stop.focus({ preventScroll: true })
    this.reveal(stop)
  }

  // The columns as the model reads them: the stops of each, top to bottom.
  columnsDom() {
    return this.columnTargets.map(column => ({
      element: column,
      list: column.querySelector("[data-kanban-board-target='cardList']"),
      stops: Array.from(column.querySelectorAll(STOP_SELECTOR))
    }))
  }

  kindOf(stop) {
    if (stop.classList.contains("kanban-column-header")) return HEAD
    if (stop.classList.contains("kanban-add-ticket")) return ADD
    return CARD
  }

  positionOf(columns, stop) {
    for (let column = 0; column < columns.length; column++) {
      const row = columns[column].stops.indexOf(stop)
      if (row >= 0) return { column, row }
    }
    return null
  }

  // === The keys (S3, S4, S6) ===

  key(event) {
    const stop = event.target.closest(STOP_SELECTOR)
    if (!stop || !this.element.contains(stop)) return
    if (this.carried) return this.carriedKey(event, stop)

    switch (event.key) {
      case "ArrowUp":
      case "ArrowDown":
      case "ArrowLeft":
      case "ArrowRight":
      case "Home":
      case "End": {
        event.preventDefault()
        const columns = this.columnsDom()
        const from = this.positionOf(columns, stop)
        if (!from) return
        const to = move(columns.map(column => column.stops.map(s => this.kindOf(s))), from, event.key)
        const next = columns[to.column]?.stops[to.row]
        if (next && next !== stop) {
          this.setCursor(next)
          this.announceStop(next)
        }
        return
      }
      case " ":
        // Space carries (D1); Enter opens, and that is ticket-row's.
        if (this.kindOf(stop) === CARD && !this.readonlyValue) {
          event.preventDefault()
          this.pickUp(stop)
        }
        return
      default:
        return
    }
  }

  // === Carrying (S6) ===

  // The card lifts, a picture of it stays at the origin, its column is the
  // target. The arrows then move the card itself; Sortable is pointer-only
  // and sees the moved node fresh on the next drag.
  pickUp(card) {
    const list = card.parentElement
    const fromIndex = Array.from(list.children).indexOf(card)
    const placeholder = card.cloneNode(true)
    for (const attribute of ["id", "data-controller", "data-action", "data-ticket-id", "tabindex"]) {
      placeholder.removeAttribute(attribute)
    }
    placeholder.classList.add("kanban-placeholder")
    placeholder.setAttribute("aria-hidden", "true")
    list.insertBefore(placeholder, card)
    card.classList.add("kanban-carried")
    this.markTarget(list)
    this.carried = { card, placeholder, fromList: list, fromIndex }
    this.announce(this.text("picked_up"))
  }

  carriedKey(event, stop) {
    const { card } = this.carried
    if (stop !== card) return
    switch (event.key) {
      case "ArrowUp":
      case "ArrowDown":
        event.preventDefault()
        this.carryVertically(event.key === "ArrowUp" ? -1 : 1)
        return
      case "ArrowLeft":
      case "ArrowRight":
        event.preventDefault()
        this.carrySideways(event.key === "ArrowLeft" ? -1 : 1)
        return
      case " ":
        event.preventDefault()
        this.drop()
        return
      case "Escape":
        // The board takes this Escape; the lane behind it stays open.
        event.preventDefault()
        event.stopPropagation()
        this.putBack()
        return
      default:
        return
    }
  }

  carryVertically(step) {
    const { card } = this.carried
    const list = card.parentElement
    const others = Array.from(list.querySelectorAll(CARD_SELECTOR)).filter(other => other !== card)
    const index = others.filter(other => card.compareDocumentPosition(other) & Node.DOCUMENT_POSITION_PRECEDING).length
    if (step > 0 && index < others.length) this.moveCarried(() => list.insertBefore(card, others[index].nextSibling))
    else if (step < 0 && index > 0) this.moveCarried(() => list.insertBefore(card, others[index - 1]))
    else return
    this.settleCarried(card)
  }

  // Moving the node takes the focus off it for a moment (focusout with no
  // relatedTarget); that moment must not read as "let go of the card".
  moveCarried(move) {
    this.movingCarried = true
    try { move() } finally { this.movingCarried = false }
  }

  carrySideways(step) {
    const { card } = this.carried
    const columns = this.columnsDom()
    const from = columns.findIndex(column => column.list === card.parentElement)
    const to = columns[from + step]
    if (from < 0 || !to || !to.list) return
    const index = Array.from(card.parentElement.querySelectorAll(CARD_SELECTOR)).filter(other => other !== card)
      .filter(other => card.compareDocumentPosition(other) & Node.DOCUMENT_POSITION_PRECEDING).length
    const targetCards = Array.from(to.list.querySelectorAll(CARD_SELECTOR))
    this.moveCarried(() => to.list.insertBefore(card, targetCards[index] || to.list.querySelector(".kanban-empty-hint") || null))
    this.markTarget(to.list)
    this.settleCarried(card)
  }

  // The target is the COLUMN of the list the carried card is in, whole with
  // head and "+ Ticket" (layout.css, .kanban-column.kanban-target); one at a
  // time.
  markTarget(list) {
    this.columnTargets.forEach(column => column.classList.toggle("kanban-target", column.contains(list)))
  }

  clearTarget() {
    this.columnTargets.forEach(column => column.classList.remove("kanban-target"))
  }

  // A moved node loses its focus in some browsers; take it back, show it,
  // say where it is now.
  settleCarried(card) {
    card.focus({ preventScroll: true })
    this.reveal(card)
    const place = this.placeOf(card)
    this.announce(this.text("card", { number: card.dataset.ticketNumber, title: this.titleOf(card), ...place }))
  }

  drop() {
    const { card, placeholder, fromList, fromIndex } = this.carried
    const toList = card.parentElement
    placeholder.remove()
    card.classList.remove("kanban-carried")
    this.clearTarget()
    this.carried = null
    this.announce(this.text("dropped", this.placeOf(card)))
    this.updateColumnCounts()
    if (toList !== fromList) this.persistMove(card, fromList, toList, fromIndex)
    else this.setCursor(card)
  }

  putBack() {
    const { card, placeholder, fromList } = this.carried
    fromList.insertBefore(card, placeholder)
    placeholder.remove()
    card.classList.remove("kanban-carried")
    this.clearTarget()
    this.carried = null
    this.updateColumnCounts()
    this.setCursor(card)
    this.announce(this.text("put_back"))
  }

  // === The cursor survives a stream (S7) ===

  // A drop, a status change in the lane, a broadcast: the server replaces the
  // card by id, and the focused node is gone with it. Before the stream
  // renders, remember whether the board had the focus and where a removal
  // would leave the cursor; after it, put the cursor on the new node.
  keepCursorThrough(event) {
    const stream = event.target
    if (!this.cursorId || !stream || stream.target !== `kanban-card-${this.cursorId}`) return
    if (typeof event.detail?.render !== "function") return
    const hadFocus = this.element.contains(document.activeElement)
    const current = this.element.querySelector(`.kanban-card[data-ticket-id="${this.cursorId}"]`)
    const fallback = stream.action === "remove" && current ? this.neighbourOf(current) : null
    const cursorId = this.cursorId
    const render = event.detail.render
    event.detail.render = async streamElement => {
      await render(streamElement)
      const card = this.element.querySelector(`.kanban-card[data-ticket-id="${cursorId}"]`)
      this.setCursor(card || fallback, { focus: hadFocus })
    }
  }

  // The next card in the same column, else the one before, else the head.
  neighbourOf(card) {
    const list = card.parentElement
    const cards = Array.from(list.querySelectorAll(CARD_SELECTOR))
    const index = cards.indexOf(card)
    return cards[index + 1] || cards[index - 1] || card.closest(".kanban-column")?.querySelector(".kanban-column-header") || null
  }

  // === The live line (S8) ===

  announce(text) {
    if (!this.hasLiveTarget || !text) return
    // The same words twice would not be read twice: a trailing no-break
    // space makes the second time a change. No animation frame here, a
    // hidden tab has none, and the words must still arrive.
    const same = this.liveTarget.textContent === text
    this.liveTarget.textContent = same ? `${text}\u00a0` : text
  }

  text(key, vars = {}) {
    const template = this.textsValue[key] || ""
    return template.replace(/%\{(\w+)\}/g, (_, name) => (vars[name] ?? ""))
  }

  announceStop(stop) {
    switch (this.kindOf(stop)) {
      case CARD:
        this.announce(this.text("card", { number: stop.dataset.ticketNumber, title: this.titleOf(stop), ...this.placeOf(stop) }))
        return
      case HEAD: {
        const column = stop.closest(".kanban-column")
        const count = column ? column.querySelectorAll(CARD_SELECTOR).length : 0
        this.announce(this.text("head", { column: column?.dataset.columnLabel || "", count }))
        return
      }
      default:
        this.announce(stop.getAttribute("title") || stop.textContent.trim())
    }
  }

  titleOf(card) {
    return card.querySelector("p")?.textContent.trim() || ""
  }

  // Where a card stands: its column's label, its position and the column's count.
  placeOf(card) {
    const list = card.parentElement
    const cards = Array.from(list.querySelectorAll(CARD_SELECTOR))
    return {
      column: list.closest(".kanban-column")?.dataset.columnLabel || "",
      position: cards.indexOf(card) + 1,
      count: cards.length
    }
  }

  // === The reveal (rule 5 of the lane plan, S5 of the keyboard plan) ===

  // ticket-row on the card does not know it is on a board and stays that way.
  // The board listens for what an opening already makes public: the load of
  // ticket_display_frame, then the grid's transition of its tracks.
  setupReveal() {
    this.grid = this.element.closest(".layout")
    this._onFrameLoad = event => {
      if (event.target.id === "ticket_display_frame") this.revealAfterTransition()
    }
    // Capture phase on the document: on this page turbo:frame-load does not
    // reach the document by bubbling (measured 08.09.2026, see
    // app/javascript/controllers/CLAUDE.md, ticket_selection).
    document.addEventListener("turbo:frame-load", this._onFrameLoad, true)

    // A page load with the ticket open: the grid is already at its width.
    if (this.element.querySelector(".kanban-card.selected-row")) this.revealSelected()
  }

  teardownReveal() {
    if (this._onFrameLoad) document.removeEventListener("turbo:frame-load", this._onFrameLoad, true)
    this.cancelPendingReveal()
  }

  cancelPendingReveal() {
    clearTimeout(this._revealTimer)
    if (this.grid && this._onTransitionEnd) this.grid.removeEventListener("transitionend", this._onTransitionEnd)
    this._onTransitionEnd = null
  }

  // The width is final only when the grid has finished moving its tracks; a
  // rectangle measured mid-transition points at where the column WAS. A
  // content swap in an open lane moves no track and fires no transitionend,
  // so the fallback timer is what reveals then.
  revealAfterTransition() {
    if (!this.grid) return this.revealSelected()

    this.cancelPendingReveal()
    const done = () => {
      this.cancelPendingReveal()
      this.revealSelected()
    }
    this._onTransitionEnd = event => {
      if (event.target === this.grid && event.propertyName === "grid-template-columns") done()
    }
    this.grid.addEventListener("transitionend", this._onTransitionEnd)
    this._revealTimer = setTimeout(done, GRID_TRANSITION_FALLBACK_MS)
  }

  revealSelected() {
    if (!this.hasBoardTarget) return
    this.reveal(this.boardTarget.querySelector(".kanban-card.selected-row"))
  }

  // Rectangles, not scrollIntoView: that walks every scrollable ancestor (the
  // list column, the window) and re-aligns a column that is already visible;
  // the page head must not move. Horizontally only the board scrolls, and only
  // when the column is not fully inside it, to the column's left edge.
  // Vertically only that column's own scroller, and only when the stop is
  // outside it, with REVEAL_MARGIN_PX of room for the ring. The head is not
  // in the scroller and needs no vertical reveal.
  reveal(element) {
    if (!this.hasBoardTarget || !element) return
    const column = element.closest(".kanban-column")
    if (!column) return

    const behavior = window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
    const board = this.boardTarget
    const boardRect = board.getBoundingClientRect()
    const columnRect = column.getBoundingClientRect()
    if (columnRect.left < boardRect.left || columnRect.right > boardRect.right) {
      const inset = parseFloat(getComputedStyle(board).paddingLeft) || 0
      board.scrollTo({ left: board.scrollLeft + (columnRect.left - boardRect.left) - inset, behavior })
    }

    const scroller = column.querySelector(".kanban-scroll")
    if (!scroller || !scroller.contains(element)) return
    const scrollerRect = scroller.getBoundingClientRect()
    const rect = element.getBoundingClientRect()
    if (rect.top - REVEAL_MARGIN_PX < scrollerRect.top) {
      scroller.scrollTo({ top: scroller.scrollTop + (rect.top - scrollerRect.top) - REVEAL_MARGIN_PX, behavior })
    } else if (rect.bottom + REVEAL_MARGIN_PX > scrollerRect.bottom) {
      scroller.scrollTo({ top: scroller.scrollTop + (rect.bottom - scrollerRect.bottom) + REVEAL_MARGIN_PX, behavior })
    }
  }
}
