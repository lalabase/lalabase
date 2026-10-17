import { Controller } from "@hotwired/stimulus"
import { ServerSearch } from "autosuggest_search"

// Two modes. Without url the options come from ERB and the typed text filters them in the
// browser (the meeting and time pickers). With url (NeoAutosuggestComponent url:) every term
// asks the server; lib/autosuggest_search.js keeps the confirmed choice apart from the
// results and drops stale answers, this controller only renders them.
export default class extends Controller {
  static targets = ["input", "dropdown", "option", "hiddenInput", "arrow", "status", "optionTemplate", "list"]
  static values = {
    selected: String,
    name: String,
    url: String,
    selectedText: String,
    hintText: String,
    emptyText: String,
    errorText: String,
    loadingText: String
  }

  connect() {
    this.isOpen = false
    this.selectedIndex = -1
    this.filteredOptions = this.optionTargets

    if (this.urlValue) {
      this.server = new ServerSearch({
        url: this.urlValue,
        selection: { value: this.selectedValue, text: this.selectedTextValue },
        // Every state but fresh results empties the list: an old option, or the keyboard
        // mark on it, must not be taken by Enter (review of #944).
        onResults: (options) => this.renderOptions(options, this.emptyTextValue),
        onError: () => this.renderOptions([], this.errorTextValue),
        onIdle: () => this.renderOptions([], this.hintTextValue),
        onLoading: () => this.renderOptions([], this.loadingTextValue)
      })
    }

    // Close dropdown when clicking outside
    this.boundHandleOutsideClick = this.handleOutsideClick.bind(this)
    document.addEventListener('click', this.boundHandleOutsideClick)
  }

  disconnect() {
    document.removeEventListener('click', this.boundHandleOutsideClick)
    // A modal closed with a request in flight: nothing may land in a detached list.
    if (this.server) this.server.cancel()
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    this.dropdownTarget.classList.remove('hidden')
    this.arrowTarget.style.transform = 'rotate(180deg)'
    this.isOpen = true
    this.selectedIndex = -1
    this.updateSelection()
    
    // Make input editable for filtering
    this.inputTarget.removeAttribute('readonly')
    this.inputTarget.select()
  }

  close() {
    if (this.server) {
      this.closeServer()
      return
    }

    this.dropdownTarget.classList.add('hidden')
    this.arrowTarget.style.transform = 'rotate(0deg)'
    this.isOpen = false
    
    // Restore readonly state and selected text
    this.inputTarget.setAttribute('readonly', true)
    this.restoreSelectedText()
    
    // Clear any filtering
    this.clearFilter()
  }

  // Server mode: focus or click opens the list, without closing it again on the click that
  // follows the focus. The confirmed text is selected, so typing replaces it.
  show() {
    if (!this.server || this.isOpen) return

    this.showDropdown()
    if (this.server.hasSelection) this.inputTarget.select()
  }

  // Server mode, on every input: the field holds a search now, so the confirmed choice goes,
  // in the hidden field as well (rule 2 of lib/autosuggest_search.js).
  search() {
    if (!this.server) return

    if (!this.isOpen) this.showDropdown()
    this.server.input(this.inputTarget.value)
    if (this.hiddenInputTarget.value !== '') {
      this.hiddenInputTarget.value = ''
      this.hiddenInputTarget.dispatchEvent(new Event('change', { bubbles: true }))
    }
  }

  showDropdown() {
    this.dropdownTarget.classList.remove('hidden')
    this.arrowTarget.style.transform = 'rotate(180deg)'
    this.isOpen = true
    this.inputTarget.setAttribute('aria-expanded', 'true')
    this.selectedIndex = -1
    if (this.optionTargets.length === 0) this.showStatus(this.hintTextValue)
  }

  closeServer() {
    this.server.cancel()
    this.dropdownTarget.classList.add('hidden')
    this.arrowTarget.style.transform = 'rotate(0deg)'
    this.isOpen = false
    this.inputTarget.setAttribute('aria-expanded', 'false')
    this.inputTarget.value = this.server.selection.text
    this.renderOptions([], this.hintTextValue)
  }

  // The list is rebuilt from scratch, the keyboard mark with it. Without options the
  // status line says why (hint, searching, no results, failed). Text goes in as text.
  renderOptions(options, statusText) {
    this.optionTargets.forEach((option) => option.remove())
    this.selectedIndex = -1
    this.inputTarget.removeAttribute('aria-activedescendant')

    if (options.length === 0) {
      this.showStatus(statusText)
    } else {
      this.showStatus('')
      // Into the listbox beside the status line (server mode always renders one).
      const list = this.hasListTarget ? this.listTarget : this.dropdownTarget
      options.forEach((option, index) => list.appendChild(this.buildOption(option, index)))
    }
    this.filteredOptions = this.optionTargets
  }

  // The id lets the field name the option the keyboard marks (aria-activedescendant).
  buildOption(option, index) {
    const element = this.optionTemplateTarget.content.firstElementChild.cloneNode(true)
    element.dataset.value = option.value
    element.dataset.text = option.text
    element.querySelector('[data-slot="text"]').textContent = option.text
    element.querySelector('[data-slot="detail"]').textContent = option.detail
    element.id = `${this.element.id}_option_${index}`
    element.setAttribute('aria-selected', 'false')
    return element
  }

  showStatus(text) {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle('hidden', !text)
  }

  selectOption(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const option = event.currentTarget
    const value = option.dataset.value
    const text = option.dataset.text
    
    if (this.server) this.server.choose({ value, text })
    this.setSelected(value, text)
    this.close()
  }

  setSelected(value, text) {
    this.selectedValue = value
    this.hiddenInputTarget.value = value
    this.inputTarget.value = text
    
    // Update visual selection
    this.updateOptionSelection(value)
    
    // Trigger change event for form handling
    this.hiddenInputTarget.dispatchEvent(new Event('change', { bubbles: true }))
  }

  updateOptionSelection(selectedValue) {
    this.optionTargets.forEach(option => {
      option.classList.remove('bg-lime-200', 'font-medium')
      if (option.dataset.value === selectedValue) {
        option.classList.add('bg-lime-200', 'font-medium')
      }
    })
  }

  restoreSelectedText() {
    const selectedOption = this.optionTargets.find(option => 
      option.dataset.value === this.selectedValue
    )
    
    if (selectedOption) {
      this.inputTarget.value = selectedOption.dataset.text
    } else if (this.selectedValue === '' || !this.selectedValue) {
      // Find blank option text or use default
      const blankOption = this.optionTargets.find(option => option.dataset.value === '')
      this.inputTarget.value = blankOption ? blankOption.dataset.text : 'Alle'
    }
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // Its Escape listens on its own field, so only a key pressed there counts.
  ownsEscape() {
    return this.isOpen && this.element.contains(document.activeElement)
  }

  handleKeydown(event) {
    if (!this.isOpen) {
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault()
        // Server mode opens its own way: aria-expanded, the status line (review of #944).
        if (this.server) this.show()
        else this.open()
        return
      }
      return
    }

    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault()
        this.moveSelection(1)
        break
      case 'ArrowUp':
        event.preventDefault()
        this.moveSelection(-1)
        break
      case 'Enter':
        event.preventDefault()
        if (this.selectedIndex >= 0 && this.filteredOptions[this.selectedIndex]) {
          this.selectOption({ 
            currentTarget: this.filteredOptions[this.selectedIndex],
            preventDefault: () => {},
            stopPropagation: () => {}
          })
        }
        break
      case 'Escape':
        event.preventDefault()
        this.close()
        break
      default:
        // Handle filtering (server mode searches on the input event instead)
        if (!this.server) this.handleFiltering()
        break
    }
  }

  moveSelection(direction) {
    if (this.filteredOptions.length === 0) return
    
    this.selectedIndex += direction
    
    // Wrap around
    if (this.selectedIndex < 0) {
      this.selectedIndex = this.filteredOptions.length - 1
    } else if (this.selectedIndex >= this.filteredOptions.length) {
      this.selectedIndex = 0
    }
    
    this.updateSelection()
  }

  updateSelection() {
    this.filteredOptions.forEach((option, index) => {
      option.classList.remove('bg-blue-100')
      if (index === this.selectedIndex) {
        option.classList.add('bg-blue-100')
        option.scrollIntoView({ block: 'nearest' })
      }
    })
    if (this.server) this.announceSelection()
  }

  // Server mode is a WAI-ARIA combobox: the focus stays in the field, so the field names the
  // marked option and the option says so, or a screen reader never hears what Enter takes
  // (review round 3 of #944).
  announceSelection() {
    const marked = this.filteredOptions[this.selectedIndex]
    this.filteredOptions.forEach((option) => option.setAttribute('aria-selected', option === marked ? 'true' : 'false'))
    if (marked) {
      this.inputTarget.setAttribute('aria-activedescendant', marked.id)
    } else {
      this.inputTarget.removeAttribute('aria-activedescendant')
    }
  }

  handleFiltering() {
    // Simple filtering based on input text
    const filterText = this.inputTarget.value.toLowerCase()
    
    this.filteredOptions = this.optionTargets.filter(option => {
      const optionText = option.dataset.text.toLowerCase()
      const matches = optionText.includes(filterText)
      
      option.style.display = matches ? 'block' : 'none'
      return matches
    })
    
    // Reset selection
    this.selectedIndex = -1
    this.updateSelection()
  }

  clearFilter() {
    this.optionTargets.forEach(option => {
      option.style.display = 'block'
      option.classList.remove('bg-blue-100')
    })
    this.filteredOptions = this.optionTargets
  }

  handleOutsideClick(event) {
    if (!this.element.contains(event.target)) {
      this.close()
    }
  }
}