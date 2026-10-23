import { Controller } from "@hotwired/stimulus"
import { MIN_LIST_PX, MIN_LANE_PX } from "lane/meeting_panel_stage"

// The split between the list and the lane, dragged at the line that separates
// them (layout.css, ".layout--lane" and ".lane-split").
//
// ONE value owns it: --list-split on the grid. The list track reads it, and so
// does the handle's own left offset, so the handle cannot drift away from the
// boundary it moves - the commonest bug in a resizer is a handle that is drawn
// from one number and drags another.
//
// Stored as a PERCENTAGE, applied as pixels. A pixel width remembered on a wide
// screen leaves a phone-sized list on a laptop; a percentage survives the window
// changing size, which is the whole reason to remember it at all.
export default class extends Controller {
  static targets = ["handle"]
  static values = { storageKey: String }

  // The list stays wide enough for a number, a title and one more column; the
  // lane wide enough for the running text it exists for. Below either the split
  // stops - a resizer that can hide a pane is a resizer that loses one. The
  // numbers live in lib/lane/meeting_panel_stage, which decides from the same
  // two how much of the meeting beside a ticket fits.
  static MIN_LIST_PX = MIN_LIST_PX
  static MIN_LANE_PX = MIN_LANE_PX
  static KEYBOARD_STEP_PX = 32
  static DEFAULT_SHARE = 0.4

  connect() {
    // For the stylesheet: with the meeting panel open on a wide grid the list
    // keeps its SHARE of what the panel leaves (layout.css, "wide"), held
    // between the same two minimums the drag is held between.
    this.element.style.setProperty("--list-min", `${MIN_LIST_PX}px`)
    this.element.style.setProperty("--lane-min", `${MIN_LANE_PX}px`)
    this.onWindowResize = this.onWindowResize.bind(this)
    this.onPointerMove = this.onPointerMove.bind(this)
    this.onPointerUp = this.onPointerUp.bind(this)
    window.addEventListener("resize", this.onWindowResize)
    this.apply(this.storedShare)
  }

  disconnect() {
    window.removeEventListener("resize", this.onWindowResize)
    this.stopDragging()
  }

  // --- the one value ------------------------------------------------------

  get gridWidth() {
    return this.element.getBoundingClientRect().width
  }

  get storageKey() {
    return `lalabase:lane-split:${this.storageKeyValue || "default"}`
  }

  get storedShare() {
    // A share of the grid's width, 0..1. Storage can be gone (private window,
    // cleared data) or throw outright, so every read falls back to the default.
    try {
      const raw = window.localStorage.getItem(this.storageKey)
      const share = raw === null ? NaN : parseFloat(raw)
      return Number.isFinite(share) ? share : this.constructor.DEFAULT_SHARE
    } catch {
      return this.constructor.DEFAULT_SHARE
    }
  }

  store(share) {
    try {
      window.localStorage.setItem(this.storageKey, String(share))
    } catch {
      // A split nobody can remember is still a split that works now.
    }
  }

  clamp(px) {
    const { MIN_LIST_PX, MIN_LANE_PX } = this.constructor
    const max = this.gridWidth - MIN_LANE_PX
    if (max <= MIN_LIST_PX) return MIN_LIST_PX
    return Math.min(Math.max(px, MIN_LIST_PX), max)
  }

  // Writes the value everything else reads. Never called with a share the
  // window cannot hold: clamp() is the single place that knows the bounds.
  apply(share) {
    const px = this.clamp(share * this.gridWidth)
    this.element.style.setProperty("--list-split", `${Math.round(px)}px`)
    // The share actually applied (after the clamp); a grid not laid out yet has no
    // width to divide by and keeps the share it was asked for.
    this.element.style.setProperty("--list-share", String(this.gridWidth ? px / this.gridWidth : share))
    this.currentPx = px

    if (!this.hasHandleTarget) return
    this.handleTarget.setAttribute("aria-valuenow", String(Math.round((px / this.gridWidth) * 100)))
  }

  onWindowResize() {
    // The remembered SHARE, re-measured - not the pixels currently set. Reading
    // the pixels back would ratchet the list smaller on every resize, because
    // each clamp would become the new remembered width.
    this.apply(this.storedShare)
  }

  // --- dragging -----------------------------------------------------------

  start(event) {
    if (event.button !== undefined && event.button !== 0) return
    event.preventDefault()

    // The distance from the pointer to the boundary, kept for the whole drag.
    // Without it the boundary jumps under the cursor on the first move by
    // however far from its centre the handle was grabbed.
    this.grabOffset = event.clientX - this.element.getBoundingClientRect().left - this.currentPx
    this.element.classList.add("layout--resizing")
    document.body.style.userSelect = "none"
    document.body.style.cursor = "col-resize"

    if (event.pointerId !== undefined && this.hasHandleTarget) {
      this.pointerId = event.pointerId
      this.handleTarget.setPointerCapture(event.pointerId)
    }
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("pointercancel", this.onPointerUp)
  }

  onPointerMove(event) {
    const px = event.clientX - this.element.getBoundingClientRect().left - this.grabOffset
    this.apply(this.clamp(px) / this.gridWidth)
  }

  onPointerUp() {
    this.store(this.currentPx / this.gridWidth)
    this.stopDragging()
  }

  stopDragging() {
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("pointercancel", this.onPointerUp)
    this.element.classList.remove("layout--resizing")
    document.body.style.userSelect = ""
    document.body.style.cursor = ""

    if (this.pointerId !== undefined && this.hasHandleTarget) {
      if (this.handleTarget.hasPointerCapture(this.pointerId)) {
        this.handleTarget.releasePointerCapture(this.pointerId)
      }
      this.pointerId = undefined
    }
  }

  // --- keyboard and reset --------------------------------------------------

  nudge(event) {
    const step = { ArrowLeft: -1, ArrowRight: 1 }[event.key]
    if (!step) return

    event.preventDefault()
    const px = this.clamp(this.currentPx + step * this.constructor.KEYBOARD_STEP_PX)
    this.apply(px / this.gridWidth)
    this.store(px / this.gridWidth)
  }

  // A double click puts the split back where it started. The way out of a
  // dragged layout should not be more dragging.
  reset(event) {
    event.preventDefault()
    this.apply(this.constructor.DEFAULT_SHARE)
    this.store(this.constructor.DEFAULT_SHARE)
  }
}
