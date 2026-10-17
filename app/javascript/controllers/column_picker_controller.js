import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import { availableWidth, fitCount, fullModeWidth } from "column_picker/fit"
import { chosenKeys } from "column_picker/order"

// The column picker of the ticket list (doc/spaltenwahl_plan.md, S2 and S3),
// mounted on the list page's wrapper so it reaches the grid, the panel
// (outside the list frame, it survives every reload) and the trigger inside
// the frame.
//
// Three jobs. (1) Open and close: the grid carries `column-picker-open` (that
// class sizes the docked TRACK), and placePanel decides docked or floating and
// says so on the panel itself (data-floating, 10 px past the list's edge);
// Escape and a click outside close.
// (2) The fit: how many ranked columns fit into the list is measured here
// (list width, minus number and title, against the minimum
// widths in rank order) and written on the table as data-fit; the boundary
// line in the panel moves to the same place. Measured again on every resize of
// the list column and on every frame load. (3) The save: a tick or a move, by
// drag or by Alt+Arrow, is saved into the view the list stands on AT ONCE
// (user, 07.09.2026: no draft, no asking), then the list frame reloads from
// the stored list. Only "für alle Ansichten übernehmen" is a step of its own
// (fillApplyForm). A view the reader may not change takes no tick (editable).
//
// Keyboard: the row has the focus, Space or Enter ticks it, Alt+Arrow moves it
// (F37); a sentence in the live region names the new position.
const OPEN_CLASS = "column-picker-open"
// Set for one frame on open and for the way out on close: the stylesheet
// animates from it (the track at 0, the panel shifted and transparent).
const ENTERING_CLASS = "column-picker-entering"
const SLIDE_MS = 250
// On the cells of the column a panel row points at while the pointer or the
// focus rests on that row (user, 07.09.2026): the reader sees where a field is.
const HIGHLIGHT_CLASS = "column-highlight"
const TRIGGER_SELECTOR = "[data-column-picker-trigger]"

export default class extends Controller {
  static targets = ["grid", "panel", "list", "row", "pin", "boundary", "status", "live", "applyForm"]
  static values = {
    required: { type: Array, default: ["number", "title"] },
    frame: String,
    fixedWidth: Number,
    saveUrl: String,
    projectId: String,
    editable: { type: Boolean, default: true },
    errorLabel: String,
    movedTemplate: String,
    // The pin's caption in both states, so the toggle can keep the name and the
    // title truthful without a round trip. Passed in from the view: wording
    // belongs in the locale, never in a controller.
    pinLabelOn: String,
    pinLabelOff: String,
    pinTitleOn: String,
    pinTitleOff: String
  }

  initialize() {
    this.onKeydown = this.onKeydown.bind(this)
    this.onPointerDown = this.onPointerDown.bind(this)
    this.onFrameLoad = this.onFrameLoad.bind(this)
    this.onFrameChanged = this.onFrameChanged.bind(this)
    this.applyFit = this.applyFit.bind(this)
    this.onGridTransitionStart = this.onGridTransitionStart.bind(this)
    this.onGridTransitionEnd = this.onGridTransitionEnd.bind(this)
    this.settling = false
    this.lastKeys = null
    this.saving = false
    this.pendingKeys = null
    this.frameLoading = false
    this.reloadPending = false
    this.pointedKey = null
  }

  connect() {
    if (this.hasListTarget && this.editableValue) {
      this.sortable = Sortable.create(this.listTarget, {
        draggable: "li[data-key]",
        filter: '[role="separator"]',
        animation: 150,
        ghostClass: "column-picker__row--ghost",
        chosenClass: "column-picker__row--chosen",
        onEnd: () => this.changed()
      })
    }
    if (this.hasListTarget) this.lastKeys = chosenKeys(this.rowModels(), this.requiredValue)
    document.addEventListener("turbo:frame-load", this.onFrameLoad)
    // The list comes back in more than one way (the bar's frame navigation,
    // a stream from a saved comment), and not every way reaches a frame-load
    // listener. What every path shares is the DOM below the list container,
    // so that is what is watched: any node added or removed there measures
    // the table anew.
    const container = this.frame?.parentElement
    if (container && "MutationObserver" in window) {
      this.frameObserver = new MutationObserver(this.onFrameChanged)
      this.frameObserver.observe(container, { childList: true, subtree: true })
    }
    const listColumn = this.element.querySelector(".column.list")
    if (listColumn && "ResizeObserver" in window) {
      this.resizeObserver = new ResizeObserver(this.applyFit)
      this.resizeObserver.observe(listColumn)
    }
    // The lane slides in and out, and the list gives way over a quarter second.
    // The fit is decided ONCE for the width it is heading to (see settleFit),
    // not on every frame on the way there.
    if (this.hasGridTarget) {
      this.gridTarget.addEventListener("transitionstart", this.onGridTransitionStart)
      this.gridTarget.addEventListener("transitionend", this.onGridTransitionEnd)
      this.gridTarget.addEventListener("transitioncancel", this.onGridTransitionEnd)
    }
    this.applyFit()
  }

  disconnect() {
    this.sortable?.destroy()
    this.resizeObserver?.disconnect()
    this.frameObserver?.disconnect()
    cancelAnimationFrame(this.frameChangeFrame)
    clearTimeout(this.settleTimeout)
    document.removeEventListener("turbo:frame-load", this.onFrameLoad)
    if (this.hasGridTarget) {
      this.gridTarget.removeEventListener("transitionstart", this.onGridTransitionStart)
      this.gridTarget.removeEventListener("transitionend", this.onGridTransitionEnd)
      this.gridTarget.removeEventListener("transitioncancel", this.onGridTransitionEnd)
    }
    this.removeCloseListeners()
  }

  // === Open and close ===

  get open() {
    return this.hasPanelTarget && !this.panelTarget.hidden
  }

  toggle(event) {
    event?.preventDefault()
    this.open ? this.close() : this.openPanel()
  }

  openPanel() {
    if (!this.hasPanelTarget) return
    clearTimeout(this.slideTimer)
    const grid = this.hasGridTarget ? this.gridTarget : null
    // Start from the closed picture (track at 0, panel shifted), let the
    // browser paint it once, then release: the transitions run from there.
    grid?.classList.add(ENTERING_CLASS)
    this.panelTarget.hidden = false
    grid?.classList.add(OPEN_CLASS)
    void this.panelTarget.offsetWidth
    grid?.classList.remove(ENTERING_CLASS)
    this.syncTrigger()
    // ⚠️ Placed HERE and not only through applyFit: that method returns early
    // when there is no table yet and while the lane is still moving, and then
    // the panel opened without ever being told where to stand.
    this.placePanel()
    document.addEventListener("keydown", this.onKeydown)
    document.addEventListener("pointerdown", this.onPointerDown, true)
    // The docked panel narrows the list as the track grows: measure while it
    // moves and once more when it has settled.
    this.applyFit()
    this.slideTimer = setTimeout(() => {
      this.applyFit()
      this.rowTargets[0]?.focus()
    }, SLIDE_MS)
  }

  close(event) {
    event?.preventDefault()
    if (!this.hasPanelTarget || this.panelTarget.hidden) return
    clearTimeout(this.slideTimer)
    const grid = this.hasGridTarget ? this.gridTarget : null
    this.removeCloseListeners()
    // The way out: the same picture the panel came from, then it is gone.
    grid?.classList.add(ENTERING_CLASS)
    this.slideTimer = setTimeout(() => {
      this.panelTarget.hidden = true
      grid?.classList.remove(OPEN_CLASS, ENTERING_CLASS)
      this.syncTrigger()
      this.applyFit()
      this.trigger?.focus()
    }, SLIDE_MS)
  }


  removeCloseListeners() {
    document.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("pointerdown", this.onPointerDown, true)
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  ownsEscape() {
    return this.open
  }

  // Escape closes the panel and nothing else: the detail behind it has an
  // Escape of its own on window, which runs after this document listener.
  onKeydown(event) {
    if (event.key !== "Escape" || !this.open) return
    event.preventDefault()
    event.stopPropagation()
    this.close()
  }

  onPointerDown(event) {
    if (!this.open) return
    const target = event.target
    if (this.panelTarget.contains(target) || target.closest?.(TRIGGER_SELECTOR)) return
    this.close()
  }

  get trigger() {
    return this.element.querySelector(TRIGGER_SELECTOR)
  }

  // The trigger lives in the list frame and comes back fresh with every reload.
  syncTrigger() {
    const trigger = this.trigger
    if (trigger) trigger.setAttribute("aria-expanded", this.open ? "true" : "false")
  }

  // === Rows: point at the column ===

  // The header cell, the cells and, for a field below the title, the items
  // that carry this column: they all name it (data-column). The pointed key
  // is remembered, so a column that appears after a tick (the list is swapped
  // while the pointer still rests on its row) comes in tinted from its first
  // frame instead of being tinted a moment after (user, 07.09.2026).
  highlight(event) {
    this.pointedKey = event.currentTarget?.dataset.columnKey || null
    this.applyHighlight()
  }

  unhighlight() {
    this.pointedKey = null
    this.applyHighlight()
  }

  applyHighlight() {
    const frame = this.frame
    if (!frame) return
    frame.querySelectorAll(`.${HIGHLIGHT_CLASS}`).forEach(el => el.classList.remove(HIGHLIGHT_CLASS))
    if (!this.pointedKey) return
    frame.querySelectorAll(`[data-column="${CSS.escape(this.pointedKey)}"]`).forEach(el => el.classList.add(HIGHLIGHT_CLASS))
  }

  // === Rows: tick, move ===

  rowKeydown(event) {
    if (!this.editableValue) return
    // ⚠️ The pin is a button INSIDE the row, so its keys bubble up here. Without
    // this line, Space on the pin would pin the column AND untick it - the row
    // would answer a key that was never meant for it. Alt+Arrow still reaches
    // the row from the pin on purpose: moving a row is about the row, wherever
    // the focus sits in it.
    if (event.target.closest("[data-column-picker-target='pin']") && !event.altKey) return

    const row = event.currentTarget
    if (event.altKey && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
      event.preventDefault()
      this.moveRowElement(row, event.key === "ArrowUp" ? -1 : 1)
      return
    }
    if (event.key === " " || event.key === "Enter") {
      event.preventDefault()
      const checkbox = row.querySelector("input")
      checkbox.checked = !checkbox.checked
      this.changed()
    }
  }

  moveRowElement(row, delta) {
    const rows = this.rowTargets
    const from = rows.indexOf(row)
    const to = Math.min(rows.length - 1, Math.max(0, from + delta))
    if (to === from) return
    // Insert relative to the data row at `to`; the separator is re-placed by
    // applyFit, so it never gets in the way here.
    delta < 0 ? rows[to].before(row) : rows[to].after(row)
    row.focus()
    this.announce(row.querySelector("label")?.textContent?.trim(), to + 1)
    this.changed()
  }

  announce(name, position) {
    if (!this.hasLiveTarget || !name) return
    const template = this.movedTemplateValue || "%{name} %{position}"
    this.liveTarget.textContent = template.replace("%{name}", name).replace("%{position}", String(position))
  }

  // Which columns stay readable when the width runs out. Read off the signs,
  // so the panel is the single source of what gets saved.
  pinnedKeys() {
    if (!this.hasPinTarget) return []
    return this.pinTargets.filter(pin => pin.getAttribute("aria-pressed") === "true").map(pin => pin.dataset.key)
  }

  // Every change takes effect at once, with no asking (user, 07.09.2026): the
  // panel keeps the list narrow while it is open, so the reader sees the very
  // case they are setting up - pin, and the value appears under the title.
  togglePin(event) {
    event.preventDefault()
    if (!this.editableValue) return

    const pin = event.currentTarget
    const now = pin.getAttribute("aria-pressed") !== "true"
    pin.setAttribute("aria-pressed", String(now))

    // ⚠️ The caption travels with the state. aria-pressed alone is announced by
    // most screen readers, but the NAME would still say "anpinnen: Status" on a
    // column that is already pinned - and the pointer's title would say it too.
    const name = pin.closest("[data-column-picker-target='row']")?.querySelector(".column-picker__label")?.textContent?.trim()
    const label = now ? this.pinLabelOnValue : this.pinLabelOffValue
    if (label && name) pin.setAttribute("aria-label", label.replace("%{name}", name))
    const title = now ? this.pinTitleOnValue : this.pinTitleOffValue
    if (title) pin.setAttribute("title", title)

    this.save(chosenKeys(this.rowModels(), this.requiredValue))
  }

  rowModels() {
    return this.rowTargets.map(row => ({ key: row.dataset.key, checked: row.querySelector("input").checked }))
  }

  // === Apply to all views (plan D5) ===

  // The form posts the list as it stands in the panel, not as the page was
  // rendered: the reader may have ticked and moved since.
  fillApplyForm(event) {
    const form = event.currentTarget
    form.querySelectorAll('input[name="view_configuration[table_columns][]"]').forEach(input => input.remove())
    chosenKeys(this.rowModels(), this.requiredValue).forEach(key => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "view_configuration[table_columns][]"
      input.value = key
      form.appendChild(input)
    })
  }

  // === The save ===

  changed() {
    const keys = chosenKeys(this.rowModels(), this.requiredValue)
    this.applyFit()
    const same = this.lastKeys && keys.length === this.lastKeys.length && keys.every((key, index) => key === this.lastKeys[index])
    if (same) return
    this.lastKeys = keys
    this.save(keys)
  }

  // One save at a time, the newest list wins: a second change while the first
  // is in flight waits and goes out afterwards, so the view never ends up with
  // an older list than the panel shows.
  async save(keys) {
    if (!this.editableValue || !this.saveUrlValue) return
    if (this.saving) {
      this.pendingKeys = keys
      return
    }
    this.saving = true
    this.setStatus(null)
    try {
      const formData = new FormData()
      keys.forEach(key => formData.append("cols[]", key))
      // The pins travel with the list, in the same request: they belong to the
      // same view, and two endpoints would be two chances for the view to end
      // up half saved. An explicit blank clears the last pin; omitting pins
      // tells the server to preserve them for clients that do not send pins.
      const pins = this.pinnedKeys()
      ;(pins.length ? pins : [""]).forEach(key => formData.append("pins[]", key))
      if (this.projectIdValue) formData.append("project_id", this.projectIdValue)
      const response = await fetch(this.saveUrlValue, {
        method: "PATCH",
        headers: { "X-CSRF-Token": this.csrfToken, "Accept": "application/json" },
        body: formData
      })
      const answer = await this.jsonAnswer(response)
      if (answer && answer.success === true) {
        this.reloadFrame()
      } else {
        this.setStatus((answer && answer.error) || this.errorLabelValue)
      }
    } catch (_e) {
      this.setStatus(this.errorLabelValue)
    } finally {
      this.saving = false
      if (this.pendingKeys) {
        const next = this.pendingKeys
        this.pendingKeys = null
        this.save(next)
      }
    }
  }

  // Only the endpoint's own JSON counts: a denial comes back as a redirect to a
  // page, which fetch follows to a 200 of HTML that saved nothing.
  async jsonAnswer(response) {
    if (response.redirected) return null
    if (!response.ok && response.status !== 422) return null
    if (!(response.headers.get("content-type") || "").includes("application/json")) return null
    try {
      return await response.json()
    } catch (_e) {
      return null
    }
  }

  get csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  setStatus(message) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message || ""
    this.statusTarget.hidden = !message
  }

  get frame() {
    return this.frameValue ? document.getElementById(this.frameValue) : null
  }

  // The list renders from the stored list, so the frame is fetched anew from
  // the address as it stands and its content swapped. Not through Turbo's
  // frame src: a reload asked for right after a render is dropped by Turbo
  // (two quick moves by keyboard hit exactly this), so the fetch is ours and
  // one at a time; a reload asked for while one is in flight goes out after it.
  async reloadFrame() {
    const frame = this.frame
    if (!frame) return
    if (this.frameLoading) {
      this.reloadPending = true
      return
    }
    this.frameLoading = true
    try {
      const response = await fetch(window.location.href, {
        headers: { "Turbo-Frame": this.frameValue, "Accept": "text/html" },
        credentials: "same-origin"
      })
      const html = await response.text()
      const fresh = new DOMParser().parseFromString(html, "text/html").getElementById(this.frameValue)
      const current = this.frame
      // The tint goes on inside the swap, so the new cells are captured tinted.
      if (fresh && current) await this.swap(() => { current.replaceChildren(...fresh.childNodes); this.applyHighlight() })
    } catch (_e) {
      this.setStatus(this.errorLabelValue)
    } finally {
      this.frameLoading = false
      this.frameChanged()
      if (this.reloadPending) {
        this.reloadPending = false
        this.reloadFrame()
      }
    }
  }

  // The new list fades over the old one instead of snapping in (user,
  // 07.09.2026): a view transition where the browser has one, a plain swap
  // where it has none or the reader asked for less motion.
  async swap(replace) {
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches
    if (typeof document.startViewTransition !== "function" || reduced) {
      replace()
      return
    }
    try {
      await document.startViewTransition(replace).finished
    } catch (_e) {
      // The transition was skipped or cut short; the swap itself has happened.
    }
  }

  // The bar and the streams of other controllers replace the list too; each
  // replacement measures the new table (frame-load for a frame navigation,
  // the observer below for a stream that fires none).
  onFrameLoad(event) {
    if (!this.frameValue || event.target?.id !== this.frameValue) return
    this.frameChanged()
  }

  // Several mutations arrive for one replacement; one measure per frame.
  onFrameChanged() {
    cancelAnimationFrame(this.frameChangeFrame)
    this.frameChangeFrame = requestAnimationFrame(() => this.frameChanged())
  }

  frameChanged() {
    this.syncTrigger()
    this.applyFit()
    this.applyHighlight()
  }

  // === The fit ===

  // `width` is passed only by settleFit, which knows where the list is going.
  // Every other caller (the ResizeObserver hands over an array, a frame load
  // hands over nothing) measures what is there now - and is ignored while the
  // lane is moving.
  applyFit(width = null) {
    const forWidth = typeof width === "number"
    if (!forWidth && this.settling) return

    const table = this.frame?.querySelector("table[data-fit]")
    if (!table) return
    const listWidth = forWidth ? width : table.parentElement.clientWidth
    // The picker trigger lives in the filter bar. The last header is a data
    // column; subtracting its rendered width makes the fit depend on whether
    // that same column is currently visible, so repeated measurements oscillate.
    const available = availableWidth(listWidth, this.fixedWidthValue)
    const fit = fitCount(available, this.minWidths(table))
    table.dataset.fit = String(fit)
    this.applyFullModeWidths(table, fit)
    this.placeBoundary(fit)
    this.placePanel()
  }

  // Full mode (the lane shut): every ranked column that fits gets its width
  // as the larger of its share of the table (--col-share) and its minimum
  // (data-col-min), so a value is not cut while the title has room (designer,
  // 09.09.2026). Set inline, because a fixed table layout reads width alone
  // and the stylesheet cannot take a max() with a percentage on a cell. A
  // column beyond the fit keeps no inline width, or it would override the
  // stylesheet's width 0 that hides it. Compact mode reads --col-min from the
  // stylesheet alone, so the inline widths go the moment the lane opens.
  applyFullModeWidths(table, fit) {
    const full = this.hasGridTarget && this.gridTarget.classList.contains("hide-content")
    const tableWidth = table.clientWidth
    table.querySelectorAll("thead th[data-rank]").forEach(th => {
      const rank = Number(th.dataset.rank)
      if (!full || rank > fit) { th.style.width = ""; return }
      const share = parseFloat(getComputedStyle(th).getPropertyValue("--col-share")) / 100
      th.style.width = `${fullModeWidth(Number(th.dataset.colMin), share, tableWidth)}px`
    })
  }

  // === The fit while the lane moves ===
  //
  // ⚠️ Measuring every frame of the slide is what made the list judder: each
  // intermediate width drops one more column, and every column dropped hands
  // its width back to the ones that stay, so the title cell went narrow, jumped
  // wider, went narrow again (user, 07.09.2026). The width the list is HEADING
  // to is known the moment the transition starts, so the columns are decided
  // once, up front, and only their widths ease.
  onGridTransitionStart(event) {
    if (event.propertyName !== "grid-template-columns" || event.target !== this.gridTarget) return

    this.settling = true
    // A transition can be cut short without ever ending (a second click while
    // it runs); the timer is what stops "settling" from becoming permanent.
    clearTimeout(this.settleTimeout)
    this.settleTimeout = setTimeout(() => this.onGridSettled(), SLIDE_MS + 100)

    const target = this.targetListWidth()
    if (target !== null) this.applyFit(target)
  }

  onGridTransitionEnd(event) {
    if (event.propertyName !== "grid-template-columns" || event.target !== this.gridTarget) return
    this.onGridSettled()
  }

  onGridSettled() {
    clearTimeout(this.settleTimeout)
    this.settling = false
    this.applyFit()
  }

  // The width the list ends at, read from the same places the stylesheet reads:
  // --list-split when the lane is open, everything but the channel when it is
  // shut. Null for any layout that is not the lane grid, and null before the
  // split has been written in pixels - then the old measure-what-is-there wins,
  // which is what every other page does anyway.
  targetListWidth() {
    if (!this.hasGridTarget) return null
    const grid = this.gridTarget
    if (!grid.classList.contains("layout--lane")) return null

    const styles = getComputedStyle(grid)
    const gap = parseFloat(styles.columnGap) || 0
    if (grid.classList.contains("hide-content")) return Math.max(0, grid.clientWidth - gap)

    const split = styles.getPropertyValue("--list-split").trim()
    return split.endsWith("px") ? parseFloat(split) : null
  }

  // The panel's ticked rows carry the widths of the list that is about to be
  // rendered; without a panel the header cells of the table at hand do.
  minWidths(table) {
    if (this.hasListTarget) {
      return this.rowTargets.filter(row => row.querySelector("input").checked).map(row => Number(row.dataset.min) || 0)
    }
    return Array.from(table.querySelectorAll("thead th[data-rank]")).map(th => Number(th.dataset.colMin) || 0)
  }

  placeBoundary(fit) {
    if (!this.hasBoundaryTarget) return
    const ticked = this.rowTargets.filter(row => row.querySelector("input").checked)
    const boundary = this.boundaryTarget
    if (fit >= ticked.length) {
      boundary.hidden = true
      return
    }
    ticked[fit].before(boundary)
    boundary.hidden = false
  }

  // Floating over an open detail, the panel sits 10 px past the list's edge:
  // it is about the list and belongs next to it. Docked (no detail), the grid
  // places it and the inline offset must be gone.
  // Docked or floating, and where. ONE place decides it, and it says so on the
  // panel (data-floating) instead of leaving the stylesheet to work it out from
  // four classes on an ancestor - see layout.css, ".column-picker[data-floating]".
  placePanel() {
    if (!this.hasPanelTarget || !this.hasGridTarget) return

    const listColumn = this.element.querySelector(".column.list")
    const floating = this.open && !this.gridTarget.classList.contains("hide-content") && !!listColumn

    if (!floating) {
      this.panelTarget.removeAttribute("data-floating")
      this.panelTarget.style.left = ""
      this.panelTarget.style.top = ""
      this.panelTarget.style.maxHeight = ""
      return
    }

    // Viewport coordinates, because the panel is position: fixed: 10px past the
    // list's right edge, starting a head's height below its top, and never
    // taller than what is left below that.
    const list = listColumn.getBoundingClientRect()
    const top = Math.round(list.top + 40)
    this.panelTarget.setAttribute("data-floating", "")
    this.panelTarget.style.left = `${Math.round(list.right + 10)}px`
    this.panelTarget.style.top = `${top}px`
    this.panelTarget.style.maxHeight = `${Math.max(120, Math.round(window.innerHeight - top - 24))}px`
  }
}
