import { Controller } from "@hotwired/stimulus"
import { assigneeDiff } from "assignee_menu/diff"

// Connects to data-controller="inline-assignees"
// The people menu of the ticket head (user, 09.09.2026): the segment that
// shows the assignees is a button, the menu lists everyone who may be
// assigned with a tick each. Ticks change the menu alone. Closing the menu
// (outside click, Escape, "Fertig") sends the difference to what the menu
// showed when it opened as ONE add/remove change through the form, the same
// endpoint the status beside it uses; no difference, no request.
//
// Sent on closing and not per tick, because the response replaces the whole
// head, this menu included: a request per tick would shut the menu under the
// hand that is still ticking.
export default class extends Controller {
  static targets = ["form", "menu", "badge", "option"]

  connect() {
    this.closeOnClickOutside = this.closeOnClickOutside.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)
  }

  disconnect() {
    this.stopListening()
  }

  toggle(event) {
    event.stopPropagation()
    this.isOpen ? this.close() : this.open()
  }

  get isOpen() {
    return this.hasMenuTarget && !this.menuTarget.classList.contains("hidden")
  }

  open() {
    if (!this.hasMenuTarget) return
    this.shown = this.checkedIds()
    this.menuTarget.classList.remove("hidden")
    if (this.hasBadgeTarget) this.badgeTarget.setAttribute("aria-expanded", "true")
    document.addEventListener("click", this.closeOnClickOutside)
    // Capture phase: the lane's own Escape listener sits on the document too
    // (layout_toggle_controller), registered long before this menu opened,
    // and a listener on the same node cannot be stopped by a later one in the
    // same phase. Capturing runs first, and stopping there ends the event
    // before the lane hears it.
    document.addEventListener("keydown", this.closeOnEscape, true)
  }

  // "Fertig" closes like any other way out.
  done() {
    this.close()
  }

  close() {
    if (!this.isOpen) return
    this.menuTarget.classList.add("hidden")
    if (this.hasBadgeTarget) this.badgeTarget.setAttribute("aria-expanded", "false")
    this.stopListening()
    this.send(assigneeDiff(this.shown, this.checkedIds()))
  }

  send({ add, remove }) {
    if (add.length === 0 && remove.length === 0) return
    if (!this.hasFormTarget) return
    this.formTarget.querySelectorAll("[data-diff]").forEach(input => input.remove())
    add.forEach(id => this.formTarget.append(this.hiddenInput("add[]", id)))
    remove.forEach(id => this.formTarget.append(this.hiddenInput("remove[]", id)))
    this.formTarget.requestSubmit()
  }

  hiddenInput(name, value) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    input.dataset.diff = ""
    return input
  }

  checkedIds() {
    return this.optionTargets.filter(option => option.checked).map(option => option.value)
  }

  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  ownsEscape() {
    return this.isOpen
  }

  closeOnEscape(event) {
    if (event.key !== "Escape") return
    // The menu takes the Escape; the lane behind it stays open (see open()).
    event.stopPropagation()
    this.close()
  }

  stopListening() {
    document.removeEventListener("click", this.closeOnClickOutside)
    document.removeEventListener("keydown", this.closeOnEscape, true)
  }
}
