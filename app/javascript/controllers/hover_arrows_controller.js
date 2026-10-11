import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="hover-arrows"
export default class extends Controller {
  static targets = ["categories", "list", "content", "arrowCategories", "arrowList", "arrowContent"]
  static outlets = ["layout-toggle"]
  
  connect() {
    this.timeouts = {
      categories: null,
      list: null,
      content: null
    }

    this.abortController = new AbortController()
    this.setupHoverListeners()
  }

  disconnect() {
    // Remove all event listeners via AbortController
    this.abortController.abort()

    // Clear all timeouts when disconnecting
    Object.values(this.timeouts).forEach(timeout => {
      if (timeout) clearTimeout(timeout)
    })
  }
  
  setupHoverListeners() {
    const signal = this.abortController.signal

    // Categories column
    if (this.hasCategoriesTarget && this.hasArrowCategoriesTarget) {
      this.categoriesTarget.addEventListener('mouseenter', () => this.showArrow('categories'), { signal })
      this.categoriesTarget.addEventListener('mouseleave', () => this.hideArrowWithDelay('categories'), { signal })

      this.arrowCategoriesTarget.addEventListener('mouseenter', () => this.keepArrowVisible('categories'), { signal })
      this.arrowCategoriesTarget.addEventListener('mouseleave', () => this.hideArrowWithDelay('categories'), { signal })
      this.arrowCategoriesTarget.addEventListener('click', () => this.handleArrowClick('categories'), { signal })
    }

    // List column
    if (this.hasListTarget && this.hasArrowListTarget) {
      this.listTarget.addEventListener('mouseenter', () => this.showArrow('list'), { signal })
      this.listTarget.addEventListener('mouseleave', () => this.hideArrowWithDelay('list'), { signal })

      this.arrowListTarget.addEventListener('mouseenter', () => this.keepArrowVisible('list'), { signal })
      this.arrowListTarget.addEventListener('mouseleave', () => this.hideArrowWithDelay('list'), { signal })
      this.arrowListTarget.addEventListener('click', () => this.handleArrowClick('list'), { signal })
    }

    // Content column
    if (this.hasContentTarget && this.hasArrowContentTarget) {
      this.contentTarget.addEventListener('mouseenter', () => this.showArrow('content'), { signal })
      this.contentTarget.addEventListener('mouseleave', () => this.hideArrowWithDelay('content'), { signal })

      this.arrowContentTarget.addEventListener('mouseenter', () => this.keepArrowVisible('content'), { signal })
      this.arrowContentTarget.addEventListener('mouseleave', () => this.hideArrowWithDelay('content'), { signal })
      this.arrowContentTarget.addEventListener('click', () => this.handleArrowClick('content'), { signal })
    }
  }
  
  showArrow(column) {
    if (this.timeouts[column]) {
      clearTimeout(this.timeouts[column])
    }
    
    // Check if we should show the arrow for list column
    if (column === 'list') {
      const layoutToggle = this.getLayoutToggleController()
      if (layoutToggle) {
        const state = layoutToggle.layoutState
        // Don't show arrow if categories are visible but no item is selected (content is disabled)
        if (state.categories && !layoutToggle.hasSelectedItem()) {
          return
        }
      }
    }
    
    const columnTarget = this[`${column}Target`]
    const arrowTarget = this[`arrow${column.charAt(0).toUpperCase() + column.slice(1)}Target`]
    
    const rect = columnTarget.getBoundingClientRect()
    arrowTarget.style.left = (rect.left + rect.width / 2) + 'px'
    arrowTarget.style.top = (rect.top - 30) + 'px'
    arrowTarget.style.opacity = '0.5'
    
    // Update arrow direction
    this.updateArrowDirection(column)
  }
  
  hideArrowWithDelay(column) {
    const arrowTarget = this[`arrow${column.charAt(0).toUpperCase() + column.slice(1)}Target`]
    
    this.timeouts[column] = setTimeout(() => {
      arrowTarget.style.opacity = '0'
    }, 1000)
  }
  
  keepArrowVisible(column) {
    if (this.timeouts[column]) {
      clearTimeout(this.timeouts[column])
    }
    
    const arrowTarget = this[`arrow${column.charAt(0).toUpperCase() + column.slice(1)}Target`]
    arrowTarget.style.opacity = '0.7'
  }
  
  handleArrowClick(column) {
    const arrowTarget = this[`arrow${column.charAt(0).toUpperCase() + column.slice(1)}Target`]
    arrowTarget.style.opacity = '0' // Hide arrow immediately
    
    if (this.timeouts[column]) {
      clearTimeout(this.timeouts[column])
    }
    
    // Get layout toggle controller
    let layoutToggle = this.hasLayoutToggleOutlet ? this.layoutToggleOutlet : null
    
    if (!layoutToggle) {
      layoutToggle = this.application.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller~="layout-toggle"]'), 
        'layout-toggle'
      )
    }
    
    if (layoutToggle) {
      if (column === 'categories') {
        layoutToggle.toggleCategories()
      } else if (column === 'list') {
        // List arrow toggles categories or content based on state
        const state = layoutToggle.layoutState
        if (!state.categories) {
          layoutToggle.toggleCategories()
        } else {
          layoutToggle.toggleContent()
        }
      } else if (column === 'content') {
        // Content arrow toggles list
        layoutToggle.toggleList()
      }
    }
  }
  
  getLayoutToggleController() {
    if (this.hasLayoutToggleOutlet) {
      return this.layoutToggleOutlet
    }
    
    return this.application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller~="layout-toggle"]'), 
      'layout-toggle'
    )
  }
  
  updateArrowDirection(column) {
    const layoutToggle = this.getLayoutToggleController()
    if (!layoutToggle) return
    
    const state = layoutToggle.layoutState
    this.updateArrowDirectionWithState(column, state, layoutToggle)
  }
  
  updateArrowDirectionWithState(column, state, layoutToggle) {
    if (column === 'list' && this.hasArrowListTarget) {
      if (!state.categories && state.content) {
        // If categories are hidden AND content is visible, show right arrow
        this.arrowListTarget.textContent = '→'
      } else if (!state.categories) {
        // If categories are hidden (but content might also be hidden), show left arrow to expand categories
        this.arrowListTarget.textContent = '←'
      } else if (layoutToggle.hasSelectedItem() && !state.content) {
        // If an item is selected but content is hidden, show left arrow
        // to indicate clicking will reveal the content column
        this.arrowListTarget.textContent = '←'
      } else if (state.content) {
        // If content is visible, show arrow to expand content more
        this.arrowListTarget.textContent = '→'
      } else {
        // If no item selected and content is hidden, show arrow to expand content
        this.arrowListTarget.textContent = '→'
      }
    } else if (column === 'content' && this.hasArrowContentTarget) {
      this.arrowContentTarget.textContent = state.list ? '←' : '→'
    } else if (column === 'categories' && this.hasArrowCategoriesTarget) {
      // Categories arrow points left when visible (to collapse), right when hidden (to expand)
      this.arrowCategoriesTarget.textContent = state.categories ? '←' : '→'
    }
  }
}