import { Controller } from "@hotwired/stimulus"

// Keeps the project activity filter aligned with the shared filter bar:
// conditions rest as a sentence, become pills only while editing, and search
// expands from the toolbar's magnifier without adding another permanent field.
export default class extends Controller {
  static targets = ["sentenceRow", "editorRow", "search", "searchInput"]

  startEditing() {
    if (!this.hasEditorRowTarget) return

    this.sentenceRowTarget.classList.add("hidden")
    this.editorRowTarget.classList.remove("hidden")
    this.editorRowTarget.querySelector("summary, button, a")?.focus()
  }

  stopEditing() {
    if (!this.hasEditorRowTarget) return

    this.editorRowTarget.classList.add("hidden")
    this.sentenceRowTarget.classList.remove("hidden")
    this.sentenceRowTarget.querySelector("button")?.focus()
  }

  openFilterMenu(event) {
    event.preventDefault()
    const disclosure = this.element.querySelector("[data-activity-filter-menu]")
    if (!disclosure) return

    disclosure.open = true
    requestAnimationFrame(() => disclosure.querySelector("[data-filter-category]")?.focus())
  }

  openSearch() {
    this.searchTarget.setAttribute("data-fb-search-open", "")
    requestAnimationFrame(() => this.searchInputTarget.focus())
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // The same conditions as closeSearch, bound to the search field.
  ownsEscape() {
    return this.hasSearchTarget && this.hasSearchInputTarget &&
      this.searchTarget.hasAttribute("data-fb-search-open") && !this.searchInputTarget.value &&
      this.searchTarget.contains(document.activeElement)
  }

  closeSearch(event) {
    if (this.searchInputTarget.value) return

    this.searchTarget.removeAttribute("data-fb-search-open")
    event?.preventDefault()
    this.searchTarget.querySelector("[data-fb-search-open-button]")?.focus()
  }

  searchBlur(event) {
    if (this.searchTarget.contains(event.relatedTarget)) return

    this.closeSearch()
  }
}
