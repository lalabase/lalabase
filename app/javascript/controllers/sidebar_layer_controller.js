import { Controller } from "@hotwired/stimulus"

// The account layer of the sidebar (common/_account_layer, Belegungstabelle F47):
// a click on the reader's name raises the pages of "Mein Konto" over the sidebar,
// and the page behind stays.
//
// Mounted on the sidebar itself, because it reaches three things in it: the name at
// its foot (trigger), the layer (panel) and what the layer covers (covered).
//
// Opens and closes by attributes; the look and the slide are CSS
// (components/sidebar_layer.css):
//   panel    hidden while it is away, data-state="open" while it stands
//   trigger  aria-expanded
//   covered  inert while it is covered: it is still in the page, and without
//            this the keyboard would walk through links nobody can see
//
// The trigger is a plain link to the account page, which is what happens without
// this script. Here it becomes a button; a click with a modifier key stays a link
// (a new tab is a fair wish).
//
// Closes on the name again, the cross, Escape (focus back to the name), a press
// outside the layer, and before Turbo keeps the page for its cache: a snapshot
// with the layer up would show it again on Back.
export default class extends Controller {
  static targets = ["trigger", "panel", "covered"]

  connect() {
    if (!this.hasTriggerTarget || !this.hasPanelTarget) return

    this.triggerTarget.setAttribute("role", "button")
    this.triggerTarget.setAttribute("aria-expanded", "false")

    this.closeOnOutsidePress = this.closeOnOutsidePress.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)
    this.reset = this.reset.bind(this)
    document.addEventListener("pointerdown", this.closeOnOutsidePress)
    document.addEventListener("keydown", this.closeOnEscape)
    document.addEventListener("turbo:before-cache", this.reset)
  }

  disconnect() {
    clearTimeout(this.hideTimer)
    document.removeEventListener("pointerdown", this.closeOnOutsidePress)
    document.removeEventListener("keydown", this.closeOnEscape)
    document.removeEventListener("turbo:before-cache", this.reset)
  }

  toggle(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button > 0) return

    event.preventDefault()
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    clearTimeout(this.hideTimer)
    const panel = this.panelTarget
    panel.hidden = false
    // The layer has to be painted where it waits before it is told where to go,
    // or there is no way between the two and it simply appears.
    void panel.offsetHeight
    panel.dataset.state = "open"
    this.triggerTarget.setAttribute("aria-expanded", "true")
    this.coveredTargets.forEach((covered) => { covered.inert = true })
    // The layer stands before the name in the page: without this, Tab from the
    // name would leave the sidebar instead of entering what just opened.
    panel.querySelector("a[href]")?.focus({ preventScroll: true })
  }

  // Also the cross's action. `focus: true` from the keyboard: Escape gives the
  // focus back to the name; a press elsewhere keeps it where the reader put it.
  close({ focus = false } = {}) {
    if (!this.isOpen) return

    const panel = this.panelTarget
    delete panel.dataset.state
    this.triggerTarget.setAttribute("aria-expanded", "false")
    this.coveredTargets.forEach((covered) => { covered.inert = false })
    if (focus === true || panel.contains(document.activeElement)) this.triggerTarget.focus({ preventScroll: true })

    // Away once it has slid out. The duration is read, not assumed: with reduced
    // motion there is no transition and no end event to wait for.
    const duration = parseFloat(getComputedStyle(panel).transitionDuration) * 1000
    clearTimeout(this.hideTimer)
    if (duration > 0) {
      this.hideTimer = setTimeout(() => this.hide(), duration)
    } else {
      this.hide()
    }
  }

  hide() {
    if (!this.isOpen) this.panelTarget.hidden = true
  }

  // Before Turbo's snapshot: closed at once, without the slide.
  reset() {
    clearTimeout(this.hideTimer)
    if (!this.hasPanelTarget) return

    delete this.panelTarget.dataset.state
    this.panelTarget.hidden = true
    if (this.hasTriggerTarget) this.triggerTarget.setAttribute("aria-expanded", "false")
    this.coveredTargets.forEach((covered) => { covered.inert = false })
  }

  get isOpen() {
    return this.hasPanelTarget && this.panelTarget.dataset.state === "open"
  }

  // Escape owner (lib/escape_owner.js): a detail lane behind stays open while the
  // layer is up; this Escape closes the layer.
  ownsEscape() {
    return this.isOpen
  }

  closeOnEscape(event) {
    if (event.key !== "Escape" || !this.isOpen) return

    this.close({ focus: true })
  }

  closeOnOutsidePress(event) {
    if (!this.isOpen) return
    if (this.panelTarget.contains(event.target) || this.triggerTarget.contains(event.target)) return

    this.close()
  }
}
