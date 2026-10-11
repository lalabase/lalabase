import { Controller } from "@hotwired/stimulus"
import { trapTabKey } from "dialog_a11y"

// "Notizblock" slide-over drawer (left), body-level.
//
// Mounted on <body> so the trigger in the (transformed) sidebar bottom-tray can
// open the body-level drawer whose position:fixed must not be clipped by the
// sidebar's transform/overflow. Mechanics mirror search_overlay_controller
// (open/close/ESC/backdrop/focus restore) plus a left slide animation and a
// lazy turbo-frame that loads the panel on first open and refreshes on reopen.
//
// DELIBERATE DUPLICATION: contextual_help_drawer_controller mirrors this
// open/close/backdrop/slide mechanic for the right-hand help drawer (its frame
// src is dynamic, so the lazy-load differs). Second case — if a THIRD drawer
// appears, extract a shared drawer base (tab-trap/announce already live in
// lib/dialog_a11y.js).
export default class extends Controller {
  static targets = ["overlay", "panel", "frame"]

  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    window.clearTimeout(this.hideTimeout)
    document.body.classList.remove("modal-open")
  }

  // Start closed even if a Turbo cache snapshot restored the drawer open.
  overlayTargetConnected(element) {
    element.classList.add("hidden")
    document.body.classList.remove("modal-open")
  }

  open(event) {
    if (event) event.preventDefault()
    if (!this.hasOverlayTarget) return
    // Cancel a pending hide from close() — a reopen within the 200ms slide-out
    // would otherwise be hidden by the stale timeout (invisible open drawer).
    window.clearTimeout(this.hideTimeout)

    // Remember the trigger so close() can return focus there (keyboard/a11y).
    this.previouslyFocused = document.activeElement
    this.overlayTarget.classList.remove("hidden")
    document.body.classList.add("modal-open")
    this.loadFrame()

    // Next frame: drop the off-screen transform so the panel slides in.
    requestAnimationFrame(() => {
      if (this.hasPanelTarget) this.panelTarget.classList.remove("-translate-x-full")
    })
  }

  close() {
    if (!this.hasOverlayTarget) return
    if (this.hasPanelTarget) this.panelTarget.classList.add("-translate-x-full")
    document.body.classList.remove("modal-open")

    // Hide after the slide-out finishes so the transition is visible.
    window.clearTimeout(this.hideTimeout)
    this.hideTimeout = window.setTimeout(() => this.overlayTarget.classList.add("hidden"), 200)

    if (this.previouslyFocused && this.previouslyFocused.focus) this.previouslyFocused.focus()
    this.previouslyFocused = null
  }

  // Load the panel on first open; refresh it on subsequent opens so the list is
  // never stale. The quick-add input carries autofocus, so Turbo focuses it once
  // the frame finishes rendering.
  loadFrame() {
    if (!this.hasFrameTarget) return
    const src = this.frameTarget.dataset.src
    if (!this.frameTarget.getAttribute("src")) {
      this.frameTarget.setAttribute("src", src)
    } else {
      this.frameTarget.reload()
    }
  }

  // Close only when the click lands on the backdrop, not inside the panel.
  closeOnBackdrop(event) {
    if (this.hasPanelTarget && this.panelTarget.contains(event.target)) return
    this.close()
  }

  handleKeydown(event) {
    if (!this.hasOverlayTarget || this.overlayTarget.classList.contains("hidden")) return

    if (event.key === "Escape") {
      this.close()
      return
    }

    // Tab trap shared with the other dialogs (dialog_a11y) — replacing the
    // inline copy also fixes its drifted selector (select/textarea missing).
    if (this.hasPanelTarget) trapTabKey(event, this.panelTarget)
  }
}
