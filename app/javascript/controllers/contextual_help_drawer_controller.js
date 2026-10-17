import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"
import I18n from "i18n"
import { trapTabKey, announcePolitely } from "dialog_a11y"

const ANNOUNCER_ID = "contextual-help-drawer-announcer"
const HIGHLIGHT_CLASS = "contextual-help-highlight"
const SLIDE_MS = 200
const HIGHLIGHT_MS = 2100 // must outlast the 2s contextual-help-flash animation (views.css)

// Contextual-help slide-over drawer (right, body-level) — the "?" menu answers
// open here instead of navigating away (doc/kontexthilfe_drawer_plan.md).
//
// Mounted on <body> (layout) so any contextual-help menu item on the page can
// open the body-level drawer (position:fixed must not be clipped by the sidebar
// transform). Mechanics mirror personal_tasks_drawer_controller
// (open/close/ESC/backdrop/focus restore + slide); differences: the turbo-frame
// src is DYNAMIC (set per clicked question), on turbo:frame-load the drawer
// scrolls to the question's anchor and flashes it, and the header's full-page
// link is re-pointed to the opened page (escape hatch, D5). Tab-trap + announce
// are shared with help_modal_controller via "dialog_a11y" (D3).
export default class extends Controller {
  static targets = ["overlay", "panel", "frame", "fullPageLink", "scrollContainer"]

  connect() {
    this.handleKeydown = this.handleKeydown.bind(this)
    this.handleBeforeCache = this.handleBeforeCache.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
    document.addEventListener("turbo:before-cache", this.handleBeforeCache)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    document.removeEventListener("turbo:before-cache", this.handleBeforeCache)
    this.clearTimers()
    document.body.classList.remove("modal-open")
  }

  // Start closed even if a Turbo cache snapshot restored the drawer open.
  overlayTargetConnected(element) {
    element.classList.add("hidden")
    element.querySelector("[data-contextual-help-drawer-target='panel']")
      ?.classList?.add("translate-x-full")
    document.body.classList.remove("modal-open")
  }

  // Reset BEFORE Turbo takes the snapshot, so back/forward never restores (and
  // visibly flashes) an open drawer; overlayTargetConnected stays as the
  // restore-side safety net.
  handleBeforeCache() {
    if (!this.hasOverlayTarget) return
    this.clearTimers()
    this.overlayTarget.classList.add("hidden")
    if (this.hasPanelTarget) this.panelTarget.classList.add("translate-x-full")
    document.body.classList.remove("modal-open")
  }

  // Opened from a contextual-help menu item. Its Stimulus action params carry the
  // frame URL (help page WITHOUT anchor) and the locale-resolved anchor; the item
  // itself stays a real slug#anchor link — so bail out BEFORE preventDefault for
  // modified clicks (open-in-new-tab intent) and misconfigured items, letting the
  // browser follow the link instead of swallowing the click.
  open(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return
    if (!this.hasOverlayTarget || !event.params.url) return
    event.preventDefault()

    this.clearTimers()
    this.pendingAnchor = event.params.anchor || null

    // The click came from inside the "?" dropdown; close it through its own
    // controller — it registered document-level listeners on open, and its
    // navigation cleanup won't run (we just prevented the navigation).
    const dropdown = event.target.closest("[data-controller~='dropdown']")
    if (dropdown) {
      this.application.getControllerForElementAndIdentifier(dropdown, "dropdown")?.close()
    }

    // Restore focus to the VISIBLE "?" trigger on close, not to the clicked item
    // inside the now-hidden menu (focus() on an invisible element is a silent no-op).
    this.previouslyFocused = dropdown?.querySelector("button") || document.activeElement
    this.overlayTarget.classList.remove("hidden")
    document.body.classList.add("modal-open")
    this.pointFullPageLinkTo(event.params.url, this.pendingAnchor)
    this.loadFrame(event.params.url)

    // Next frame: drop the off-screen transform so the panel slides in.
    requestAnimationFrame(() => {
      if (!this.hasPanelTarget) return
      this.panelTarget.classList.remove("translate-x-full")
      this.panelTarget.focus()
    })
    announcePolitely(I18n.t("stimulus.contextual_help_drawer.opened"), ANNOUNCER_ID)
  }

  close() {
    if (!this.hasOverlayTarget) return
    if (this.hasPanelTarget) this.panelTarget.classList.add("translate-x-full")
    document.body.classList.remove("modal-open")

    // Hide after the slide-out finishes so the transition is visible; restore
    // focus only then — while the dialog is still shown, focus must not sit
    // outside it. open() cancels this timer on a fast reopen (otherwise the
    // stale timeout would hide the freshly reopened drawer).
    const toFocus = this.previouslyFocused
    this.previouslyFocused = null
    window.clearTimeout(this.hideTimeout)
    this.hideTimeout = window.setTimeout(() => {
      this.overlayTarget.classList.add("hidden")
      if (toFocus && toFocus.focus) toFocus.focus()
    }, SLIDE_MS)
    announcePolitely(I18n.t("stimulus.contextual_help_drawer.closed"), ANNOUNCER_ID)
  }

  // Remember where the press STARTED: a text selection that begins in the prose
  // and ends on the backdrop fires click on the common ancestor — selecting help
  // text to copy it must never dismiss the drawer.
  trackPointerDown(event) {
    this.pointerDownTarget = event.target
  }

  // Close only when the click (and its mousedown) landed on the backdrop.
  closeOnBackdrop(event) {
    const pressedOn = this.pointerDownTarget
    this.pointerDownTarget = null
    if (this.hasPanelTarget &&
        (this.panelTarget.contains(event.target) || (pressedOn && this.panelTarget.contains(pressedOn)))) return
    this.close()
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  ownsEscape() {
    return this.hasOverlayTarget && !this.overlayTarget.classList.contains("hidden")
  }

  handleKeydown(event) {
    if (!this.ownsEscape()) return

    if (event.key === "Escape") {
      this.close()
      return
    }
    if (this.hasPanelTarget) trapTabKey(event, this.panelTarget)
  }

  // In-drawer browsing: help-internal links stay in the frame (capture their
  // anchor here — the fetch response URL the frame ends up with loses the hash).
  // Everything else must NOT navigate the frame: an app page's response contains
  // only this drawer's EMPTY placeholder frame and would silently wipe the
  // content back to "Lädt …". Route those top-level (external links → new tab).
  handleFrameClick(event) {
    const link = event.target.closest("a[href]")
    if (!link || !this.hasFrameTarget || !this.frameTarget.contains(link)) return
    if (link.target === "_blank" || link.hasAttribute("download")) return

    const url = new URL(link.href, window.location.origin)
    const base = this.frameTarget.dataset.helpBase || "/hilfe"
    const inHelp = url.origin === window.location.origin &&
      (url.pathname === base || url.pathname.startsWith(`${base}/`))

    if (inHelp) {
      this.pendingAnchor = url.hash ? decodeURIComponent(url.hash.slice(1)) : null
      return
    }

    event.preventDefault()
    this.close()
    if (url.origin === window.location.origin) {
      Turbo.visit(url.href)
    } else {
      window.open(url.href, "_blank", "noopener")
    }
  }

  // Same help page again → no refetch; a DIFFERENT page sets src. Compare
  // pathnames, never raw strings: Turbo rewrites src to the absolute response
  // URL (incl. the items-per-page query noise application.js appends to frame
  // requests), so string equality would never match and every repeat click
  // would refetch the full page. While a load is in flight, leave the frame
  // alone — frameLoaded will consume the freshly set pendingAnchor.
  loadFrame(url) {
    if (!this.hasFrameTarget) return
    const current = this.frameTarget.getAttribute("src")
    const samePath = current &&
      new URL(current, window.location.origin).pathname === new URL(url, window.location.origin).pathname

    if (samePath) {
      if (this.frameTarget.complete) this.scrollToAnchor()
    } else {
      this.frameTarget.setAttribute("src", url)
    }
  }

  // turbo:frame-load — fires for our own src set in open() AND for help-internal
  // link navigation inside the drawer (handleFrameClick keeps everything else
  // out of the frame; keep the escape-hatch link in sync).
  frameLoaded() {
    if (this.hasFrameTarget && this.frameTarget.src) {
      this.pointFullPageLinkTo(this.frameTarget.src, this.pendingAnchor)
    }
    this.scrollToAnchor()
  }

  // turbo:frame-missing / turbo:fetch-request-error — the response carries no
  // matching frame (expired session redirecting to the login layout, a page
  // without the frame) or the fetch itself failed. Without this handler Turbo
  // grafts its untranslated "Content missing" into the drawer. Show a translated
  // message instead; the escape-hatch link still reaches the full page, and
  // clearing src lets the next open() retry the same URL.
  frameError(event) {
    event.preventDefault()
    this.pendingAnchor = null
    if (!this.hasFrameTarget) return
    this.frameTarget.removeAttribute("src")
    const message = document.createElement("p")
    message.className = "text-sm text-cream-600"
    message.textContent = I18n.t("stimulus.contextual_help_drawer.load_error")
    this.frameTarget.replaceChildren(message)
  }

  // Turbo does not scroll to a hash inside a frame (plan F1) — find the heading
  // ourselves, scroll the drawer body there and flash it (CSS in views.css).
  scrollToAnchor() {
    const anchor = this.pendingAnchor
    this.pendingAnchor = null
    const container = this.hasScrollContainerTarget ? this.scrollContainerTarget : null
    const target = anchor && this.hasFrameTarget &&
      this.frameTarget.querySelector(`#${CSS.escape(anchor)}`)

    if (!target) {
      if (container) container.scrollTop = 0
      return
    }

    target.scrollIntoView({ block: "start" })
    target.classList.remove(HIGHLIGHT_CLASS)
    void target.offsetWidth // restart the animation when the same heading is hit twice
    target.classList.add(HIGHLIGHT_CLASS)
    window.clearTimeout(this.highlightTimeout)
    this.highlightTimeout = window.setTimeout(() => target.classList.remove(HIGHLIGHT_CLASS), HIGHLIGHT_MS)
  }

  // Escape hatch (D5): the header link always opens the currently shown page as
  // a full help page (incl. tree), with the question anchor when there is one.
  // Reduce to the pathname: frame.src carries app-global query noise (the
  // items-per-page param appended to frame requests in application.js).
  pointFullPageLinkTo(url, anchor) {
    if (!this.hasFullPageLinkTarget) return
    const path = new URL(url, window.location.origin).pathname
    this.fullPageLinkTarget.setAttribute("href", anchor ? `${path}#${anchor}` : path)
  }

  clearTimers() {
    window.clearTimeout(this.hideTimeout)
    window.clearTimeout(this.highlightTimeout)
  }
}
