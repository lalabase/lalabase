import { Controller } from "@hotwired/stimulus"

// The air the panel keeps to the edge of the box it is aligned in.
const PANEL_INSET_PX = 16

// Click-triggered popover with inline content. Closes on outside click + Escape.
export default class extends Controller {
  static targets = ["panel"]

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.panelTarget.classList.contains("hidden")) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.panelTarget.classList.remove("hidden")
    this.alignPanel()
  }

  // Keeps an anchored panel inside the viewport: the trigger can sit at the
  // far right of its row, where a left-anchored wide panel runs off screen —
  // then it anchors right instead. Measured on every open AND on every frame
  // load (openOnFrameLoad), because a lazy frame's placeholder is narrower
  // than its loaded content. The phone sheet is position:fixed and needs none
  // of this.
  // The panel stays inside the box that would clip it: the nearest ancestor
  // that scrolls or hides its overflow (the lane column of the ticket page,
  // .column.content), or the viewport where there is none. It is moved LEFT
  // by exactly the overflow, never past that box's left edge. It used to flip
  // to right: 0 at the trigger when it hit the viewport; in a lane whose
  // right edge lies far inside the viewport that kept it hanging out of the
  // lane's LEFT edge, where the column's overflow cut the form off
  // (user, 09.09.2026).
  alignPanel() {
    const panel = this.panelTarget
    if (getComputedStyle(panel).position !== "absolute") return

    panel.style.left = ""
    panel.style.right = ""
    const bounds = this.clippingBounds()
    const rect = panel.getBoundingClientRect()
    const overflowRight = rect.right - (bounds.right - PANEL_INSET_PX)
    if (overflowRight <= 0) return

    const room = rect.left - (bounds.left + PANEL_INSET_PX)
    const shift = Math.min(overflowRight, Math.max(room, 0))
    if (shift > 0) panel.style.left = `${panel.offsetLeft - shift}px`
  }

  clippingBounds() {
    let node = this.element.parentElement
    while (node && node !== document.body) {
      const { overflowX, overflowY } = getComputedStyle(node)
      if (/auto|hidden|scroll|clip/.test(`${overflowX} ${overflowY}`)) return node.getBoundingClientRect()
      node = node.parentElement
    }
    return { left: 0, right: document.documentElement.clientWidth }
  }

  close() {
    this.panelTarget.classList.add("hidden")
  }

  // A frame load inside the wrapper opens the panel: the timeline's pencil
  // navigates the popover frame from OUTSIDE this controller's scope, and the
  // loaded edit form must become visible where it lives — at the chip. A load
  // while the panel is already open (row click, cancel link, first lazy load)
  // changes nothing.
  openOnFrameLoad() {
    if (this.panelTarget.classList.contains("hidden")) {
      this.open()
      this.element.scrollIntoView({ block: "nearest" })
    } else {
      // Already open: the loaded content is wider than the placeholder was.
      this.alignPanel()
    }
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && !this.panelTarget.classList.contains("hidden")) {
      this.close()
    }
  }

  closeOnOutsideClick(event) {
    if (this.panelTarget.classList.contains("hidden")) return
    if (this.element.contains(event.target)) return
    this.close()
  }
}
