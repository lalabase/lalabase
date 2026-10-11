import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Inline WYSIWYG dashboard editor (replaces dashboard_config_controller).
//
// Layout model (auto-columns, plan doc/dashboard_auto_columns_plan.md): a row is a 6-unit flex
// track. Each widget has a width in units (>= its registry minimum); widths are proportional to
// units (flex-grow). The row is ALWAYS full — Σ units == ROW_UNITS — so the visible width equals
// the unit proportion (WYSIWYG); there is no hidden "free space". There is NO row-type select and
// NO covered-slot model — columns are emergent from which widgets sit in the row.
//
// Width controls move the BOUNDARY between two adjacent widgets (split-pane / zero-sum): widening
// one widget narrows its neighbour by the same amount, never below either minimum.
//   - drag the right-edge handle = move the boundary with the RIGHT neighbour (snaps to whole units)
//   - ⋯-menu "breiter"/"schmaler" = keyboard/touch equivalent (WCAG 2.5.7); uses the right
//     neighbour, or the left one for the rightmost widget (which owns no right boundary)
//   Both are gated so they are never dead: disabled when the relevant neighbour is already at its
//   minimum. Adding/removing a widget redistributes units so the row stays exactly full.
//
// Drag & drop reorder (decision C + keyboard fallback, §6.3):
//   - rows reorder vertically (Sortable on the rows container, handle only)
//   - widgets reorder within a row AND move between rows (shared Sortable group; the trailing
//     "+ widget" button is kept last). A row only accepts a dropped widget while its widgets'
//     minimums still leave room for it (group.put gate); the moved widget enters at its minimum and
//     both rows refill to Σ units. Cross-row move is mouse/touch only — the keyboard reorder chips
//     stay within a row (left/right).
//
// Reindex contract (§6.3): before submit the FULL rows[i][widgets][j] prefix of every field is
// rebuilt from DOM position via data-name-suffix. The PATCH happens once on submit.
//
// New rows/widgets are cloned from server-rendered <template>s (no JS HTML).
export default class extends Controller {
  // applyAllBlock/applyAllCheckbox removed: the save-scope radio replaces the apply-all checkbox.
  static targets = ["form", "rows", "row", "slot", "unsaved", "error", "smartFolderWarning", "undoBtn", "redoBtn", "compactToggle"]
  static values = {
    unsavedConfirm: { type: String, default: "" },
    confirmAll: { type: String, default: "" },
    emptyRows: { type: String, default: "" },
    emptyCards: { type: String, default: "" },
    // The 6-unit row track size (Dashboards::LayoutEngine::ROW_UNITS). The row is kept exactly full;
    // this bounds the boundary moves and gates "+ widget" against the room left for more minimums.
    rowUnits: { type: Number, default: 6 },
    // Endpoint that re-renders one widget with its unsaved settings (live preview on flip-back).
    previewUrl: { type: String, default: "" },
    // The proportional-width flex class per unit count, emitted once from DASHBOARD_UNIT_FLEX
    // (dashboard_helper.rb) as { "1": "lg:flex-[1_1_0%]", … }. Single source so the Ruby render and
    // the JS resize can't drift. Tailwind still sees the literals in the Ruby file, so JIT emits them.
    unitFlex: { type: Object, default: {} },
    // --- Surface binding (K1): the controller is shared by the project dashboard and the org
    // overview, which have different save scopes and stats-style widgets. These come from the editor
    // view so no surface-specific string is baked into the controller. Defaults = project dashboard.
    // The radio value selected when none is checked (the personal/this-surface scope).
    defaultScope: { type: String, default: "personal_this" },
    // Scopes whose write reaches beyond the current surface (project: the two „all projects" scopes):
    // they trigger the pre-submit confirm AND the smart-folder „won't resolve elsewhere" warning.
    confirmScopes: { type: Array, default: [] },
    // Widget keys whose card-list can be emptied client-side (all checkboxes off) and must be blocked
    // before submit, since the server can't tell „empty" from „use defaults" (project: stats_cards).
    statsWidgetKeys: { type: Array, default: [] }
  }

  connect() {
    this.sortables = []
    this.dirty = false
    // Undo/redo: a linear stack of `rows` HTML snapshots. The whole editor is client-side (the form
    // serializes only on save), so history is purely in the DOM. index points at the current state.
    this.history = []
    this.historyIndex = -1
    this.restoring = false
    this.MAX_HISTORY = 25
    this.resizing = false
    // Compact mode crops each widget preview so rows stay short and the whole layout fits on ~one
    // screen — otherwise full-height previews put the target row out of reach when dragging. Default
    // on; remembered per browser.
    this.compact = this.readCompactPref()
    this.refreshSortables()
    this.applyCompact(this.compact)
    this.updateWidthAffordance()

    this.boundDirty = () => this.markDirty()
    // A committed settings change (select/checkbox in a slot) is one undo step. `change` only (not
    // `input`) so it is coarse; gated to changes inside a row so unrelated admin toggles don't record.
    this.boundRecordChange = (event) => { if (event.target.closest("[data-row]")) this.recordHistory() }
    this.boundKeydown = (event) => this.onKeydown(event)
    this.element.addEventListener("input", this.boundDirty)
    this.element.addEventListener("change", this.boundDirty)
    this.element.addEventListener("change", this.boundRecordChange)
    this.element.addEventListener("keydown", this.boundKeydown)

    this.recordHistory() // capture the initial (as-loaded) layout at index 0
  }

  disconnect() {
    this.destroySortables()
    this.element.removeEventListener("input", this.boundDirty)
    this.element.removeEventListener("change", this.boundDirty)
    this.element.removeEventListener("change", this.boundRecordChange)
    this.element.removeEventListener("keydown", this.boundKeydown)
  }

  onKeydown(event) {
    if (event.key === "Escape") { this.closeMenus(); return }
    const meta = event.metaKey || event.ctrlKey
    if (meta && (event.key === "z" || event.key === "Z")) {
      event.preventDefault()
      event.shiftKey ? this.redo() : this.undo()
    } else if (meta && (event.key === "y" || event.key === "Y")) {
      event.preventDefault()
      this.redo()
    }
  }

  // --- Sortable lifecycle ---

  refreshSortables() {
    this.destroySortables()

    this.sortables.push(Sortable.create(this.rowsTarget, {
      handle: "[data-row-handle]",
      draggable: "[data-row]",
      animation: 150,
      ghostClass: "sortable-ghost",
      chosenClass: "sortable-chosen",
      dragClass: "sortable-drag",
      // Auto-scroll the page while dragging so a row further down/up is reachable.
      scroll: true,
      scrollSensitivity: 60,
      scrollSpeed: 16,
      bubbleScroll: true,
      onEnd: () => { this.closeMenus(); this.markDirty(); this.recordHistory() }
    }))

    this.element.querySelectorAll("[data-slots]").forEach((slots) => {
      this.sortables.push(Sortable.create(slots, {
        handle: "[data-slot-handle]",
        draggable: "[data-slot]",
        filter: "[data-add-col]",
        // Shared group so a widget can move to another row. put() is asked live during the drag
        // whether THIS row can accept the item — only if its widgets' minimums (plus the dragged
        // one's) still fit ROW_UNITS — so an over-full row shows the no-drop cursor and refuses it.
        group: {
          name: "dashboard-widgets",
          put: (to, _from, dragEl) => {
            // A function put() bypasses SortableJS's group-name check, so we must reject anything
            // that isn't a widget — otherwise a whole ROW (dragged in the rows Sortable) would be
            // accepted into a widget list and nest inside another row.
            if (!dragEl.matches("[data-slot]")) return false
            const present = Array.from(to.el.querySelectorAll("[data-slot]"))
              .filter((s) => s !== dragEl)
              .reduce((sum, s) => sum + this.slotUnitsMin(s), 0)
            return present + this.slotUnitsMin(dragEl) <= this.rowUnitsValue
          }
        },
        // Not 'horizontal': a widget can now leave its row, so the drag must also track vertical
        // movement to the row above/below.
        animation: 150,
        // Auto-scroll the page while dragging so a target row off-screen becomes reachable.
        scroll: true,
        scrollSensitivity: 60,
        scrollSpeed: 16,
        bubbleScroll: true,
        ghostClass: "sortable-ghost",
        chosenClass: "sortable-chosen",
        dragClass: "sortable-drag",
        // Keep the "+ widget" column pinned last: forbid dropping AFTER it (but allow before it, so a
        // widget can still land in the last slot and can be dropped INTO an empty row whose only child
        // is the add-col). Without this the add-col gets shoved around mid-drag.
        onMove: (evt) => !(evt.related && evt.related.matches("[data-add-col]") && evt.willInsertAfter),
        onEnd: (evt) => this.onSlotDrop(evt)
      }))
    })
  }

  destroySortables() {
    this.sortables.forEach((s) => s.destroy())
    this.sortables = []
  }

  // Drop handler for the widget Sortables (intra- and cross-row). Always keeps the "+ widget" column
  // last in any touched row. For a cross-row move it resets the widget to its minimum width and
  // refills BOTH rows to Σ = ROW_UNITS — the source opened a gap (others grow), the target gained a
  // widget (others shrink); the put-gate guarantees the target can fit the minimum. An emptied
  // source row is left in place, like a freshly added empty row (the save drops empty rows).
  onSlotDrop(evt) {
    const fromRow = evt.from.closest("[data-row]")
    const toRow = evt.to.closest("[data-row]")
    ;[evt.from, evt.to].forEach((list) => {
      const addCol = list.querySelector("[data-add-col]")
      if (addCol) list.appendChild(addCol)
    })
    if (fromRow !== toRow) {
      this.setSlotUnits(evt.item, this.slotUnitsMin(evt.item))
      this.normalizeRow(toRow)
      this.normalizeRow(fromRow)
      // Rebind the Sortables after a cross-list move so the relocated widget is cleanly draggable
      // again (SortableJS can otherwise leave the two lists' state out of sync for the next drag).
      // Deferred so we never destroy the instance whose onEnd is still running.
      setTimeout(() => this.refreshSortables(), 0)
    }
    this.updateWidthAffordance()
    this.markDirty()
    this.recordHistory()
  }

  // --- Rows ---

  addRow() {
    const row = this.cloneTemplate("[data-row-template]")
    if (!row) return
    this.closeMenus()
    this.rowsTarget.appendChild(row)
    this.refreshSortables()
    this.updateWidthAffordance()
    this.markDirty()
    this.recordHistory()
  }

  removeRow(event) {
    const row = event.currentTarget.closest("[data-row]")
    if (!row) return
    this.closeMenus() // close any open settings flip / add-picker before the row list changes
    // WCAG 2.4.3: keep focus on a sibling row's handle, falling back to "+ Zeile".
    const next = row.nextElementSibling
    const prev = row.previousElementSibling
    let sibling = null
    if (next && next.hasAttribute("data-row")) sibling = next
    else if (prev && prev.hasAttribute("data-row")) sibling = prev
    const focusTarget = sibling?.querySelector("[data-row-handle]") ||
                        this.element.querySelector("[data-action*='addRow']")
    row.remove()
    this.refreshSortables()
    focusTarget?.focus()
    this.markDirty()
    this.recordHistory()
  }

  // Row reorder shifts every later row index: close any open menu/popover first.
  moveRowUp(event) {
    const row = event.currentTarget.closest("[data-row]")
    const prev = row.previousElementSibling
    if (prev && prev.hasAttribute("data-row")) {
      this.closeMenus()
      row.parentNode.insertBefore(row, prev)
      this.markDirty()
      this.recordHistory()
    }
  }

  moveRowDown(event) {
    const row = event.currentTarget.closest("[data-row]")
    const next = row.nextElementSibling
    if (next && next.hasAttribute("data-row")) {
      this.closeMenus()
      row.parentNode.insertBefore(next, row)
      this.markDirty()
      this.recordHistory()
    }
  }

  // --- Slot actions menu ---

  // ⋯ flips the card to its settings/actions back (shown in place of the widget); clicking ⋯ again,
  // the back's close button, or Escape flips it back. Only one card is ever flipped at a time.
  toggleMenu(event) {
    const slot = event.currentTarget.closest("[data-slot]")
    const wasFlipped = slot.classList.contains("is-flipped")
    this.closeMenus()
    if (!wasFlipped) this.flipToBack(slot)
  }

  // The whole widget front is a click target that opens its settings, so you needn't hit the small
  // gear. The drag controls (grip, resize handle) and the gear keep their own handlers, so a click
  // on those does not also open settings.
  openSettings(event) {
    if (event.target.closest("[data-slot-handle], [data-slot-resize], [data-slot-menu-button]")) return
    const slot = event.currentTarget.closest("[data-slot]")
    if (slot.classList.contains("is-flipped")) return
    this.closeMenus()
    this.flipToBack(slot)
  }

  flipToBack(slot) {
    slot.classList.add("is-flipped")
    slot.querySelector("[data-flip-front]")?.setAttribute("inert", "")
    slot.querySelector("[data-flip-back]")?.removeAttribute("inert")
    this.fitFlipHeight(slot) // grow the card to the settings form so it is never clipped
    slot.querySelector("[data-slot-menu-button]")?.setAttribute("aria-expanded", "true")
    // WCAG 2.4.3: move focus onto the now-visible back face.
    slot.querySelector("[data-flip-back] button:not([disabled]), [data-flip-back] select, [data-flip-back] input")?.focus()
  }

  // The settings back can be taller than the widget front (e.g. stats_cards' long card list). Set
  // the flip card's height to the back's content height so the form is shown in full (no clip), and
  // re-measure after anything that changes the back's height (move-target list). Reset on close.
  fitFlipHeight(slot) {
    const flip = slot.querySelector("[data-flip]")
    const back = slot.querySelector("[data-flip-back]")
    if (flip && back) flip.style.height = `${back.scrollHeight}px`
  }

  resetFlipHeight(slot) {
    const flip = slot.querySelector("[data-flip]")
    if (flip) flip.style.height = ""
  }

  closeMenus() {
    const restoreTo = this.triggerForFocusedPanel()

    this.element.querySelectorAll("[data-slot].is-flipped").forEach((slot) => {
      slot.classList.remove("is-flipped")
      slot.querySelector("[data-flip-front]")?.removeAttribute("inert")
      slot.querySelector("[data-flip-back]")?.setAttribute("inert", "")
      slot.querySelector("[data-slot-menu-button]")?.setAttribute("aria-expanded", "false")
      this.resetFlipHeight(slot)
      this.refreshPreview(slot) // show the new settings on the card immediately (WYSIWYG)
    })
    this.element.querySelectorAll("[data-add-picker-host]").forEach((host) => {
      host.classList.add("hidden")
      host.innerHTML = ""
    })

    if (restoreTo) restoreTo.focus()
  }

  // WCAG 2.4.3: if focus sits inside a back face / picker we are about to hide, return it to that
  // slot's ⋯ trigger (on the front) so closing never drops focus to <body>.
  triggerForFocusedPanel() {
    const active = document.activeElement
    const panel = active?.closest("[data-flip-back]")
    if (!panel) return null
    const slot = panel.closest("[data-slot]")
    return slot && this.slotTrigger(slot)
  }

  slotTrigger(slot) {
    return slot.querySelector("[data-slot-menu-button]")
  }

  // The row is a horizontal flex track, so "earlier in the DOM" = left, "later" = right.
  moveSlotLeft(event) {
    const slot = event.currentTarget.closest("[data-slot]")
    const prev = slot.previousElementSibling
    if (prev && prev.hasAttribute("data-slot")) {
      slot.parentNode.insertBefore(slot, prev)
      this.afterSlotMove(slot, event.currentTarget, "moveSlotRight")
    }
  }

  moveSlotRight(event) {
    const slot = event.currentTarget.closest("[data-slot]")
    const next = slot.nextElementSibling
    if (next && next.hasAttribute("data-slot")) {
      slot.parentNode.insertBefore(next, slot)
      this.afterSlotMove(slot, event.currentTarget, "moveSlotLeft")
    }
  }

  // After a chip-driven reorder, recompute every slot's affordances (the moved slot's new position
  // flips which edge chips/resize directions are valid) and flag the dirty state. If the chip we
  // clicked just became disabled (the slot reached a row edge), move focus to the opposite chip so
  // keyboard users aren't stranded on a disabled control (WCAG 2.4.3).
  afterSlotMove(slot, clickedBtn, fallbackAction) {
    this.updateWidthAffordance()
    this.markDirty()
    this.recordHistory()
    if (clickedBtn.disabled) {
      const fallback = slot.querySelector(`[data-action*='${fallbackAction}']`)
      if (fallback && !fallback.disabled) fallback.focus()
    }
  }

  removeWidget(event) {
    const slot = event.currentTarget.closest("[data-slot]")
    const row = slot.closest("[data-row]")
    const addBtn = row.querySelector("[data-add-widget]")
    slot.remove()
    this.normalizeRow(row) // give the freed units back to the remaining widgets (Σ stays full)
    addBtn?.focus() // WCAG 2.4.3
    this.refreshSortables()
    this.updateWidthAffordance()
    this.markDirty()
    this.recordHistory()
  }

  // --- Widget picker (row-level "+ widget") ---

  // "+ widget": append a widget to this row. Opens the picker gated to what fits the free units.
  addWidget(event) {
    const row = event.currentTarget.closest("[data-row]")
    const host = row.querySelector("[data-add-picker-host]")
    if (!host) return
    const wasOpen = !host.classList.contains("hidden")
    this.closeMenus() // clears this host (and any other open flip/picker)
    if (wasOpen) return // a second click on "+" closes what it just opened (toggle)
    host.innerHTML = ""
    // Room for one more widget = the units left after every current widget keeps its minimum (the
    // row is full, so adding always squeezes the others down to their minimums).
    const free = this.rowUnitsValue - this.rowMinUsed(row)
    if (free < 1) {
      // Row full: the "+" is muted but still clickable — show why instead of an empty picker. The
      // hint has no close button; clicking it (or the "+" again) dismisses it.
      const hint = this.cloneTemplate("[data-row-full-template]")
      if (hint) {
        host.appendChild(hint)
        host.classList.remove("hidden")
        hint.focus() // the hint IS the dismiss button
      }
      return
    }
    const picker = this.cloneTemplate("[data-picker-template]")
    this.gatePickerOptions(picker, free)
    host.appendChild(picker)
    host.classList.remove("hidden")
    picker.querySelector("[data-pick]:not([disabled])")?.focus()
  }

  // Disable picker options whose minimum width does not fit `free` units.
  gatePickerOptions(picker, free) {
    picker.querySelectorAll("[data-pick]").forEach((btn) => {
      const fits = parseInt(btn.dataset.units || "1", 10) <= free
      btn.disabled = !fits
      btn.classList.toggle("opacity-40", !fits)
      btn.classList.toggle("pointer-events-none", !fits)
    })
  }

  closePicker(event) {
    const host = event.currentTarget.closest("[data-add-picker-host]")
    if (!host) return
    host.classList.add("hidden")
    host.innerHTML = ""
    host.closest("[data-row]")?.querySelector("[data-add-widget]")?.focus()
  }

  // Insert the chosen widget before the row's "+ widget" column.
  pickWidget(event) {
    const key = event.currentTarget.dataset.pick
    const clone = this.cloneTemplate(`[data-widget-template="${key}"]`)
    if (!clone) return
    const row = event.currentTarget.closest("[data-row]")
    row.querySelector("[data-add-col]").before(clone)
    this.normalizeRow(row) // squeeze the row back to exactly full now the new widget joined it
    const host = row.querySelector("[data-add-picker-host]")
    host.classList.add("hidden")
    host.innerHTML = ""
    this.slotTrigger(clone)?.focus()
    this.refreshSortables()
    this.updateWidthAffordance()
    this.markDirty()
    this.recordHistory()
  }

  // --- Width (units) ---

  // Right-edge pointer drag (primary width control). The boundary with the right neighbour follows
  // the pointer CONTINUOUSLY during the drag (fractional flex-grow on the two slots) and snaps to a
  // whole unit only on release. Continuous feedback matters: a unit is ~1/6 of the row (~200px), so
  // a per-unit snap leaves the first ~half-column a dead zone and the drag feels broken.
  startResize(event) {
    event.preventDefault()
    const handle = event.currentTarget
    const slot = handle.closest("[data-slot]")
    const row = slot.closest("[data-row]")
    if (this.slotsOf(row).length <= 1) return // nothing to redistribute in a single-widget row
    const neighbour = this.resizeNeighbour(slot)
    if (!neighbour) return
    this.resizing = true // suppress the (layout-thrashing) crop re-measure during the live drag

    const container = slot.closest("[data-slots]")
    const unitPx = Math.max(container.getBoundingClientRect().width / this.rowUnitsValue, 1)
    const startX = event.clientX
    const startUnits = this.slotUnits(slot)
    const total = startUnits + this.slotUnits(neighbour) // the two slots share this many units
    const lower = this.slotUnitsMin(slot)
    const upper = total - this.slotUnitsMin(neighbour)
    let live = startUnits
    try { handle.setPointerCapture(event.pointerId) } catch { /* not capturable */ }

    const onMove = (e) => {
      live = Math.min(Math.max(startUnits + (e.clientX - startX) / unitPx, lower), upper)
      slot.style.flex = `${live} 1 0%`            // inline flex overrides the unit class for the drag
      neighbour.style.flex = `${total - live} 1 0%`
    }
    const finish = (commit) => {
      handle.removeEventListener("pointermove", onMove)
      handle.removeEventListener("pointerup", onUp)
      handle.removeEventListener("pointercancel", onCancel)
      slot.style.flex = ""        // hand the width back to the unit class…
      neighbour.style.flex = ""
      this.resizing = false
      if (commit) this.setUnits(slot, Math.round(live)) // …snapped to the nearest whole unit
      if (this.compact) this.markCroppedPreviews()
      this.recordHistory() // one undo step for the whole drag, not one per unit crossed
    }
    const onUp = () => finish(true)
    const onCancel = () => finish(false)
    handle.addEventListener("pointermove", onMove)
    handle.addEventListener("pointerup", onUp)
    handle.addEventListener("pointercancel", onCancel)
  }

  widenWidget(event) {
    const slot = event.currentTarget.closest("[data-slot]")
    this.setUnits(slot, this.slotUnits(slot) + 1)
    this.recordHistory()
  }

  narrowWidget(event) {
    const slot = event.currentTarget.closest("[data-slot]")
    this.setUnits(slot, this.slotUnits(slot) - 1)
    this.recordHistory()
  }

  // The neighbour a width control trades units with: the RIGHT sibling, or the LEFT one for the
  // rightmost widget (which owns no right boundary). The resize handle exists only on non-rightmost
  // widgets, so for the handle this is always the right neighbour.
  resizeNeighbour(slot) {
    const slots = this.slotsOf(slot.closest("[data-row]"))
    const idx = slots.indexOf(slot)
    return slots[idx + 1] || slots[idx - 1] || null
  }

  // Single source of truth for a width change (handle + breiter/schmaler). Moves the boundary
  // between `slot` and its neighbour by a whole number of units, zero-sum (the neighbour takes or
  // gives the same amount), never pushing either below its minimum. The row's Σ units stays
  // invariant — this is the split-pane model.
  setUnits(slot, requested) {
    const neighbour = this.resizeNeighbour(slot)
    if (!neighbour) return this.slotUnits(slot) // single-widget row: nothing to trade with

    const cur = this.slotUnits(slot)
    const nbCur = this.slotUnits(neighbour)
    let delta = requested - cur
    // Clamp to the boundary's travel: neither side may drop below its minimum.
    delta = Math.max(delta, this.slotUnitsMin(slot) - cur)
    delta = Math.min(delta, nbCur - this.slotUnitsMin(neighbour))
    if (delta === 0) return cur

    this.setSlotUnits(slot, cur + delta)
    this.setSlotUnits(neighbour, nbCur - delta)
    this.updateWidthAffordance()
    this.markDirty()
    return cur + delta
  }

  // Bring a row to EXACTLY Σ units == rowUnits after a widget joined (over) or left (under) it.
  // Over: shrink from the right toward each minimum. Under: grow round-robin from the left. Mirrors
  // Dashboards::LayoutEngine.distribute_row_units so the JS and the server render produce the same widths.
  normalizeRow(row) {
    const slots = this.slotsOf(row)
    if (!slots.length) return
    let diff = this.rowUnitsUsed(row) - this.rowUnitsValue
    if (diff > 0) {
      for (const s of [...slots].reverse()) {
        if (diff <= 0) break
        const take = Math.min(this.slotUnits(s) - this.slotUnitsMin(s), diff)
        if (take > 0) { this.setSlotUnits(s, this.slotUnits(s) - take); diff -= take }
      }
    } else if (diff < 0) {
      let need = -diff
      for (let i = 0; need > 0; i++) {
        const s = slots[i % slots.length]
        this.setSlotUnits(s, this.slotUnits(s) + 1)
        need--
      }
    }
  }

  // Enable/disable every width affordance from the live row state, so none is ever dead. Each
  // control is a boundary move, so its availability comes from whether the slot and its neighbour
  // can still give a unit:
  // - resize handle (boundary with the RIGHT neighbour) hidden in single-widget rows and on the
  //   rightmost widget; its icon points only at the direction(s) that can actually move
  // - "schmaler" enabled while this slot is above its minimum; "breiter" while the traded neighbour is
  // - "+ widget" muted (not hidden) when no widget's minimum still fits; clicking it then explains why
  updateWidthAffordance() {
    this.rowsTarget.querySelectorAll("[data-row]").forEach((row) => {
      const slots = this.slotsOf(row)
      const multi = slots.length > 1

      slots.forEach((slot, idx) => {
        const isLast = idx === slots.length - 1
        const rightNb = slots[idx + 1]
        const chipNb = rightNb || slots[idx - 1] // breiter/schmaler trade side (left for rightmost)
        const slotCanGive = this.slotUnits(slot) > this.slotUnitsMin(slot)
        const canTakeFrom = (nb) => !!nb && this.slotUnits(nb) > this.slotUnitsMin(nb)

        const handle = slot.querySelector("[data-slot-resize]")
        if (handle) {
          // Handle owns the boundary with the RIGHT neighbour. Drag left = this slot shrinks (needs
          // slack here); drag right = this slot grows by taking from the right neighbour (needs slack
          // there). Show only when a direction can move, and point the icon at it. Filled carets read
          // far better than thin chevrons at this knob size (↔ both ways, ▶ right only, ◀ left only).
          const canShrink = slotCanGive
          const canGrow = canTakeFrom(rightNb)
          const show = multi && !isLast && (canShrink || canGrow)
          handle.classList.toggle("is-hidden", !show)
          const icon = handle.querySelector(".dashboard-edit-resize-grip i")
          if (icon && show) {
            icon.className = "bi " + (canShrink && canGrow ? "bi-arrow-left-right" : canGrow ? "bi-caret-right-fill" : "bi-caret-left-fill")
          }
        }

        const widenBtn = slot.querySelector("[data-action*='widenWidget']")
        const narrowBtn = slot.querySelector("[data-action*='narrowWidget']")
        if (widenBtn) widenBtn.disabled = !canTakeFrom(chipNb)        // grow by taking from the neighbour
        if (narrowBtn) narrowBtn.disabled = !(chipNb && slotCanGive)  // shrink, giving to the neighbour

        // Reorder chips grey out at the row edges (can't move past the first / last position).
        const leftBtn = slot.querySelector("[data-action*='moveSlotLeft']")
        const rightBtn = slot.querySelector("[data-action*='moveSlotRight']")
        if (leftBtn) leftBtn.disabled = idx === 0
        if (rightBtn) rightBtn.disabled = isLast
      })

      const addCol = row.querySelector("[data-add-col]")
      if (addCol) addCol.classList.toggle("is-full", this.rowUnitsValue - this.rowMinUsed(row) < 1)
    })
    // Re-evaluate which previews are cropped after the layout changed (skipped during a live resize
    // drag, which doesn't change preview heights and would otherwise thrash layout per pixel).
    if (this.compact && !this.resizing) this.markCroppedPreviews()
  }

  // --- Card settings (carried over) ---

  toggleCardSettings(event) {
    const checkbox = event.currentTarget
    const cardRow = checkbox.closest("[data-card-row]")
    cardRow.querySelectorAll("[data-card-setting]").forEach((select) => {
      select.disabled = !checkbox.checked
      select.classList.toggle("opacity-40", !checkbox.checked)
      select.classList.toggle("pointer-events-none", !checkbox.checked)
    })
  }

  // projects_table widget: show the project checkbox list only for the "selected" mode (the other
  // modes — all / pinned / with_entries — compute their set server-side, no picker needed). The
  // checkboxes keep their value while hidden, so switching modes back and forth never loses them.
  toggleProjectSelection(event) {
    const radio = event.currentTarget
    const slot = radio.closest("[data-slot]")
    const picker = slot?.querySelector("[data-project-selection]")
    if (picker) picker.hidden = radio.value !== "selected"
  }

  // my_open_tickets widget: the de-duplicate option only makes sense for stacked sections. In tabs
  // mode only one bucket is ever visible, so there is nothing to de-duplicate — hide the option when
  // "tabs" is chosen. The checkbox keeps its value while hidden, so switching modes never loses it.
  toggleDeduplicate(event) {
    const radio = event.currentTarget
    const slot = radio.closest("[data-slot]")
    const dedup = slot?.querySelector("[data-dedup-option]")
    if (dedup) dedup.hidden = radio.value === "tabs"
  }

  // --- Save scope (radio) + smart folder warning ---

  // Currently selected save_scope radio value (defaults to the surface's personal scope).
  selectedScope() {
    const checked = this.element.querySelector("[name='save_scope']:checked")
    return checked ? checked.value : (this.defaultScopeValue || "personal_this")
  }

  // Re-evaluate the smart folder warning whenever the save target changes.
  changeScope() {
    this.updateSmartFolderWarning()
  }

  // Warn only for the beyond-this-surface scopes (project: the „all projects" scopes), since smart
  // folder ids are project-specific and resolve to nothing in the other projects. This whole method
  // is project-only: the overview has no smartFolderWarning target, so it short-circuits there.
  updateSmartFolderWarning() {
    if (!this.hasSmartFolderWarningTarget) return
    const scope = this.selectedScope()
    const affectsAllProjects = this.confirmScopesValue.includes(scope)
    const hasSmartFolder = !!this.element.querySelector("[data-widget-key='smart_folder_tickets']")
    this.smartFolderWarningTarget.classList.toggle("hidden", !(affectsAllProjects && hasSmartFolder))
  }

  // --- Leave / submit ---

  confirmLeave(event) {
    if (this.dirty && !window.confirm(this.unsavedConfirmValue)) {
      event.preventDefault()
      event.stopPropagation()
    }
  }

  save() {
    this.formTarget.requestSubmit()
  }

  submit(event) {
    if (!this.validateBeforeSubmit()) {
      event.preventDefault()
      return
    }
    this.clearError()
    this.reindex()
    // Confirm before a broad write (project: either „all projects" scope overwrites many layouts).
    const scope = this.selectedScope()
    if (this.confirmScopesValue.includes(scope)) {
      if (this.confirmAllValue && !window.confirm(this.confirmAllValue)) {
        event.preventDefault()
      }
    }
  }

  validateBeforeSubmit() {
    if (this.rowsTarget.querySelectorAll("[data-row]").length === 0) {
      this.showError(this.emptyRowsValue)
      return false
    }
    // A stats-style slot whose picker checkboxes are all unchecked. The server can't tell this apart
    // from "use defaults", so this client guard is the only protection. The guarded widget keys are
    // surface-supplied (project: stats_cards; overview: org_stats_cards + billing_overview). The
    // selector matches any picker suffix ending in `_keys][]` (card_keys, stage_keys, …) so a new
    // picker widget is guarded without touching this code.
    const statsSelector = this.statsWidgetKeysValue.map((k) => `[data-widget-key='${k}']`).join(",")
    const emptyStats = statsSelector && Array.from(this.element.querySelectorAll(statsSelector))
      .find((slot) => slot.querySelectorAll("[data-name-suffix$='_keys][]']:checked").length === 0)
    if (emptyStats) {
      this.showError(this.emptyCardsValue)
      emptyStats.scrollIntoView({ block: "center" })
      this.slotTrigger(emptyStats)?.focus()
      return false
    }
    return true
  }

  showError(message) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }

  clearError() {
    if (this.hasErrorTarget) this.errorTarget.classList.add("hidden")
  }

  // Full rows[i][widgets][j] reindex by DOM position (the critical contract). Width travels as the
  // [units] field via data-name-suffix; there is no row-type or row-height field anymore.
  reindex() {
    const rows = this.rowsTarget.querySelectorAll("[data-row]")
    rows.forEach((row, i) => {
      const slots = row.querySelectorAll("[data-slot]")
      slots.forEach((slot, j) => {
        slot.querySelectorAll("[data-name-suffix]").forEach((field) => {
          field.name = `rows[${i}][widgets][${j}]${field.dataset.nameSuffix}`
        })
      })
    })
  }

  // --- Unit helpers ---

  slotsOf(row) {
    return Array.from(row.querySelectorAll("[data-slot]"))
  }

  rowUnitsUsed(row) {
    return this.slotsOf(row).reduce((sum, slot) => sum + this.slotUnits(slot), 0)
  }

  // Σ of every widget's MINIMUM units — the floor the row can be squeezed to. Room for one more
  // widget = rowUnits − this, since adding shrinks the others down to their minimums.
  rowMinUsed(row) {
    return this.slotsOf(row).reduce((sum, slot) => sum + this.slotUnitsMin(slot), 0)
  }

  slotUnits(slot) {
    return parseInt(slot.dataset.units || "1", 10)
  }

  slotUnitsMin(slot) {
    return parseInt(slot.dataset.unitsMin || "1", 10)
  }

  // Set a slot's rendered width (flex class), its data-units and its serialized [units] input
  // together — the three must never diverge. Flex classes come from the unitFlex value (one source,
  // shared with the Ruby render — see the value definition).
  setSlotUnits(slot, units) {
    slot.dataset.units = units
    slot.classList.remove(...Object.values(this.unitFlexValue))
    slot.classList.add(this.unitFlexValue[units] || this.unitFlexValue[1])
    const input = slot.querySelector("[data-slot-units]")
    if (input) input.value = units
  }

  // --- Helpers ---

  markDirty() {
    this.dirty = true
    if (this.hasUnsavedTarget) this.unsavedTarget.classList.remove("hidden")
  }

  // --- Undo / redo ---

  // Snapshot the current rows HTML as a new history entry; called at the end of every discrete edit.
  // Form state lives in DOM PROPERTIES (a select's value, a checkbox's checked) which innerHTML does
  // not serialize, so freeze it into attributes first — otherwise undo would lose settings changes.
  recordHistory() {
    if (this.restoring) return
    this.freezeFormState()
    const snapshot = this.rowsTarget.innerHTML
    if (this.history[this.historyIndex] === snapshot) return // a no-op edit adds no step
    this.history = this.history.slice(0, this.historyIndex + 1) // a fresh edit drops the redo tail
    this.history.push(snapshot)
    if (this.history.length > this.MAX_HISTORY) this.history.shift()
    this.historyIndex = this.history.length - 1
    this.updateHistoryButtons()
  }

  // Copy each form control's live property into the matching attribute so innerHTML captures it.
  freezeFormState() {
    this.rowsTarget.querySelectorAll("input, select, textarea").forEach((el) => {
      if (el.tagName === "SELECT") {
        Array.from(el.options).forEach((o) => o.toggleAttribute("selected", o.selected))
      } else if (el.type === "checkbox" || el.type === "radio") {
        el.toggleAttribute("checked", el.checked)
      } else {
        el.setAttribute("value", el.value)
      }
    })
  }

  undo() {
    if (this.historyIndex <= 0) return
    this.restore(--this.historyIndex)
  }

  redo() {
    if (this.historyIndex >= this.history.length - 1) return
    this.restore(++this.historyIndex)
  }

  // Replace the rows with a history snapshot and rebuild the live machinery (Sortables, affordances).
  // `restoring` keeps the swap from being recorded as a fresh edit. Dirty tracks distance from the
  // as-loaded state (index 0), so undoing all the way back also clears the unsaved banner.
  restore(index) {
    this.restoring = true
    this.rowsTarget.innerHTML = this.history[index]
    this.refreshSortables()
    this.updateWidthAffordance()
    this.restoring = false
    this.dirty = index > 0
    if (this.hasUnsavedTarget) this.unsavedTarget.classList.toggle("hidden", !this.dirty)
    this.updateHistoryButtons()
  }

  updateHistoryButtons() {
    const setState = (btn, disabled) => {
      if (!btn) return
      btn.disabled = disabled
      // Mirror the design system's disabled look (Neo::Buttons disabled_classes), since this is
      // toggled at runtime rather than at render time.
      btn.classList.toggle("opacity-50", disabled)
      btn.classList.toggle("cursor-not-allowed", disabled)
      btn.classList.toggle("pointer-events-none", disabled)
    }
    setState(this.hasUndoBtnTarget ? this.undoBtnTarget : null, this.historyIndex <= 0)
    setState(this.hasRedoBtnTarget ? this.redoBtnTarget : null, this.historyIndex >= this.history.length - 1)
  }

  // --- Compact view ---

  // Compact crops each preview (CSS .dashboard-edit-compact) so rows stay short and far-away rows are
  // reachable for drag; full mode restores the WYSIWYG previews. Preference is per-browser.
  readCompactPref() {
    try { return localStorage.getItem("dashboardEditCompact") !== "false" } catch { return true }
  }

  toggleCompact() {
    this.compact = !this.compact
    try { localStorage.setItem("dashboardEditCompact", String(this.compact)) } catch { /* private mode */ }
    this.applyCompact(this.compact)
  }

  applyCompact(compact) {
    this.element.classList.toggle("dashboard-edit-compact", compact)
    const btn = this.hasCompactToggleTarget ? this.compactToggleTarget : null
    if (btn) {
      // The icon is the ButtonComponent's own <i> (it carries the standard mr-2 icon→label spacing),
      // so swap ONLY the glyph class and leave the spacing classes intact. The button names the
      // action: in compact it offers the full preview, and vice versa.
      const icon = btn.querySelector("i.bi")
      if (icon) {
        icon.classList.remove("bi-arrows-angle-expand", "bi-arrows-angle-contract")
        icon.classList.add(compact ? "bi-arrows-angle-expand" : "bi-arrows-angle-contract")
      }
      const text = btn.querySelector("[data-compact-text]")
      if (text) text.textContent = compact ? (btn.dataset.labelFull || "") : (btn.dataset.labelCompact || "")
      btn.setAttribute("aria-pressed", String(compact))
    }
    if (compact) this.markCroppedPreviews()
  }

  // Fade only previews actually taller than the cap, so short widgets (e.g. a couple of stat cards)
  // are not faded for no reason.
  markCroppedPreviews() {
    if (!this.compact) return
    this.element.querySelectorAll("[data-preview]").forEach((p) => {
      p.classList.toggle("is-cropped", p.scrollHeight > p.clientHeight + 1)
    })
  }

  // Re-render a settings-bearing widget's front preview from the server with its current (unsaved)
  // settings, so flipping back from the settings form shows the new state at once. Failures are
  // swallowed — a preview that can't refresh must never break the editor.
  refreshPreview(slot) {
    const preview = slot.querySelector("[data-preview]")
    if (!preview || !this.previewUrlValue) return
    // Only settings-bearing widgets need a re-render. data-has-settings is set server-side from the
    // same registry gate as the form, so this never drifts from which widgets actually have settings.
    if (slot.dataset.hasSettings !== "true") return

    const body = new FormData()
    slot.querySelectorAll("[data-name-suffix]").forEach((field) => {
      if (field.disabled) return
      const name = `widget${field.dataset.nameSuffix}`
      // checkbox/radio only contribute when checked, matching the native form submit (otherwise a
      // radio group would send every option's value, and the preview would parse a different mode
      // than the save does).
      if (field.type === "radio") { if (field.checked) body.append(name, field.value); return }
      if (field.type === "checkbox") { if (field.checked) body.append(name, field.value); return }
      body.append(name, field.value)
    })

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.previewUrlValue, { method: "POST", headers: { "X-CSRF-Token": token, Accept: "text/html" }, body })
      .then((r) => (r.ok ? r.text() : null))
      .then((html) => {
        if (html != null) preview.innerHTML = html
        if (this.compact) preview.classList.toggle("is-cropped", preview.scrollHeight > preview.clientHeight + 1)
      })
      .catch(() => {})
  }

  cloneTemplate(selector) {
    const template = this.element.querySelector(`template${selector}`)
    if (!template) return null
    return template.content.firstElementChild.cloneNode(true)
  }
}
