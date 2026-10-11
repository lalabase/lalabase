import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "loadingIndicator", "endMessage", "sentinel"]
  static values = { 
    url: String,
    page: Number,
    hasMore: Boolean,
    loading: Boolean 
  }
  
  connect() {
    // Adjust rootMargin for mobile - load earlier on mobile for smoother experience
    const isMobile = window.innerWidth < 640
    const rootMargin = isMobile ? "200px" : "100px"
    
    this.observer = new IntersectionObserver(
      this.handleIntersection.bind(this),
      {
        root: null,
        rootMargin: rootMargin,
        threshold: 0.1
      }
    )
    
    // Prefer observing the sentinel — it is always visible (1px). The
    // loading indicator is hidden (display:none, no box) and would
    // never be reported as visible by the IntersectionObserver.
    if (this.hasSentinelTarget) {
      this.observer.observe(this.sentinelTarget)
    } else if (this.hasLoadingIndicatorTarget) {
      this.observer.observe(this.loadingIndicatorTarget)
    }

    // Initialize values
    this.pageValue = this.pageValue || 1
    this.hasMoreValue = this.hasMoreValue ?? true
    this.loadingValue = false
  }
  
  disconnect() {
    if (this.observer) {
      this.observer.disconnect()
    }
  }
  
  handleIntersection(entries) {
    entries.forEach(entry => {
      if (entry.isIntersecting && this.hasMoreValue && !this.loadingValue) {
        this.loadMore()
      }
    })
  }
  
  async loadMore() {
    if (this.loadingValue || !this.hasMoreValue) {
      return
    }
    
    this.loadingValue = true
    this.showLoadingIndicator()
    
    try {
      const nextPage = this.pageValue + 1
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set('page', nextPage)
      
      // Preserve existing filters
      const currentParams = new URLSearchParams(window.location.search)
      for (const [key, value] of currentParams) {
        if (key !== 'page') {
          url.searchParams.set(key, value)
        }
      }
      
      const response = await fetch(url, {
        headers: {
          'Accept': 'text/html',
          'X-Requested-With': 'XMLHttpRequest'
        }
      })
      
      if (response.ok) {
        const html = await response.text()
        const doc = new DOMParser().parseFromString(html, 'text/html')

        // Get the new items container of the next page.
        const newContainer = doc.querySelector('[data-neo-endless-scroll-target="container"]')
        const newScroller = doc.querySelector('[data-controller~="neo-endless-scroll"]')
        const appended = newContainer ? this._appendChildren(newContainer) : 0

        if (appended > 0) {
          this.pageValue = nextPage
          // Read hasMore directly from the next page's data attribute
          // (Pagy-driven), instead of looking for .pagy-nav.
          this.hasMoreValue =
            newScroller?.getAttribute('data-neo-endless-scroll-has-more-value') === 'true'
        } else {
          this.hasMoreValue = false
        }
      } else {
        console.error('Failed to load more notifications:', response.status)
        this.hasMoreValue = false
      }
    } catch (error) {
      console.error('Error loading more notifications:', error)
      this.hasMoreValue = false
    } finally {
      this.loadingValue = false
      this.updateIndicators()
    }
  }
  
  // Appends the children of the new container to the existing one.
  // - The select-all row (data-endless-skip) is skipped.
  // - A leading date header that matches the last already-visible
  //   date header is deduplicated (grouped view).
  // Returns the number of notification items actually appended.
  _appendChildren(newContainer) {
    const lastHeader = [...this.containerTarget.querySelectorAll('[data-date-header]')].pop()
    let lastHeaderDate = lastHeader?.getAttribute('data-date-header') || null
    let appendedItems = 0

    Array.from(newContainer.children).forEach((child) => {
      if (child.matches('[data-endless-skip]')) return

      if (child.matches('[data-date-header]')) {
        const date = child.getAttribute('data-date-header')
        if (date === lastHeaderDate) return // skip the duplicate header
        lastHeaderDate = date
      }

      this.containerTarget.appendChild(child.cloneNode(true))
      if (child.matches('[data-notification-item]')) appendedItems += 1
    })

    return appendedItems
  }

  showLoadingIndicator() {
    if (this.hasLoadingIndicatorTarget) {
      this.loadingIndicatorTarget.classList.remove('hidden')
    }
    
    if (this.hasEndMessageTarget) {
      this.endMessageTarget.classList.add('hidden')
    }
  }
  
  updateIndicators() {
    if (this.hasLoadingIndicatorTarget) {
      this.loadingIndicatorTarget.classList.add('hidden')
    }
    
    if (this.hasEndMessageTarget) {
      if (!this.hasMoreValue) {
        this.endMessageTarget.classList.remove('hidden')
      } else {
        this.endMessageTarget.classList.add('hidden')
      }
    }
  }
  
  // Called when filters change to reset pagination
  reset() {
    this.pageValue = 1
    this.hasMoreValue = true
    this.loadingValue = false
    
    // Clear container except for initial load
    const items = this.containerTarget.querySelectorAll('[data-notification-item]')
    items.forEach((item, index) => {
      if (index >= 20) { // Keep first page of items
        item.remove()
      }
    })
    
    this.updateIndicators()
  }
}