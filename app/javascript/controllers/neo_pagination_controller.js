import { Controller } from "@hotwired/stimulus"
import { readLaneParams, withLanePartOf } from "lane/params"

/**
 * Neo Pagination Controller
 *
 * Responsibilities:
 * - Items-per-page change (dropdown onchange)
 * - Preference save to /user_preferences + sessionStorage
 * - Frame-aware navigation (frame.src vs Turbo.visit)
 * - Preserve scroll position on page change
 * - URL validation (blocks /undefined URLs)
 */
export default class extends Controller {
  static values = {
    frame: { type: String, default: "_top" },
    currentItems: { type: Number, default: 20 }
  }

  connect() {
    this.initializeItemsPerPage()
    this._scrollAbortController = new AbortController()
    this.setupLaneCarry()
    this.setupScrollPreservation()
    window.addEventListener("items-per-page-changed", this.handleExternalChange)
  }

  disconnect() {
    window.removeEventListener("items-per-page-changed", this.handleExternalChange)
    if (this._scrollAbortController) {
      this._scrollAbortController.abort()
    }
  }

  // --- Actions (called via data-action) ---

  /**
   * Items-per-page dropdown changed.
   * Reads the URL from the selected <option value="...">.
   */
  changeItemsPerPage(event) {
    const url = this.withLaneState(event.target.value)
    if (!this.validateUrl(url)) return

    const itemsMatch = url.match(/[?&]items=(\d+)/)
    if (itemsMatch) {
      const itemsPerPage = itemsMatch[1]
      this.savePreference(itemsPerPage)
    }

    // Short delay so that the preference save has time
    setTimeout(() => this.navigateToUrl(url), 100)
  }

  // --- Private methods ---

  initializeItemsPerPage() {
    const urlParams = new URLSearchParams(window.location.search)
    const urlValue = urlParams.get("items")
    const sessionValue = sessionStorage.getItem("items_per_page")

    if (urlValue) {
      this.currentItemsValue = parseInt(urlValue)
      sessionStorage.setItem("items_per_page", urlValue)
    } else if (sessionValue) {
      this.currentItemsValue = parseInt(sessionValue)
    }
  }

  // A page turn keeps the open object and its preview (D9 of
  // doc/dateivorschau_plan.md): the destination is the rendered href with the
  // lane part of the CURRENT address, read at click time, before Turbo reads
  // the href. On a page without lane groups the href stays as rendered.
  withLaneState(url) {
    const groups = readLaneParams(this.element, null)
    return groups ? withLanePartOf(url, { current: new URL(window.location.href), groups }) : url
  }

  setupLaneCarry() {
    const signal = this._scrollAbortController.signal
    this.element.querySelectorAll("a[href]").forEach(link => {
      link.addEventListener("click", () => {
        link.setAttribute("href", this.withLaneState(link.getAttribute("href")))
      }, { signal })
    })
  }

  setupScrollPreservation() {
    const signal = this._scrollAbortController.signal
    this.element.querySelectorAll("a[data-turbo-frame]").forEach(link => {
      link.addEventListener("click", () => {
        const elementTop = this.element.getBoundingClientRect().top + window.scrollY
        document.addEventListener("turbo:frame-load", () => {
          window.scrollTo(0, elementTop - 20)
        }, { once: true })
      }, { signal })
    })
  }

  handleExternalChange = (event) => {
    const newValue = event.detail.value
    this.currentItemsValue = parseInt(newValue)
    sessionStorage.setItem("items_per_page", newValue)
  }

  savePreference(itemsPerPage) {
    sessionStorage.setItem("items_per_page", itemsPerPage)

    window.dispatchEvent(new CustomEvent("items-per-page-changed", {
      detail: { value: itemsPerPage }
    }))

    const csrfToken = document.querySelector("meta[name=csrf-token]")?.content
    if (!csrfToken) return

    fetch("/user_preferences", {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: JSON.stringify({ preferences: { items_per_page: itemsPerPage } })
    }).catch(() => {
      // The preference save is best-effort — navigation should not be blocked
    })
  }

  navigateToUrl(url) {
    if (!this.validateUrl(url)) return

    // A ticket selection lives on the controller mounted around the list
    // frame. Items-per-page used to perform a full visit when no detail ticket
    // was open, destroying that in-memory selection. Prefer the owning
    // selection frame when this pagination instance has one; mobile and every
    // other list keep their existing frameValue behaviour.
    const selectionMount = this.element.closest('[data-controller~="ticket-selection"]')
    const selectionFrame = selectionMount?.dataset.ticketSelectionFrameValue
    const frameId = selectionFrame || this.frameValue

    if (frameId === "_top") {
      if (typeof Turbo !== "undefined") {
        Turbo.visit(url)
      } else {
        window.location.href = url
      }
    } else {
      const frame = document.getElementById(frameId)
      if (frame) {
        frame.src = url
      }
    }
  }

  validateUrl(url) {
    return url && url !== "undefined" && url !== "" && !url.includes("/undefined")
  }
}
