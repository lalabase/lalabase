import { Controller } from "@hotwired/stimulus"

// Global search overlay (command-palette style).
//
// Mounted on <body> so the "Suche" nav item (inside the transformed sidebar) and the
// Cmd/Ctrl+K shortcut can both open the body-level overlay. The overlay markup lives
// outside the sidebar's transform/overflow, so its position:fixed is not clipped.
export default class extends Controller {
  static targets = ["overlay", "panel"]

  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    document.body.classList.remove("modal-open")
  }

  // Start closed even if a Turbo cache snapshot restored the overlay open.
  overlayTargetConnected(element) {
    element.classList.add("hidden")
    document.body.classList.remove("modal-open")
  }

  // Entry point for the "Suche" nav item and Cmd/Ctrl+K. When the search bar is
  // pinned (Stage 2b), a persistent inline bar is in the DOM -> focus it instead of
  // opening the overlay. Otherwise open the overlay.
  open(event) {
    if (event) event.preventDefault()
    const inlineInput = document.querySelector('#global-search-inline-bar input[type="text"]')
    if (inlineInput) {
      inlineInput.focus()
      inlineInput.select()
      return
    }
    this.showOverlay()
  }

  showOverlay() {
    if (!this.hasOverlayTarget) return
    // Remember what had focus (the "Suche" trigger, or wherever Cmd+K was pressed) so
    // close() can return focus there instead of dumping it on <body> — keyboard/a11y.
    this.previouslyFocused = document.activeElement
    this.overlayTarget.classList.remove("hidden")
    // `modal-open` is the shared body class every modal in this app toggles. NOTE: there
    // is currently NO global `.modal-open` CSS rule, so this does not lock body scroll
    // today — it is kept only for consistency/forward-compat (add the rule once and every
    // modal benefits). Don't read this as "scroll is locked behind the overlay".
    document.body.classList.add("modal-open")
    this.focusInput()
  }

  close() {
    if (!this.hasOverlayTarget) return
    this.overlayTarget.classList.add("hidden")
    document.body.classList.remove("modal-open")
    // Return focus to the trigger captured in showOverlay (keyboard users).
    if (this.previouslyFocused && this.previouslyFocused.focus) {
      this.previouslyFocused.focus()
    }
    this.previouslyFocused = null
  }

  toggle(event) {
    if (this.hasOverlayTarget && !this.overlayTarget.classList.contains("hidden")) {
      this.close()
    } else {
      this.open(event)
    }
  }

  // Close only when the click lands on the backdrop, not inside the panel.
  closeOnBackdrop(event) {
    if (this.hasPanelTarget && this.panelTarget.contains(event.target)) return
    this.close()
  }

  focusInput() {
    const input = this.overlayTarget.querySelector("input[type='text']")
    if (input) {
      input.focus()
      input.select()
    }
  }

  handleKeydown(event) {
    if ((event.metaKey || event.ctrlKey) && event.key === "k") {
      event.preventDefault()
      this.toggle(event)
    }

    if (event.key === "Escape" && this.ownsEscape()) {
      this.close()
    }
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  ownsEscape() {
    return this.hasOverlayTarget && !this.overlayTarget.classList.contains("hidden")
  }
}
