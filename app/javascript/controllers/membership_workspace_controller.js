import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "close"]

  connect() {
    this.listPath = window.location.pathname
  }

  // Like the knowledge lane, keep selection in the URL without promoting
  // frame loads to Drive visits (which restore stale frame contents on Back).
  navigate(event) {
    const link = event.target.closest("a[href]")
    if (!link || link.dataset.turboFrame === "_top" || event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const url = new URL(link.href)
    if (url.origin !== window.location.origin || url.pathname !== this.listPath || url.hash) return
    event.preventDefault()
    this.visit(url)
  }

  search(event) {
    event.preventDefault()
    const url = new URL(event.target.action)
    url.search = new URLSearchParams(new FormData(event.target)).toString()
    this.visit(url)
  }

  visit(url) {
    if (url.href !== window.location.href) history.pushState({ membershipWorkspace: true }, "", url.href)
    this.element.src = url.href
  }

  restore() {
    if (window.location.pathname !== this.listPath) return
    if (this.element.src === window.location.href) this.element.reload()
    else this.element.src = window.location.href
  }

  restoreFocus() {
    // A deletion may redirect back to the unselected list. Mirror that result,
    // so reload never tries to reopen the membership that was just removed.
    const path = this.element.querySelector("[data-membership-workspace-url]")?.dataset.membershipWorkspaceUrl
    if (path) history.replaceState({ membershipWorkspace: true }, "", path)
    const control = this.focusId && document.getElementById(this.focusId)
    if (control) control.focus({ preventScroll: true })
    else if (this.hasCloseTarget) this.closeTarget.focus({ preventScroll: true })
    this.focusId = null
  }

  openRow(event) {
    if (event.target.closest("a, button, select, form, details") || window.getSelection()?.toString()) return
    event.currentTarget.querySelector("[data-member-link]")?.click()
  }

  changeRole(event) {
    const select = event.target
    if (select.value === "__manage__") {
      select.value = select.dataset.previousValue
      window.Turbo.visit(select.dataset.rolesUrl)
      return
    }
    this.submit(event)
  }

  submit(event) {
    this.focusId = event.target.id
    event.target.form.requestSubmit()
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  // Its Escape is bound inside the workspace: an open menu, else the open panel.
  ownsEscape() {
    return this.element.contains(document.activeElement) &&
      (this.hasCloseTarget || Boolean(this.element.querySelector("details[open]")))
  }

  closeMenu(event) {
    event.stopPropagation()
    event.currentTarget.open = false
    event.currentTarget.querySelector("summary").focus()
  }

  closeOutside(event) {
    this.element.querySelectorAll("details[open]").forEach(menu => {
      if (!menu.contains(event.target)) menu.open = false
    })
  }

  closePanel(event) {
    if (event.target.closest("select, details")) return
    if (this.hasCloseTarget) this.closeTarget.click()
  }

  async copyLink(event) {
    const button = event.currentTarget
    const label = button.textContent
    button.disabled = true
    try {
      const result = fetch(button.dataset.url, { headers: { Accept: "application/json" }, cache: "no-store" })
        .then(response => {
          if (!response.ok) throw new Error("Invitation unavailable")
          return response.json()
        }).then(data => data.url)
      // Passing a promised Blob preserves Safari's user activation across the fetch.
      if (navigator.clipboard?.write && window.ClipboardItem) {
        await navigator.clipboard.write([new ClipboardItem({ "text/plain": result.then(url => new Blob([url], { type: "text/plain" })) })])
      } else if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(await result)
      } else {
        await result
        throw new Error("Clipboard unavailable")
      }
      button.textContent = button.dataset.copied
    } catch {
      button.textContent = button.dataset.error
    } finally {
      button.disabled = false
      setTimeout(() => { if (button.isConnected) button.textContent = label }, 2500)
    }
  }
}
