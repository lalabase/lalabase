import { Controller } from "@hotwired/stimulus"
import { menuShift } from "menu_fit"

// Floating org-switcher menu (the <details> in _navigation_application).
//
// The panel target is positioned as an OVERLAY (CSS position:absolute, anchored to the #sidebar
// aside) instead of sitting in the sidebar's scroll flow. Opening it therefore does NOT grow the
// sidebar's overflow-y-auto column, so no scrollbar appears and the nav below does not jump. The
// absolute panel escapes that column's clipping because its containing block is the aside — an
// ancestor of the column — while staying inside the sidebar bounds. A JS max-height caps it to the
// viewport so a long list scrolls INSIDE the panel.
//
// Also handled here: close on outside pointerdown / Escape (with focus return), and #stop for a
// control inside the summary (the manage-org gear) that must navigate without toggling the menu.
export default class extends Controller {
  static targets = ["panel", "menu"]

  // ⚠️ fit is bound HERE, once, and not in connect(). Stimulus connects a
  // target before its controller, so menuTargetConnected registered fit before
  // connect() had bound it: the window called it with `this` as the window, it
  // did nothing, and the rebinding in connect() left a reference that
  // removeEventListener could never match, one more listener per reconnect
  // (third review of #932).
  initialize() {
    this.fit = this.fit.bind(this)
  }

  connect() {
    this.closeOnOutsideClick = this.closeOnOutsideClick.bind(this)
    this.closeOnEscape = this.closeOnEscape.bind(this)
    this.reposition = this.reposition.bind(this)
    document.addEventListener("pointerdown", this.closeOnOutsideClick)
    document.addEventListener("keydown", this.closeOnEscape)
  }

  // A filter menu is placed again whenever its size changes, and whenever the
  // screen does (second review of #932). Its size changes when it opens (a
  // closed <details> lays nothing out), when a section of "+ Filter" unfolds
  // inside it, and when the drawer around a menu that was ALREADY open (the
  // custom period) is shown. The toggle event alone saw none but the first,
  // and not a phone turned sideways. A ResizeObserver reports after layout and
  // before paint, so the menu is drawn in place from its first frame.
  //
  // The window's resize covers what the observer cannot see: the screen
  // changes while the menu keeps its size, and its pill moves (a desktop
  // window narrowed from 1400 to 1200 px; mobile_shell_regressions_spec).
  menuTargetConnected(menu) {
    this.menuObserver = new ResizeObserver(() => this.fit())
    this.menuObserver.observe(menu)
    window.addEventListener("resize", this.fit)
  }

  menuTargetDisconnected() {
    this.menuObserver?.disconnect()
    this.menuObserver = null
    window.removeEventListener("resize", this.fit)
  }

  disconnect() {
    document.removeEventListener("pointerdown", this.closeOnOutsideClick)
    document.removeEventListener("keydown", this.closeOnEscape)
    this.untrack()
  }

  // Fired by the <details> `toggle` event. Position the overlay while open; keep it glued to the
  // summary as long as it stays open (scroll uses capture so the sidebar's inner scroll counts).
  onToggle() {
    if (this.element.open) {
      this.reposition()
      window.addEventListener("scroll", this.reposition, true)
      window.addEventListener("resize", this.reposition)
    } else {
      this.untrack()
      if (this.hasPanelTarget) this.panelTarget.style.opacity = ""
    }
  }

  untrack() {
    window.removeEventListener("scroll", this.reposition, true)
    window.removeEventListener("resize", this.reposition)
  }

  // Anchor the absolute panel just below the summary, offsets measured relative to the aside (its
  // containing block). Cap the height to the space left down to the viewport bottom so it never
  // overflows the sidebar — the panel scrolls internally instead.
  reposition() {
    if (!this.hasPanelTarget) return
    const summary = this.element.querySelector("summary")
    if (!summary) return
    const base = (this.element.closest("#sidebar") || document.body).getBoundingClientRect()
    const rect = summary.getBoundingClientRect()
    const gap = 6
    const inset = 8
    const margin = 12
    this.panelTarget.style.top = `${rect.bottom - base.top + gap}px`
    this.panelTarget.style.left = `${rect.left - base.left + inset}px`
    this.panelTarget.style.width = `${rect.width - inset * 2}px`
    this.panelTarget.style.maxHeight = `${window.innerHeight - rect.bottom - gap - margin}px`
    this.panelTarget.style.opacity = "1"
  }

  // Keeps an opened filter menu on the screen (shared/_filter_pill, review of
  // #932). The menu hangs from its pill and on a phone could reach past the
  // edge; its width is capped in CSS, this moves it sideways by what
  // menuShift answers. The shift is cleared first, so every measurement is of
  // the menu where the CSS put it. Run by the observer and the resize
  // listener above; a closed menu is left alone.
  //
  // ⚠️ Moved through `left`, not a transform. A transform moves what is drawn,
  // but Chrome kept the page as wide as the unmoved menu, so the page still
  // scrolled sideways (measured on the billings' project menu, 375 px). `left`
  // from the menu's own offset also covers an end-aligned menu, whose `right`
  // is released for it.
  fit() {
    if (!this.hasMenuTarget || !this.element.open) return
    const menu = this.menuTarget
    menu.style.left = ""
    menu.style.right = ""
    const shift = menuShift(menu.getBoundingClientRect(), document.documentElement.clientWidth)
    if (shift === 0) return
    menu.style.left = `${menu.offsetLeft + shift}px`
    menu.style.right = "auto"
  }

  // A control INSIDE the summary (the manage-org gear) that must navigate without toggling the
  // disclosure calls this: stopping propagation keeps the click from reaching the summary, so the
  // link follows through while the menu stays put.
  stop(event) {
    event.stopPropagation()
  }

  // Closing on purpose, from a control inside the panel. The custom period's
  // apply button used to walk the DOM for its own <details> and strip the
  // attribute -- a third way of closing a disclosure this controller already
  // owns, on an element it is already mounted on.
  close() {
    this.element.open = false
  }

  closeOnOutsideClick(event) {
    if (this.element.open && !this.element.contains(event.target)) {
      this.element.open = false
    }
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  ownsEscape() {
    return this.element.open && this.element.contains(document.activeElement)
  }

  closeOnEscape(event) {
    if (event.key !== "Escape" || !this.element.open) return
    // Only act while focus is still inside the open menu. A native <details> does not close
    // on blur, so a keyboard user can Tab past the still-open menu; without this guard an
    // unrelated Escape further down the page would yank focus back up to the summary.
    if (!this.element.contains(document.activeElement)) return

    this.element.open = false
    this.element.querySelector("summary")?.focus()
  }
}
