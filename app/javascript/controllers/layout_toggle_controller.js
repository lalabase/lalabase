import { Controller } from "@hotwired/stimulus"
import { readLaneParams, laneParamNames } from "lane/params"
import { controlIndexPath, indexPaths } from "lane/filter_context"

// The fixed-height list/detail grids (Tickets table, Knowledge, Meetings) fill the
// viewport instead of carrying a hardcoded `calc(100vh - <magic>)` height. The bottom
// gap mirrors the page's left gutter (main lg:px-6 = 1.5rem) so the space below the
// grid matches the space to the sidebar. Floor for very short viewports.
const GRID_BOTTOM_GAP_PX = 24
const GRID_MIN_HEIGHT_PX = 200

// Connects to data-controller="layout-toggle"
//
// Column/content state of the two-column list pages (Tickets, Knowledge, Meetings).
// The page specifics come in as Values from the mount — the controller no longer
// has any frame IDs or row selectors hardcoded:
//
//   list-frame-ids        list frames whose load re-evaluates layout/selection
//   detail-frame-id       detail frame: load shows the content column
//                         (e.g. "New note" link loads the form into the frame)
//   content-selector      selector for real content in the detail frame
//   selected-row-selector list row marked server-/client-side
//   selection-params      URL params that signal an open selection
//
// Public API (used by row controllers, chat button and the hover_arrows outlet):
// showContent(), closeContent(), togglePanel(), toggleCategories(),
// toggleList(), toggleContent(), hasSelectedItem(), layoutState.
export default class extends Controller {
  static targets = ["layout"]

  static values = {
    listFrameIds: { type: Array, default: [] },
    detailFrameId: { type: String, default: "" },
    contentSelector: { type: String, default: "" },
    selectedRowSelector: { type: String, default: "" },
    selectionParams: { type: Array, default: ["ticket_id", "note_id", "document_id"] },
    listFilterParams: { type: Array, default: [] },
    // Meetings carry per-record Turbo stream subscriptions in their detail.
    // Opt-in clearing disconnects those subscriptions when the lane closes.
    clearDetailOnClose: { type: Boolean, default: false },
    // Per-area sessionStorage key so lane state does not bleed across areas.
    // Tickets/Knowledge keep the shared default; Meetings mounts its own key. A grid
    // WITHOUT a panel column never
    // opens one, whatever the stored state says: see hasPanelColumn().
    storageKey: { type: String, default: "layoutState" },
    // Parameters every request of a lane of another list carries, added at
    // click and submit (syncFilterContext): "Alle Meetings" says
    // list_context=organisation, so a save in its lane redraws that list, also
    // from a link a broadcast or a section refresh rendered without it.
    laneContext: { type: Object, default: {} }
  }

  connect() {
    // Check server-side state first
    const layoutElement = this.hasLayoutTarget ? this.layoutTarget : document.querySelector('.layout')
    const serverSaysHideContent = layoutElement && layoutElement.classList.contains('hide-content')

    // Detect if we're in a two-column layout (no categories sidebar)
    this.hasCategoriesColumn = layoutElement && !layoutElement.classList.contains('two-column')

    // Load layout state from sessionStorage or use defaults
    const savedState = sessionStorage.getItem(this.storageKeyValue)
    this.layoutState = {
      categories: true,  // visible by default
      list: true,        // visible by default
      content: false,    // hidden by default until an item is selected
      panel: false       // hidden by default
    }
    if (savedState) {
      try {
        this.layoutState = JSON.parse(savedState)
      } catch (e) {
        // Fall back to defaults if parsing fails
      }
    }

    // An explicit server-rendered deep link takes precedence over a closed lane.
    if (layoutElement?.classList.contains('show-panel')) {
      this.layoutState.panel = true
      layoutElement.classList.remove('show-panel')
    }

    // Force categories off for two-column layouts
    if (!this.hasCategoriesColumn) {
      this.layoutState.categories = false
    }

    // A grid without a panel column can never show one, whatever the shared
    // storage key says (it may carry panel:true from Knowledge). The clamp lives
    // in updateLayout(), the ONE place that flips hide-panel, so every reader of
    // the stored state (connect, handleFrameLoad, togglePanel) is covered, and the
    // stored value itself is left alone: a tickets visit must not close the lane
    // the user left open on Knowledge (S4-T1 review finding, second round).

    // Determine if content should be shown
    if (this.hasSelection() || this.hasContentLoaded()) {
      this.layoutState.content = true
    } else if (serverSaysHideContent) {
      // No item selected - always respect server state
      // (ignore saved session state when the server says hide)
      this.layoutState.content = false
    } else {
      // Server says show content - use saved state or show it
      this.layoutState.content = savedState ? this.layoutState.content : true
    }

    // Special case: direct show route (e.g. /tickets/<id> renders the index
    // view with the detail pane open)
    const isShowRoute = window.location.pathname.match(/\/(tickets|notes|documents)\/[\w-]+$/)
    if (isShowRoute) {
      this.layoutState.content = true
    }

    // Initialize layout - this will restore the saved state to both elements
    this.updateLayout()

    // Listen for Turbo Frame loads to maintain layout state
    this.boundHandleFrameLoad = this.handleFrameLoad.bind(this)
    document.addEventListener('turbo:frame-load', this.boundHandleFrameLoad, true)
    this.boundHandleListStream = this.handleListStream.bind(this)
    document.addEventListener('turbo:before-stream-render', this.boundHandleListStream)
    this.boundSyncFilterContext = () => this.syncFilterContext(new URL(window.location.href))
    this.element.addEventListener('click', this.boundSyncFilterContext, true)
    this.element.addEventListener('submit', this.boundSyncFilterContext, true)

    // A write that ends the lane's object (a deleted meeting) closes the lane
    // through the closeLane stream action (application.js).
    this.boundCloseLane = this.closeLane.bind(this)
    document.addEventListener('lane:close', this.boundCloseLane)

    // ESC key closes content panel
    this.boundCloseOnEscape = this.closeOnEscape.bind(this)
    document.addEventListener('keydown', this.boundCloseOnEscape)

    // Re-fill the grid height when the viewport resizes (rAF-throttled).
    this.boundScheduleGridHeight = this.scheduleGridHeightUpdate.bind(this)
    window.addEventListener('resize', this.boundScheduleGridHeight)
  }

  disconnect() {
    // Clean up event listeners
    document.removeEventListener('turbo:frame-load', this.boundHandleFrameLoad, true)
    document.removeEventListener('turbo:before-stream-render', this.boundHandleListStream)
    this.element.removeEventListener('click', this.boundSyncFilterContext, true)
    this.element.removeEventListener('submit', this.boundSyncFilterContext, true)
    document.removeEventListener('lane:close', this.boundCloseLane)
    document.removeEventListener('keydown', this.boundCloseOnEscape)
    window.removeEventListener('resize', this.boundScheduleGridHeight)
    if (this._gridHeightRaf) cancelAnimationFrame(this._gridHeightRaf)
  }

  closeOnEscape(event) {
    if (event.key === 'Escape' && this.layoutState.content && !this.escapeBelongsToOverlay(event)) {
      event.preventDefault()
      this.closeContent()
    }
  }

  // Menus and dialogs own the first Escape. Since their document/window
  // listeners may run after this controller's listener, visible DOM state is
  // the reliable signal; event.defaultPrevented alone depends on connect order.
  escapeBelongsToOverlay(event) {
    if (event.defaultPrevented) return true

    return Boolean(document.querySelector([
      'dialog[open]',
      '[data-neo-inline-popover-target="panel"]:not(.hidden)',
      '[data-dropdown-target="menu"]:not(.hidden)',
      '[data-neo-dropdown-target="menu"]:not(.hidden)',
      // The bulk panel's layers and field picker hide with the attribute.
      '[data-values-layer]:not([hidden])',
      '[data-select-layer]:not([hidden])',
      '[data-ticket-bulk-panel-target="pickerMenu"]:not([hidden])',
      // The "Link" modal is the content of its frame: present only while open.
      '[data-controller~="ticket-relation-modal"]',
      // The "+" modal of "Alle Meetings" hides with the class and listens on
      // window, after this document listener.
      '[data-meeting-modal-target="modal"]:not(.hidden)'
    ].join(', ')))
  }

  handleFrameLoad(event) {
    // Detail frame loaded (e.g. "New note/file" link loads a form):
    // show the content column.
    if (this.detailFrameIdValue && event.target.id === this.detailFrameIdValue) {
      this.showContent()
      return
    }

    // List frame loaded - only update layout, no state change
    if (!this.listFrameIdsValue.includes(event.target.id)) return

    // Restore stored layout state first
    const savedState = sessionStorage.getItem(this.storageKeyValue)
    if (savedState) {
      try {
        this.layoutState = JSON.parse(savedState)
      } catch (e) {
        // Error restoring state, keep current
      }
    }

    // Re-evaluate selection after frame load (rows might have been replaced)
    if (this.hasSelectedRow(event.target)) {
      this.layoutState.content = true
    }

    if (this.hasLayoutTarget) {
      this.updateLayout()
    }

    // Opted-in filters follow list refreshes even while a detail/form is open.
    if (!this.layoutState.content || this.listFilterParamsValue.length) {
      this.syncUrlFromFrame(event.target)
    }
  }

  handleListStream(event) {
    if (!this.listFilterParamsValue.length) return
    const target = event.target.getAttribute('target')
    if (!this.listFrameIdsValue.includes(target)) return
    const render = event.detail.render
    event.detail.render = async stream => {
      await render(stream)
      const frame = document.getElementById(target)
      if (frame) this.syncUrlFromFrame(frame)
    }
  }

  // Sync list pagination and opted-in filters without replacing lane state.
  syncUrlFromFrame(frame) {
    const renderedQuery = frame.querySelector('[data-list-filter-query]')?.dataset.listFilterQuery
    const frameSrc = frame.src || frame.getAttribute('src') || (renderedQuery !== undefined && window.location.href)
    if (!frameSrc) return

    try {
      const frameUrl = new URL(frameSrc, window.location.origin)
      const currentUrl = new URL(window.location.href)

      // The response names the filters it actually rendered, including cleared
      // values. Keep the open lane while changing the list's address/context.
      const filters = renderedQuery === undefined ? frameUrl.searchParams : new URLSearchParams(renderedQuery)
      for (const name of this.listFilterNames(currentUrl.searchParams, filters)) {
        currentUrl.searchParams.delete(name)
        for (const value of filters.getAll(name)) {
          if (value) currentUrl.searchParams.append(name, value)
        }
      }

      const page = filters.get('page')
      if (page && page !== '1') {
        currentUrl.searchParams.set('page', page)
      } else {
        currentUrl.searchParams.delete('page')
      }

      const items = frameUrl.searchParams.get('items')
      if (items) {
        currentUrl.searchParams.set('items', items)
      }

      // The entry keeps its state (a page's own, or Turbo's) and the wrapper
      // learns the list part it now shows (a page turn moves it).
      window.history.replaceState(window.history.state || { lane: true }, '', currentUrl.toString())
      this.syncFilterContext(currentUrl)
      this.element.dispatchEvent(new CustomEvent("lane:list-changed", { bubbles: true }))
    } catch (e) {
      // Error syncing URL from frame
    }
  }

  // A frame refresh leaves the page head and an open form in place. Refresh
  // their URLs and hidden filters; repeat before clicks/submits for controls
  // subsequently inserted by Turbo streams. Only this index's routes opt in,
  // and those of the index a lane head names (data-lane-index-url): the lane
  // of "Alle Meetings" shows a project's meeting (lib/lane/filter_context).
  syncFilterContext(current) {
    if (!this.listFilterParamsValue.length || !this.element.dataset.indexUrl) return

    const laneIndexUrls = [...this.element.querySelectorAll('[data-lane-index-url]')].map(head => head.dataset.laneIndexUrl)
    const indexes = indexPaths(this.element.dataset.indexUrl, laneIndexUrls, current.origin)
    const ownIndex = new URL(this.element.dataset.indexUrl, current.origin).pathname
    for (const control of this.element.querySelectorAll('a[href], form[action], button[formaction]')) {
      const isForm = control.tagName === 'FORM'
      if (isForm && control.method.toLowerCase() === 'get') continue
      const attribute = isForm ? 'action' : control.tagName === 'BUTTON' ? 'formaction' : 'href'
      const address = new URL(control.getAttribute(attribute), current.origin)
      const path = address.pathname.replace(/\.turbo_stream$/, '')
      const index = controlIndexPath(path, indexes)
      if (address.origin !== current.origin || !index) continue

      // List links intentionally change page, sort or view. Only explicit lane
      // return links inherit the current list state at the index route.
      if (control.tagName === 'A' && path === index && !control.matches('[data-lane-back], [data-form-lane-back], [data-lane-close]')) continue

      const previousInputs = new URLSearchParams()
      if (isForm) control.querySelectorAll('input[type="hidden"]').forEach(input => previousInputs.append(input.name, input.value))
      for (const name of this.listFilterNames(address.searchParams, current.searchParams, previousInputs)) {
        address.searchParams.delete(name)
        for (const value of current.searchParams.getAll(name)) address.searchParams.append(name, value)
        if (isForm) {
          control.querySelectorAll('input[type="hidden"]').forEach(input => { if (input.name === name) input.remove() })
          for (const value of current.searchParams.getAll(name)) {
            const input = document.createElement('input')
            input.type = 'hidden'
            input.name = name
            input.value = value
            control.append(input)
          }
        }
      }
      if (index !== ownIndex) this.applyLaneContext(control, address, isForm)
      control.setAttribute(attribute, address.toString())
    }
  }

  applyLaneContext(control, address, isForm) {
    for (const [name, value] of Object.entries(this.laneContextValue)) {
      address.searchParams.set(name, value)
      if (!isForm) continue

      control.querySelectorAll('input[type="hidden"]').forEach(input => { if (input.name === name) input.remove() })
      const input = document.createElement('input')
      input.type = 'hidden'
      input.name = name
      input.value = value
      control.append(input)
    }
  }

  listFilterNames(...sources) {
    const names = new Set(this.listFilterParamsValue)
    for (const source of sources) {
      for (const name of source.keys()) {
        if (this.listFilterParamsValue.some(key => name === key || name.startsWith(`${key}[`))) names.add(name)
      }
    }
    return names
  }

  // Called when an item is selected (row controllers, detail frame load)
  showContent() {
    this.layoutState.content = true
    this.updateLayout()
  }

  // An invisible meeting must not keep its summary/analysis subscriptions or
  // section-sync observers alive. index-page owns both the frame and placeholder;
  // this explicit event keeps the two controllers independent of each other's
  // implementation and lets reopening the same row perform a fresh request.
  clearDetailFrame() {
    this.element.dispatchEvent(new CustomEvent('lane:clear-detail', {
      bubbles: true,
      detail: { frameId: this.detailFrameIdValue }
    }))
  }

  // Column toggles — used on two-column pages via the hover_arrows arrows
  // (content arrow -> toggleList = full-screen detail).
  toggleCategories() {
    // No-op if there's no categories column (two-column layout)
    if (!this.hasCategoriesColumn) return

    this.layoutState.categories = !this.layoutState.categories
    this.updateLayout()
  }

  toggleList() {
    if (!this.layoutState.list) {
      // Trying to show list - always allowed
      this.layoutState.list = true
    } else {
      // Can't hide list without a selected item or while content is hidden
      if (!this.hasSelectedItem()) return
      if (!this.layoutState.content) return

      this.layoutState.list = false
    }
    this.updateLayout()
  }

  toggleContent() {
    if (!this.hasSelectedItem()) return

    if (!this.layoutState.content) {
      // Trying to show content - always allowed
      this.layoutState.content = true
    } else {
      // Can't hide both list and content
      if (!this.layoutState.list) return

      this.layoutState.content = false
    }
    this.updateLayout()
  }

  // True when the grid renders a third lane. The current ticket, knowledge and
  // meetings grids render none; NeoTwoColumnGridComponent only emits the aside
  // for a filled slot.
  hasPanelColumn() {
    const layout = this.hasLayoutTarget ? this.layoutTarget : document.querySelector('.layout')
    return Boolean(layout && layout.querySelector('.column.panel'))
  }

  togglePanel() {
    if (!this.hasPanelColumn()) return

    const wasOpen = this.layoutState.panel
    this.layoutState.panel = !wasOpen

    if (!wasOpen) {
      // Opening the panel lane — remember categories state, then hide to make space
      this._categoriesBeforePanel = this.layoutState.categories
      this.layoutState.categories = false
    } else {
      // Closing the panel lane — restore categories to previous state
      this.layoutState.categories = this._categoriesBeforePanel !== undefined
        ? this._categoriesBeforePanel
        : true
      delete this._categoriesBeforePanel
    }

    this.updateLayout()
  }

  // The lane's object is gone: close as the ✕ does, and take its names out of
  // the address in the SAME entry. A new entry would let Back reopen it.
  closeLane() {
    const currentUrl = new URL(window.location.href)
    const names = this.laneStateNames
    if (names.some(param => currentUrl.searchParams.has(param))) {
      names.forEach(param => currentUrl.searchParams.delete(param))
      window.history.replaceState(window.history.state || { lane: true }, '', currentUrl.toString())
    }
    this.closeContent({ history: false })
  }

  closeContent({ history = true } = {}) {
    // Mobile renders either list OR detail on the server. There is no hidden
    // list column for updateLayout() to reveal, so closing must visit the index
    // address that the visible back link uses instead of clearing the frame in
    // place and leaving a list-less placeholder behind.
    if (this.mobileOnlyLayout) {
      this.visitMobileList({ history })
      return
    }

    this.layoutState.content = false

    // Deselect the chosen row or card, wherever it is. .selected-row is the
    // one class of the list pages with a lane (tickets, knowledge and meetings,
    // written by list_row_controller and the server rows alike). The legacy
    // bg-lime marker remains in the cleanup for older mounts during navigation.
    document.querySelectorAll('.selected-row, tr.bg-lime-100').forEach(element => {
      element.classList.remove('selected-row', 'bg-lime-100')
    })

    // Remove the selection and its preview from the address (the lane names,
    // D9 of doc/dateivorschau_plan.md). The entry is the page's own (lane:
    // true, lib/lane/history); the restorer closes WITHOUT one, or Back would
    // have nowhere to go.
    if (history) {
      const currentUrl = new URL(window.location.href)
      const names = this.laneStateNames
      const hadItem = names.some(param => currentUrl.searchParams.has(param))
      names.forEach(param => currentUrl.searchParams.delete(param))
      if (hadItem) {
        window.history.pushState({ lane: true }, '', currentUrl.toString())
      }
    }

    this.updateLayout()
    if (this.clearDetailOnCloseValue) this.clearDetailFrame()
  }

  // The lane names of this page: from the wrapper's groups (this element
  // carries them), or the selection-params value as a fallback for older pages.
  get laneNames() {
    const groups = readLaneParams(this.element, null)
    return groups ? laneParamNames(groups) : this.selectionParamsValue
  }

  get laneStateNames() {
    const groups = readLaneParams(this.element, null)
    return groups
      ? [...new Set([...laneParamNames(groups), ...(groups.form || [])])]
      : this.selectionParamsValue
  }

  get mobileOnlyLayout() {
    return !this.hasLayoutTarget && this.element.dataset.viewportCurrentModeValue === 'mobile'
  }

  visitMobileList({ history }) {
    const current = new URL(window.location.href)
    const address = new URL(this.element.dataset.indexUrl || current.pathname, current.origin)
    address.search = current.search
    address.hash = current.hash
    const detailParams = [...this.laneStateNames, 'frame', 'frame_id', 'format']
    detailParams.forEach(param => address.searchParams.delete(param))

    if (window.Turbo) {
      window.Turbo.visit(address.toString(), { action: history ? 'advance' : 'replace' })
    } else {
      window.location.href = address.toString()
    }
  }

  updateLayout() {
    if (!this.hasLayoutTarget) return

    // Save layout state to sessionStorage
    sessionStorage.setItem(this.storageKeyValue, JSON.stringify(this.layoutState))

    // Update layout classes on the inner .layout element
    this.layoutTarget.classList.toggle('hide-categories', !this.layoutState.categories)
    this.layoutTarget.classList.toggle('hide-list', !this.layoutState.list)
    this.layoutTarget.classList.toggle('hide-content', !this.layoutState.content)
    // Clamp, not state: a grid without a panel column never shows one (see connect()).
    this.layoutTarget.classList.toggle('hide-panel', !this.layoutState.panel || !this.hasPanelColumn())

    // Also update the show-content class on the outer .labor-layout-view element
    const laborLayoutView = this.element // The element with data-controller="layout-toggle"
    if (laborLayoutView && laborLayoutView.classList.contains('labor-layout-view')) {
      laborLayoutView.classList.toggle('show-content', this.layoutState.content)
    }

    // Also update the show-content class on the inner .layout element to keep them in sync
    this.layoutTarget.classList.toggle('show-content', this.layoutState.content)

    // Keep the grid filling the viewport (state toggles change columns, not height,
    // but re-measuring here is cheap and covers first render + every layout change).
    this.updateGridHeight()
  }

  // Fill the fixed-height grid from its live top position down to a bottom gap that
  // mirrors the page's left gutter — replaces the old hardcoded `calc(100vh - 252px)`
  // that overshot and left a dead, non-scrollable band below the grid. Measuring
  // getBoundingClientRect().top folds in ALL chrome above the grid (page header,
  // search bar, claim banner) with no magic offset. The board is on the same
  // grid since it opens its ticket in the lane (doc/kanban_ticket_als_bahn_plan.md,
  // S1a) and is measured like the table; it used to size itself (height: 100%).
  updateGridHeight() {
    if (!this.hasLayoutTarget) return
    const grid = this.layoutTarget

    const top = grid.getBoundingClientRect().top
    const height = Math.max(window.innerHeight - top - GRID_BOTTOM_GAP_PX, GRID_MIN_HEIGHT_PX)
    grid.style.height = `${height}px`
  }

  scheduleGridHeightUpdate() {
    if (this._gridHeightRaf) return
    this._gridHeightRaf = requestAnimationFrame(() => {
      this._gridHeightRaf = null
      this.updateGridHeight()
    })
  }

  // Public API — also used by the hover_arrows outlet
  hasSelectedItem() {
    return this.layoutState.content || this.hasSelection()
  }

  // === Selection/content (Values-based) ===

  hasSelection() {
    const params = new URLSearchParams(window.location.search)
    if (this.laneNames.some(param => params.has(param))) return true

    return this.hasSelectedRow()
  }

  hasSelectedRow(scope = document) {
    if (!this.selectedRowSelectorValue) return false

    return scope.querySelector(this.selectedRowSelectorValue) !== null
  }

  hasContentLoaded() {
    if (!this.detailFrameIdValue || !this.contentSelectorValue) return false

    const frame = document.getElementById(this.detailFrameIdValue)
    return !!(frame && frame.querySelector(this.contentSelectorValue))
  }
}
