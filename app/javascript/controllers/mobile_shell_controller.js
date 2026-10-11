import { Controller } from "@hotwired/stimulus"
import { FULL_PAGE_BELOW_PX } from "list_row/address"
export default class extends Controller {
  static values = { countLabel: String, allLabel: String }
  static targets = ["projects", "normal", "selection", "count", "all"]
  connect() {
    this._viewport = event => {
      const url = new URL(event.detail.url, window.location.href)
      // Only tickets use the 1024px layout. Other list controllers still use 768px.
      if (window.innerWidth < FULL_PAGE_BELOW_PX && /^\/org\/[^/]+\/projects\/[^/]+\/tickets(?:\/|$)/.test(url.pathname)) {
        event.detail.fetchOptions.headers['X-Viewport'] = 'mobile'
      }
    }
    document.addEventListener('turbo:before-fetch-request', this._viewport)
    this._beforeCache = () => { if (this.hasProjectsTarget && this.projectsTarget.open) this.projectsTarget.close() }
    document.addEventListener('turbo:before-cache', this._beforeCache)
  }
  disconnect() {
    document.removeEventListener('turbo:before-fetch-request', this._viewport)
    document.removeEventListener('turbo:before-cache', this._beforeCache)
  }

  openProjects() { this.projectsTarget.showModal() }
  closeProjects() { this.projectsTarget.close() }
  backdrop(event) { if (event.target === this.projectsTarget) this.closeProjects() }
  search(event) {
    const bar = document.querySelector('.mobile-ticket-list [data-controller~="filter-bar"]')
    if (bar) {
      this.application.getControllerForElementAndIdentifier(bar, "filter-bar")?.openSearch()
    } else {
      this.application.getControllerForElementAndIdentifier(document.body, "search-overlay")?.open(event)
    }
  }
  selectionChanged(event) {
    const { count, mobileActive, hitsTotal, max } = event.detail
    if (mobileActive && !this.normalTarget.hidden) this.selectionTarget.style.minHeight = `${this.normalTarget.getBoundingClientRect().height}px`
    this.normalTarget.hidden = Boolean(mobileActive)
    this.selectionTarget.hidden = !mobileActive
    this.countTarget.textContent = this.countLabelValue.replace("%{count}", count)
    this.allTarget.textContent = this.allLabelValue.replace("%{count}", hitsTotal)
    this.allTarget.disabled = hitsTotal > max
  }
  switchProject(event) {
    const current = new URLSearchParams(window.location.search)
    if ([...current.keys()].some(key => ['search', 'smart_folder_id'].includes(key) || key.startsWith('filter['))) {
      const next = new URL(event.currentTarget.href)
      next.searchParams.set('project_switched', '1')
      event.currentTarget.href = next.toString()
    }
  }
  clear() { window.dispatchEvent(new CustomEvent("mobile-selection:clear")) }
  selectAll() { window.dispatchEvent(new CustomEvent("mobile-selection:all")) }
}
