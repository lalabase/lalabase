import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"
import { trapTabKey, announcePolitely } from "dialog_a11y"

export default class extends Controller {
  static targets = ["modal", "backdrop", "content", "focusTrap"]
  static values = { context: String }

  connect() {
    // Bind ESC key handler
    this.handleKeydown = this.handleKeydown.bind(this)

    // Cache DOM references before any teleporting
    // (Stimulus targets break once element leaves controller subtree)
    this._modal = this.modalTarget
    this._backdrop = this.backdropTarget
    this._content = this.contentTarget
  }

  open(event) {
    event.preventDefault()

    // Teleport modal to body so `position: fixed` isn't constrained
    // by ancestor `transform` transitions (e.g. .column in labor.css)
    this._originalParent = this._modal.parentElement
    document.body.appendChild(this._modal)

    // Since modal is now outside the controller subtree, Stimulus
    // data-action attributes won't fire. Use manual event delegation.
    this._handleModalClick = (e) => {
      const target = e.target
      if (target === this._backdrop || target.closest('[data-action*="help-modal#close"]')) {
        e.preventDefault()
        this.close()
      }
    }
    this._modal.addEventListener("click", this._handleModalClick)

    // Show modal
    this._modal.classList.remove("hidden")
    document.body.style.overflow = "hidden"

    // Add event listeners
    document.addEventListener("keydown", this.handleKeydown)

    // Focus management
    this.previousFocus = document.activeElement
    this._modal.focus()

    // Announce to screen readers
    this.announce(I18n.t('stimulus.help_modal.opened'))

    // Animate in
    requestAnimationFrame(() => {
      this._backdrop.classList.add("opacity-100")
      this._content.classList.add("scale-100", "opacity-100")
    })
  }

  close(event) {
    if (event) event.preventDefault()

    // Animate out
    this._backdrop.classList.remove("opacity-100")
    this._content.classList.remove("scale-100", "opacity-100")

    // Hide modal after animation
    setTimeout(() => {
      this._modal.classList.add("hidden")
      document.body.style.overflow = ""

      // Remove manual click delegation
      if (this._handleModalClick) {
        this._modal.removeEventListener("click", this._handleModalClick)
        this._handleModalClick = null
      }

      // Move modal back to original parent so Stimulus stays connected
      if (this._originalParent) {
        this._originalParent.appendChild(this._modal)
        this._originalParent = null
      }

      // Remove event listeners
      document.removeEventListener("keydown", this.handleKeydown)

      // Restore focus
      if (this.previousFocus) {
        this.previousFocus.focus()
      }

      // Announce to screen readers
      this.announce(I18n.t('stimulus.help_modal.closed'))
    }, 200)
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      this.close()
    }

    // Tab trap within modal (shared with the contextual-help drawer, dialog_a11y)
    trapTabKey(event, this._modal)
  }

  announce(message) {
    announcePolitely(message, "help-modal-announcer")
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)

    // Clean up modal click handler if modal was open during disconnect
    if (this._handleModalClick && this._modal) {
      this._modal.removeEventListener("click", this._handleModalClick)
      this._handleModalClick = null
    }

    // Move modal back to original parent if it was teleported
    if (this._originalParent && this._modal) {
      this._modal.classList.add("hidden")
      this._originalParent.appendChild(this._modal)
      this._originalParent = null
    }

    document.body.style.overflow = ""
  }
}
