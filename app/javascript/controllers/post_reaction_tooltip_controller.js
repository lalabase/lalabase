import { Controller } from "@hotwired/stimulus"

// Inspecting a chip must never also toggle it. Long presses share the mobile
// list's 450ms / 10px gesture boundary and consume only their ensuing click.
export default class extends Controller {
  static values = { text: String }

  disconnect() {
    this.cancelPress()
    this.hide()
  }

  show(event) {
    if (event && this.touching) return
    if (this.tooltip) return
    this.tooltip = document.createElement('div')
    this.tooltip.className = 'post-reaction-tooltip'
    this.tooltip.id = `reaction-tooltip-${crypto.randomUUID()}`
    this.tooltip.setAttribute('role', 'tooltip')
    this.tooltip.setAttribute('popover', 'manual')
    this.tooltip.textContent = this.textValue
    document.body.append(this.tooltip)
    this.tooltip.showPopover?.()
    this.described = this.element.querySelector('button, [tabindex]')
    this.described?.setAttribute('aria-describedby', this.tooltip.id)
    const rect = this.element.getBoundingClientRect()
    const box = this.tooltip.getBoundingClientRect()
    this.tooltip.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - box.width - 8))}px`
    this.tooltip.style.top = `${Math.max(8, rect.top - box.height - 6)}px`
    this.boundHide = () => this.hide()
    window.addEventListener('scroll', this.boundHide, true)
    window.addEventListener('resize', this.boundHide)
  }

  hide(event) {
    if (event?.key === 'Escape' && this.tooltip) {
      event.preventDefault()
      event.stopPropagation()
    }
    clearTimeout(this.hideTimer)
    this.tooltip?.remove()
    this.tooltip = null
    this.described?.removeAttribute('aria-describedby')
    window.removeEventListener('scroll', this.boundHide, true)
    window.removeEventListener('resize', this.boundHide)
  }

  startPress(event) {
    this.suppressClickUntil = 0
    if (event.pointerType === 'mouse') return
    this.cancelPress()
    this.touching = true
    this.origin = { x: event.clientX, y: event.clientY }
    this.pressTimer = setTimeout(() => {
      this.longPressed = true
      this.suppressClickUntil = Date.now() + 1200
      this.show()
    }, 450)
  }

  movePress(event) {
    if (this.origin && Math.hypot(event.clientX - this.origin.x, event.clientY - this.origin.y) > 10) {
      this.cancelPress()
      this.hide()
    }
  }

  endPress() {
    clearTimeout(this.pressTimer)
    if (this.longPressed) {
      this.suppressClickUntil = Date.now() + 1200
      this.hideTimer = setTimeout(() => this.hide(), 2000)
    }
    this.origin = null
    this.touching = false
    this.longPressed = false
  }

  cancelPress() {
    clearTimeout(this.pressTimer)
    this.origin = null
    this.touching = false
    this.longPressed = false
    this.hide()
  }

  contextMenu(event) {
    if (this.touching || Date.now() < this.suppressClickUntil) event.preventDefault()
  }

  click(event) {
    if (Date.now() < this.suppressClickUntil) {
      this.suppressClickUntil = 0
      event.preventDefault()
      event.stopImmediatePropagation()
    }
  }
}
