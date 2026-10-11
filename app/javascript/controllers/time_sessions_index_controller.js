import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["searchInput", "searchForm", "listContainer", "layoutToggle", "modal"]

  connect() {
    this.searchTimeout = null
    this.setupSearchForm()
    this.setupRowClickHandler()
    this.applyFilterLayout()

    this.handleTurboSuccess = this.handleTurboSuccess.bind(this)
    document.addEventListener("turbo:submit-end", this.handleTurboSuccess)
  }

  disconnect() {
    clearTimeout(this.searchTimeout)
    document.removeEventListener("turbo:submit-end", this.handleTurboSuccess)

    if (this.hasSearchInputTarget) {
      this.searchInputTarget.removeEventListener('input', this.boundInputHandler)
      this.searchInputTarget.removeEventListener('search', this.boundSearchHandler)
      this.searchInputTarget.removeEventListener('dblclick', this.boundDblclickHandler)
      delete this.searchInputTarget.dataset.searchSetup
    }

    this.element.removeEventListener('click', this.boundRowClickHandler)
  }

  applyFilterLayout() {
    const urlParams = new URLSearchParams(window.location.search)
    const hasFilters = urlParams.has('ticket_id') || urlParams.has('time_session_group_id') || urlParams.has('start_date') || urlParams.has('end_date')

    if (hasFilters) {
      const layout = document.querySelector('.layout')
      if (layout) {
        layout.classList.add('hide-content')
        layout.classList.remove('show-content')
      }

      const laborLayoutView = document.querySelector('.labor-layout-view')
      if (laborLayoutView) {
        laborLayoutView.classList.remove('show-content')
      }
    }
  }

  setupSearchForm() {
    if (!this.hasSearchInputTarget || !this.hasSearchFormTarget) return
    if (this.searchInputTarget.dataset.searchSetup === 'true') return

    this.searchInputTarget.dataset.searchSetup = 'true'

    this.boundInputHandler = this.handleSearchInput.bind(this)
    this.boundSearchHandler = this.handleSearchClear.bind(this)
    this.boundDblclickHandler = this.handleSearchDblclick.bind(this)

    this.searchInputTarget.addEventListener('input', this.boundInputHandler)
    this.searchInputTarget.addEventListener('search', this.boundSearchHandler)
    this.searchInputTarget.addEventListener('dblclick', this.boundDblclickHandler)
  }

  handleSearchInput(event) {
    clearTimeout(this.searchTimeout)
    if (event.target.value.length > 3 || event.target.value.length === 0) {
      this.searchTimeout = setTimeout(() => {
        this.updateFormAction()
        this.searchFormTarget.requestSubmit()
      }, 300)
    }
  }

  handleSearchClear(event) {
    if (event.target.value === '') {
      clearTimeout(this.searchTimeout)
      this.updateFormAction()
      this.searchFormTarget.requestSubmit()
    }
  }

  handleSearchDblclick(event) {
    event.target.select()
  }

  updateFormAction() {
    const urlParams = new URLSearchParams(window.location.search)
    const preserveParams = ['time_session_id', 'items', 'smart_folder_id']

    preserveParams.forEach(param => {
      if (urlParams.has(param)) {
        let input = this.searchFormTarget.querySelector(`input[name="${param}"]`)
        if (!input) {
          input = document.createElement('input')
          input.type = 'hidden'
          input.name = param
          this.searchFormTarget.appendChild(input)
        }
        input.value = urlParams.get(param)
      }
    })
  }

  setupRowClickHandler() {
    this.boundRowClickHandler = this.handleRowClick.bind(this)
    this.element.addEventListener('click', this.boundRowClickHandler)
  }

  handleRowClick(event) {
    const timeSessionRow = event.target.closest('tr[data-time-session-id]')
    if (!timeSessionRow) return

    // Ignore clicks on links, buttons, forms, etc.
    if (event.target.closest('a, button, form, input, .dropdown, .no-click')) return

    const timeSessionPath = timeSessionRow.dataset.href
    if (!timeSessionPath) return

    // Update row highlight
    this.element.querySelectorAll('tr.bg-cyan-100').forEach(row => {
      row.classList.remove('bg-cyan-100')
    })
    timeSessionRow.classList.add('bg-cyan-100')

    // Show content column only if no filters are active
    const urlParams = new URLSearchParams(window.location.search)
    const hasFilters = urlParams.has('ticket_id') || urlParams.has('time_session_group_id') || urlParams.has('start_date') || urlParams.has('end_date')

    if (!hasFilters && this.hasLayoutToggleTarget) {
      const controller = this.application.getControllerForElementAndIdentifier(
        this.layoutToggleTarget,
        'layout-toggle'
      )
      if (controller && controller.showContent) {
        controller.showContent()
      }
    }

    // Update frame content
    const frame = document.getElementById('time_session_display_frame')
    if (frame) {
      frame.setAttribute('src', `${timeSessionPath}?format=turbo_stream&frame=content`)
    }
  }

  // Called when turbo frames load
  frameLoaded(event) {
    // Frame load handling
  }

  // Modal handling
  // Closes the capture modal after a successful save
  // (Pattern: docs/dokumentation/modal_pattern.md)
  handleTurboSuccess(event) {
    const form = event.target
    if (form && form.id === "time_session_form" && event.detail.success) {
      this.closeModal()
    }
  }

  openModal(event) {
    event.preventDefault()

    if (this.hasModalTarget) {
      this.modalTarget.classList.remove('hidden')
      document.body.style.overflow = 'hidden'
    } else {
      console.error("Modal target not found")
    }
  }

  closeModal(event) {
    if (event) event.preventDefault()

    if (this.hasModalTarget) {
      this.modalTarget.classList.add('hidden')
      document.body.style.overflow = ''
    }
  }

  clickOutside(event) {
    // Only close if clicking on the backdrop
    if (event.target === event.currentTarget) {
      this.closeModal()
    }
  }
}
