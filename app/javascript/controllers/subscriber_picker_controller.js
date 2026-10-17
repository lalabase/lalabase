import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["trigger", "dropdown", "input", "results", "summary", "editor"]
  static values = { url: String }

  // The notified line swaps for the checkbox editor IN PLACE (user mockup
  // 05.09.2026). Server round trips keep the editor open through the
  // subscriber_open param, so these two only handle the local swap.
  openEditor() {
    if (!this.hasSummaryTarget || !this.hasEditorTarget) return
    this.summaryTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
  }

  closeEditor() {
    if (!this.hasSummaryTarget || !this.hasEditorTarget) return
    this.editorTarget.classList.add("hidden")
    this.summaryTarget.classList.remove("hidden")
  }

  connect() {
    this._onClickOutside = this._onClickOutside.bind(this)
    this._onKeydown = this._onKeydown.bind(this)
    this._searchTimeout = null
  }

  disconnect() {
    document.removeEventListener("click", this._onClickOutside)
    document.removeEventListener("keydown", this._onKeydown)
    if (this._searchTimeout) clearTimeout(this._searchTimeout)
  }

  toggle() {
    if (this.dropdownTarget.classList.contains("hidden")) {
      this._open()
    } else {
      this._close()
    }
  }

  search() {
    if (this._searchTimeout) clearTimeout(this._searchTimeout)

    this._searchTimeout = setTimeout(() => {
      this._fetchUsers()
    }, 250)
  }

  selectUser(event) {
    const userId = event.currentTarget.dataset.userId
    if (!userId) return

    this._close()
    this._submitSubscription(userId)
  }

  // Private

  _open() {
    this.dropdownTarget.classList.remove("hidden")
    this.inputTarget.value = ""
    this.inputTarget.focus()
    this._fetchUsers()
    document.addEventListener("click", this._onClickOutside)
    document.addEventListener("keydown", this._onKeydown)
  }

  _close() {
    this.dropdownTarget.classList.add("hidden")
    document.removeEventListener("click", this._onClickOutside)
    document.removeEventListener("keydown", this._onKeydown)
  }

  _onClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this._close()
    }
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  ownsEscape() {
    return this.hasDropdownTarget && !this.dropdownTarget.classList.contains("hidden")
  }

  _onKeydown(event) {
    if (event.key === "Escape") {
      this._close()
    }
  }

  async _fetchUsers() {
    const query = this.inputTarget.value.trim()
    const url = new URL(this.urlValue, window.location.origin)
    if (query) url.searchParams.set("q", query)

    try {
      const response = await fetch(url, {
        headers: { "Accept": "application/json" }
      })
      const users = await response.json()
      this._renderResults(users)
    } catch (error) {
      console.error("Failed to fetch available users:", error)
    }
  }

  _renderResults(users) {
    if (users.length === 0) {
      this.resultsTarget.innerHTML = `
        <div class="p-3 text-center text-xs text-gray-400">
          ${this.resultsTarget.closest('[data-controller]').querySelector('[data-no-results]')?.textContent || 'No results'}
        </div>
      `
      return
    }

    this.resultsTarget.innerHTML = users.map(user => `
      <button type="button"
              class="w-full text-left px-3 py-2 text-sm hover:bg-gray-100 flex items-center gap-2 transition-colors"
              data-action="click->subscriber-picker#selectUser"
              data-user-id="${user.id}">
        <i class="bi bi-person text-gray-400" style="font-size: 14px;"></i>
        <div>
          <div class="font-medium text-gray-800">${this._escapeHtml(user.name)}</div>
          <div class="text-xs text-gray-400">${this._escapeHtml(user.email)}</div>
        </div>
      </button>
    `).join("")
  }

  _submitSubscription(userId) {
    // Find the subscribe_other path from the component's form action
    const subscribeUrl = this.urlValue.replace("/available_users", "/subscribe_other")
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    const form = document.createElement("form")
    form.method = "POST"
    form.action = subscribeUrl
    form.style.display = "none"
    form.setAttribute("data-turbo", "true")

    const tokenInput = document.createElement("input")
    tokenInput.type = "hidden"
    tokenInput.name = "authenticity_token"
    tokenInput.value = csrfToken || ""
    form.appendChild(tokenInput)

    const userInput = document.createElement("input")
    userInput.type = "hidden"
    userInput.name = "user_id"
    userInput.value = userId
    form.appendChild(userInput)

    // Keep the checkbox editor open across the Turbo replace.
    const openInput = document.createElement("input")
    openInput.type = "hidden"
    openInput.name = "subscriber_open"
    openInput.value = "1"
    form.appendChild(openInput)

    document.body.appendChild(form)
    form.requestSubmit()
    form.remove()
  }

  _escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
