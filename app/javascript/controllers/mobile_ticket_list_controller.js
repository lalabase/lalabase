import { Controller } from "@hotwired/stimulus"
import { FULL_PAGE_BELOW_PX } from "list_row/address"

// Presentation and pointer adapter; TicketSelection remains the sole selection model.
export default class extends Controller {
  static targets = ["editor"]
  connect() {
    this._capture = event => {
      if (this.suppressClick) { event.preventDefault(); event.stopImmediatePropagation(); this.suppressClick = false }
    }
    this.element.addEventListener('click', this._capture, true)
    // Filter changes push their own history entries. Restore the whole mobile
    // page so both the rows and filter controls reflect the popped address.
    this.listPath = window.location.pathname
    this._restore = () => {
      const url = new URL(window.location.href)
      if (url.pathname !== this.listPath) return
      url.searchParams.set('viewport', window.innerWidth < FULL_PAGE_BELOW_PX ? 'mobile' : 'desktop')
      window.history.replaceState(window.history.state, '', url.toString())
      window.location.reload()
    }
    window.addEventListener('popstate', this._restore)
  }
  disconnect() {
    this.cancel()
    clearTimeout(this._suppressTimer)
    this.element.removeEventListener('click', this._capture, true)
    window.removeEventListener('popstate', this._restore)
  }
  get selection() { return this.application.getControllerForElementAndIdentifier(this.element, 'ticket-selection') }
  beginSelection() { this.selection.mobileActive = true; this.selection.render() }
  start(event) {
    if (event.pointerType === 'mouse' || !event.isPrimary || event.target.closest('input, button, select, summary')) return
    const row = event.target.closest('.mobile-ticket-row')
    const box = row?.querySelector('input[type="checkbox"]')
    if (!box) return
    this.cancel()
    this.startPoint = { x: event.clientX, y: event.clientY }
    this.timer = setTimeout(() => {
      if (!box.isConnected) return
      this.beginSelection()
      this.selection.selection.set(box.value, true, this.selection.pageIds)
      this.selection.afterTick()
      this.suppressClick = true
      clearTimeout(this._suppressTimer)
      this._suppressTimer = setTimeout(() => { this.suppressClick = false }, 1200)
      this.timer = null
    }, 450)
  }
  move(event) {
    if (this.startPoint && Math.hypot(event.clientX - this.startPoint.x, event.clientY - this.startPoint.y) > 10) this.cancel()
  }
  stop() { this.cancel() }
  cancel() { clearTimeout(this.timer); this.timer = null; this.startPoint = null }
  contextMenu(event) { if (this.timer || this.suppressClick) event.preventDefault() }
  openTicket(event) {
    if (!this.selection.mobileActive) return
    event.preventDefault()
    const box = event.target.closest('.mobile-ticket-row').querySelector('input')
    this.selection.selection.set(box.value, !box.checked, this.selection.pageIds)
    this.selection.afterTick()
  }
  edit(event) {
    if (this.selection.selection.isEmpty()) return
    const result = this.element.querySelector('[data-ticket-selection-target="result"]')
    this.editorTarget.insertBefore(result, this.editorTarget.querySelector('turbo-frame'))
    this.editorTarget.showModal()
    this.morePending = Boolean(event.detail?.more)
    this.selection.showPanel()
    this.editorReady()
  }
  editorReady() {
    if (!this.morePending) return
    const action = this.editorTarget.querySelector('[data-ticket-bulk-panel-target="other"]')
    if (action) { action.scrollIntoView({ block: 'center' }); action.focus(); this.morePending = false }
  }
  closeEditor() { this.editorTarget.close() }
  editorClosed() {
    const result = this.element.querySelector('[data-ticket-selection-target="result"]')
    this.element.insertBefore(result, this.element.querySelector('#tickets_list_frame'))
  }
  backdrop(event) { if (event.target === this.editorTarget) this.closeEditor() }
  sort(event) {
    const [column, direction] = event.target.value.split(':')
    const url = new URL(window.location.href)
    url.searchParams.set('sort[column]', column)
    url.searchParams.set('sort[direction]', direction)
    url.searchParams.delete('page')
    window.Turbo.visit(url.toString())
  }
}
