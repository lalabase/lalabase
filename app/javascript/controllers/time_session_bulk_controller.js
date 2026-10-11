import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"
import { groupFrom, rowFrom, checkboxesIn } from "time_session_bulk_markers"
import { readSelection, writeSelection } from "bulk_selection"

export default class extends Controller {
  static targets = ["checkbox", "masterCheckbox", "actionBar",
                   "panelTitle", "newGroupOption",
                   "newGroupName", "existingGroupOption", "submitButton", "groupCheckbox",
                   "formContent", "minimizeButton", "maximizeButton",
                   "selectionPanel", "takenPanel", "selectionSummary", "selectionList",
                   "selectionTotal",
                   "alreadyPanel", "alreadySummary", "alreadyList",
                   "newGroupField"]
  // What "closed" means is declared in the markup, not here: the panel has to be
  // rendered closed before any JavaScript runs, so the class list exists there
  // anyway, and a second copy in this file would be the one that goes stale. The
  // panel comes in from the bottom on a phone and from the right on a wide
  // screen, which is why this is a LIST and not one class.
  static classes = ["closed"]
  // Who is looking. sessionStorage outlives a sign-out in the same tab, so the
  // selection is filed under the reader as well as the path.
  static values = { scope: String }

  connect() {
    // A Map of id -> { duration, label }, not a Set of ids, and deliberately not
    // "whatever is ticked in the DOM": a booking filtered off the screen is still
    // in the assignment, and the panel still has to name it.
    //
    // Read from storage, because the panel has to survive a filter change and
    // close only when somebody closes it (user, 31.08.2026). Sitting around the
    // turbo frame is not enough on its own: a filter PILL carries
    // turbo_frame "_top", so it navigates the whole page. lib/bulk_selection.js
    // owns where this is kept.
    this.selection = readSelection(this.storage, this.path, this.scopeValue)
    this.minimized = false

    // Re-tick what is still selected after the frame brings new rows. Bound once
    // so disconnect can take it off again; the controller outlives many renders
    // now, and a listener added per render would fire once per past render.
    // TWO events, because rows arrive two ways. A filter or a page navigates the
    // frame and fires turbo:frame-render. Booking a time from the modal answers
    // with a turbo_stream that REPLACES the same frame, and a stream render is
    // not a frame navigation: no frame-render, so the ticks and the tint were
    // gone from the new rows while the selection still held them, and the panel
    // said "3 ausgewählt" over a list with nothing ticked.
    //
    // After the stream has swapped the DOM, not before, hence the frame.
    this.onFrameRender = this.restoreSelection.bind(this)
    this.onStreamRender = () => requestAnimationFrame(() => this.restoreSelection())
    document.addEventListener('turbo:frame-render', this.onFrameRender)
    document.addEventListener('turbo:before-stream-render', this.onStreamRender)

    // Nothing is picked when the panel opens. The old default was "eine neue
    // Abrechnung", which hid the billings behind a click and answered a question
    // the reader had not been asked yet. An empty list of boxes says a choice is
    // owed; a preselected one says the choice is made.
    this.clearTarget()
    // Re-tick whatever came back from storage before anything else reads the DOM.
    this.restoreSelection()
  }

  get storage() {
    // Reading the property itself throws where site data is blocked.
    try { return window.sessionStorage } catch { return null }
  }

  get path() {
    return window.location.pathname
  }

  disconnect() {
    document.removeEventListener('turbo:frame-render', this.onFrameRender)
    document.removeEventListener('turbo:before-stream-render', this.onStreamRender)
  }

  // What a checkbox knows about its booking. Read at the moment it is ticked,
  // because after the next frame render that element is gone.
  // Serialised only when the selection actually CHANGED. updateUI also runs for
  // a frame render, a radio click and every validate, and a sessionStorage write
  // is synchronous.
  persistSelection() {
    const snapshot = JSON.stringify(Array.from(this.selection))
    if (snapshot === this.lastPersisted) return

    this.lastPersisted = snapshot
    writeSelection(this.storage, this.path, this.selection, this.scopeValue)
  }

  entryFor(checkbox) {
    return {
      duration: parseInt(checkbox.dataset.duration, 10) || 0,
      label: checkbox.dataset.label || '',
      // Which billing this booking is already in, or null. Read here because
      // after the next frame render the element is gone, and because without it
      // the panel cannot tell that a booking picked out of billing X is being
      // handed back to billing X.
      groupId: checkbox.dataset.groupId || null
    }
  }

  // One tick applied everywhere it matters: the Map entry and the row tint.
  // toggleMaster, toggleSelection and toggleGroup used to repeat this by hand,
  // in lockstep — the third copy is what this method replaces.
  applySelection(checkbox, isChecked) {
    if (isChecked) {
      this.selection.set(checkbox.value, this.entryFor(checkbox))
    } else {
      this.selection.delete(checkbox.value)
    }
    const row = this._findRow(checkbox)
    if (!row) return
    if (isChecked) { row.dataset.selected = 'true' } else { delete row.dataset.selected }
  }

  // Split by "is this already in the billing we are assigning to". Two lists,
  // and only the first one counts towards the result.
  partitionedSelection() {
    const target = this.existingGroupId
    const taken = []
    const already = []

    this.selection.forEach((entry, id) => {
      const row = [id, entry]
      if (target && entry.groupId === target) { already.push(row) } else { taken.push(row) }
    })
    return { taken, already }
  }

  // New rows have arrived. Anything still selected gets its tick and its tint
  // back; anything filtered away stays in the selection and keeps being listed
  // in the panel, which is the point of holding the entry rather than the node.
  restoreSelection() {
    // Cheap, but it runs on every frame render on the page, including the
    // billing-entries frames this panel opens itself. Nothing to do when nobody
    // has selected anything.
    if (this.selection.size === 0 && this.checkboxTargets.every(box => !box.checked)) return

    this.checkboxTargets.forEach(checkbox => {
      const selected = this.selection.has(checkbox.value)
      checkbox.checked = selected
      // A booking somebody billed in the meantime is no longer selectable, and a
      // disabled checkbox is how the page says so. Keeping it would send an id
      // the server refuses for the whole batch.
      if (selected && checkbox.disabled) {
        this.selection.delete(checkbox.value)
        checkbox.checked = false
        return
      }
      // Refresh the stored entry from the FRESH row: a colleague may have moved
      // this booking into a billing since it was ticked, and a stale groupId
      // would list it as about-to-be-taken-over and count its minutes into a
      // total that already holds them — the double count this panel prevents.
      if (selected) this.selection.set(checkbox.value, this.entryFor(checkbox))
      const row = this._findRow(checkbox)
      if (row) {
        if (selected) { row.dataset.selected = 'true' } else { delete row.dataset.selected }
      }
    })
    this.syncGroupCheckboxes()
    this.updateUI()
  }

  toggleMaster(event) {
    const isChecked = event.target.checked
    this.checkboxTargets.forEach(checkbox => {
      checkbox.checked = isChecked
      this.applySelection(checkbox, isChecked)
    })
    // Sync group checkboxes
    this.groupCheckboxTargets.forEach(gc => gc.checked = isChecked)
    this.updateUI()
  }

  toggleSelection(event) {
    const checkbox = event.target
    this.applySelection(checkbox, checkbox.checked)
    // Uncheck master if not all are selected
    if (!checkbox.checked && this.hasMasterCheckboxTarget) {
      this.masterCheckboxTarget.checked = false
    }
    this.updateUI()
  }

  toggleGroup(event) {
    const groupCheckbox = event.target
    const isChecked = groupCheckbox.checked

    const groupContainer = groupFrom(groupCheckbox)

    if (!groupContainer) return

    checkboxesIn(groupContainer).forEach(checkbox => {
      if (!checkbox.disabled) {
        checkbox.checked = isChecked
        this.applySelection(checkbox, isChecked)
      }
    })

    this.updateUI()
  }

  updateUI() {
    const count = this.selection.size

    // Show/hide action bar based on selection (offcanvas animation)
    if (this.hasActionBarTarget) {
      if (count > 0) {
        this.actionBarTarget.classList.remove(...this.closedClasses)
      } else {
        this.actionBarTarget.classList.add(...this.closedClasses)
      }
    }

    this.renderSelection()
    // One seam: every path that changes the selection ends here. Serialised only
    // when it CHANGED, because updateUI also runs for a frame render, a radio
    // click and every validate, and sessionStorage writes are synchronous.
    this.persistSelection()

    // Keep the bulk submit button in sync with the current selection & form state
    this.validateForm()

    // Update master checkbox state. Compared against what is RENDERED on
    // purpose: "all" means the rows in front of the reader, and a selection
    // carried over from another page must not leave it ticked here.
    if (this.hasMasterCheckboxTarget && this.checkboxTargets.length > 0) {
      const allChecked = this.checkboxTargets.every(cb => cb.checked)
      const someChecked = this.checkboxTargets.some(cb => cb.checked)
      
      this.masterCheckboxTarget.checked = allChecked
      this.masterCheckboxTarget.indeterminate = someChecked && !allChecked
    }
  }

  // Prevent row click when clicking checkbox
  stopPropagation(event) {
    event.stopPropagation()
  }

  validateForm() {
    if (!this.hasSubmitButtonTarget) {
      console.warn('Submit button target not found')
      return
    }

    // One question: is a row picked, and if it is the new-billing row, does it
    // carry a name yet.
    const isValid = this.isNewGroup
      ? this.hasNewGroupNameTarget && this.newGroupNameTarget.value.trim().length > 0
      : this.existingGroupId !== null

    // Something has to actually MOVE. With only already-filed rows picked, the
    // assignment is a guaranteed no-op, and an enabled button promising one is
    // worse than a disabled one explaining itself through the second list.
    const moving = this.partitionedSelection().taken.length
    const shouldBeEnabled = isValid && moving > 0
    this.submitButtonTarget.disabled = !shouldBeEnabled
    this.submitButtonTarget.classList.toggle('opacity-50', !shouldBeEnabled)
    this.submitButtonTarget.classList.toggle('cursor-not-allowed', !shouldBeEnabled)
    this.submitButtonTarget.classList.toggle('pointer-events-none', !shouldBeEnabled)

    this.renderBillingResult()
  }

  // Show or hide what a billing already holds. The frame inside is
  // loading="lazy", so unhiding it IS the request: Turbo fetches the first time
  // it becomes visible, and a billing nobody opens costs nothing.
  toggleBillingEntries(event) {
    const button = event.currentTarget
    const row = button.closest('li')
    const box = row?.querySelector('[data-billing-entries]')
    if (!box) return

    const open = box.classList.toggle('hidden') === false
    button.setAttribute('aria-expanded', String(open))
    row.querySelector('[data-billing-chevron]')?.classList.toggle('rotate-90', open)
  }

  // What the chosen billing BECOMES, on its own line, next to what it holds
  // today. The reader would otherwise add the header's selection total and the
  // line's total in their head, every time, to answer the only question they
  // came here with: how big does this billing get.
  //
  // Only on the chosen line, and only while something is selected: a column of
  // hypotheticals of which at most one can happen is noise, and it buries the
  // totals being compared.
  renderBillingResult() {
    // Only what is actually moving: a booking already in this billing brings no
    // minutes with it, and adding them would show a total containing the same
    // time twice.
    const selected = this.takenMinutes()

    this.existingGroupOptionTargets.forEach(option => {
      const field = option.closest('li')?.querySelector('[data-billing-result]')
      if (!field) return

      if (option.checked && selected > 0) {
        const base = parseInt(option.dataset.minutes, 10) || 0
        const total = this.formatDuration(base + selected)
        field.textContent = `\u2192 ${total}`
        // The label REPLACES the text for a screen reader, so it has to carry the
        // number too: "Summe nach dem Übernehmen" alone said which number it was
        // and never what it said.
        field.setAttribute('aria-label', `${I18n.t('stimulus.time_session.billing_after')}: ${total}`)
        field.title = I18n.t('stimulus.time_session.billing_after')
        field.classList.remove('hidden')
      } else {
        field.textContent = ''
        field.classList.add('hidden')
      }
    })
  }

  submitBulkAssignment(event) {
    event.preventDefault()
    
    if (this.selection.size === 0) {
      alert(I18n.t('stimulus.time_session.select_at_least_one'))
      return
    }
    
    // Prepare form data
    const formData = new FormData()
    this.selection.forEach((_entry, id) => {
      formData.append('time_session_ids[]', id)
    })
    
    if (this.isNewGroup) {
      formData.append('create_new_group', 'true')
      formData.append('new_group_name', this.newGroupNameTarget.value)
    } else {
      formData.append('create_new_group', 'false')
      formData.append('existing_group_id', this.existingGroupId || '')
    }
    
    // Get CSRF token
    const csrfToken = document.querySelector('meta[name="csrf-token"]').content
    
    // Get the URL from the action bar element
    const url = this.actionBarTarget.dataset.timeSessionBulkUrl
    if (!url) {
      console.error('Bulk assignment URL not found')
      alert(I18n.t('stimulus.time_session.bulk_assignment_url_not_found'))
      return
    }
    
    // Submitting bulk assignment
    
    // One submit at a time: a double click with "Neue Abrechnung" would create
    // two groups, the second one an empty orphan. Success reloads the page, so
    // only the error path needs to re-enable the button.
    if (this.hasSubmitButtonTarget) this.submitButtonTarget.disabled = true

    // Submit via fetch
    fetch(url, {
      method: 'POST',
      headers: {
        'X-CSRF-Token': csrfToken,
        'Accept': 'text/html'
      },
      body: formData,
      // manual, not follow: following it made THIS request read the flash the
      // server had just set, so the reload below showed a blank page and a
      // partial success said nothing at all. Unfollowed, the flash is still
      // waiting for the reload. An unfollowed redirect arrives as
      // type 'opaqueredirect' with ok false, so it is checked by hand.
      redirect: 'manual'
    })
    .then(response => {
      if (response.ok || response.type === 'opaqueredirect') {
        // The selection outlives a page load on purpose, which makes clearing it
        // after a SUCCESSFUL assignment part of the assignment. Without this the
        // reload below reopens the panel holding the rows that were just filed,
        // still carrying the billing they had BEFORE, so the panel offers to
        // take them over again and counts their minutes into a total that now
        // contains them: exactly the double count this panel exists to prevent.
        this.selection.clear()
        this.persistSelection()
        window.location.reload()
      } else {
        return response.text().then(text => {
          throw new Error(text)
        })
      }
    })
    .catch(error => {
      console.error('Error:', error)
      if (this.hasSubmitButtonTarget) this.submitButtonTarget.disabled = false
      alert(I18n.t('stimulus.time_session.bulk_update_failed') + ': ' + error.message)
    })
  }

  toggleMinimize() {
    this.minimized = !this.minimized

    if (this.minimized) {
      // Minimise: hide the form
      if (this.hasFormContentTarget) {
        this.formContentTarget.classList.add('hidden')
      }
      if (this.hasMinimizeButtonTarget) {
        this.minimizeButtonTarget.classList.add('hidden')
      }
      if (this.hasMaximizeButtonTarget) {
        this.maximizeButtonTarget.classList.remove('hidden')
      }
    } else {
      // Maximise: show the form
      if (this.hasFormContentTarget) {
        this.formContentTarget.classList.remove('hidden')
      }
      if (this.hasMinimizeButtonTarget) {
        this.minimizeButtonTarget.classList.remove('hidden')
      }
      if (this.hasMaximizeButtonTarget) {
        this.maximizeButtonTarget.classList.add('hidden')
      }
    }
  }

  // The minutes that actually move. Summed from the selection, not from the
  // ticked boxes: a booking filtered off the screen is still in the assignment,
  // so it still counts. The already-filed ones are left out, because they bring
  // nothing with them.
  // One method, two readers: the foot of the list says this number, and the
  // chosen billing adds it to what it holds. They must never disagree.
  takenMinutes() {
    return this.partitionedSelection().taken
               .reduce((total, [, entry]) => total + entry.duration, 0)
  }

  // The billings are a LIST of radios, not a select (design draft): a select
  // hides the choices behind one more click and shows only the one already
  // picked. Which one is chosen is therefore a question to the group, not a
  // property of one element.
  //
  // The new-billing row shares that radio group, which is what makes the whole
  // panel ONE choice, but it is a separate target: an existing billing has an
  // id and the new one has not, and nothing here should have to tell them apart
  // by comparing against a magic string.
  get existingGroupId() {
    const picked = this.existingGroupOptionTargets.find(option => option.checked)
    return picked ? picked.value : null
  }

  get isNewGroup() {
    return this.hasNewGroupOptionTarget && this.newGroupOptionTarget.checked
  }

  // Every row that can be picked, billings and the new one alike. Clearing has
  // to reach all of them or a stale tick survives in the half nobody looked at.
  get optionTargets() {
    return this.hasNewGroupOptionTarget
      ? [...this.existingGroupOptionTargets, this.newGroupOptionTarget]
      : this.existingGroupOptionTargets
  }

  clearTarget() {
    this.optionTargets.forEach(option => { option.checked = false })
    this.lastPickedId = null
    this.syncNewGroupField()
  }

  // A radio cannot be unpicked: clicking the one that is already chosen does
  // nothing, so a reader who ticked the wrong billing could only pick another
  // one or leave through "eine neue Abrechnung". Clicking it again clears it
  // (user, 31.08.2026).
  //
  // Tracked here rather than read off the input, because by the time click runs
  // the browser has already set checked, and a fresh pick fires change while a
  // repeat click fires none: only the controller can tell the two apart.
  // Updated ONLY here, so chooseBilling cannot make the first click look like a
  // repeat.
  togglePick(event) {
    const input = event.currentTarget

    if (this.lastPickedId === input.value) {
      input.checked = false
      this.lastPickedId = null
    } else {
      this.lastPickedId = input.value
    }
    this.chooseBilling()

    // Picking the new-billing row asks for a name, so put the cursor in it. Here
    // and not in syncNewGroupField, which also runs on every clear and on
    // connect: focusing there would take the cursor out of whatever the reader
    // was doing.
    if (this.isNewGroup && this.hasNewGroupNameTarget) this.newGroupNameTarget.focus()
  }

  // Choosing a billing changes the split, so both the lists and the arithmetic
  // have to follow. Separate from validateForm because renderSelection calls
  // that one already; wiring the option straight to validateForm would either
  // miss the redraw or loop.
  chooseBilling() {
    this.syncNewGroupField()
    this.renderSelection()
    this.validateForm()
  }

  // The name field belongs to its row and appears only while that row is picked.
  // Disabled as well as hidden, because a hidden field still submits, and
  // emptied on the way out, so a name typed and then abandoned cannot come back
  // attached to a different choice.
  syncNewGroupField() {
    const isNew = this.isNewGroup
    if (this.hasNewGroupFieldTarget) {
      this.newGroupFieldTarget.classList.toggle('hidden', !isNew)
    }
    if (this.hasNewGroupNameTarget) {
      this.newGroupNameTarget.disabled = !isNew
      if (!isNew) this.newGroupNameTarget.value = ''
    }
  }

  // The list of what is about to be taken over. Read from the selection Map, not
  // from the ticked checkboxes: a booking selected on page one is still going to
  // be taken over after the reader has filtered or paged away from it, and this
  // list is the only place they can still see it. Reading the DOM would show
  // them a shorter list than the one they are about to submit.
  //
  // Keyed by id, which also settles the double-render: the page carries the
  // desktop table AND the phone cards, so every booking has two checkboxes.
  renderSelection() {
    if (!this.hasSelectionListTarget) return

    const { taken, already } = this.partitionedSelection()

    this.selectionListTarget.replaceChildren(
      ...taken.map(([id, entry]) => this.selectionRow(id, entry))
    )
    if (this.hasSelectionSummaryTarget) {
      this.selectionSummaryTarget.textContent =
        I18n.t('stimulus.time_session.selection_intro', { count: taken.length })
    }
    if (this.hasSelectionTotalTarget) {
      this.selectionTotalTarget.textContent = this.formatDuration(this.takenMinutes())
    }
    // Heading, list and total go together: with nothing moving there is no list
    // to head and no minutes to add up, and a "Summe 00:00" under an empty list
    // would be the panel answering a question nobody asked.
    if (this.hasTakenPanelTarget) {
      this.takenPanelTarget.classList.toggle('hidden', taken.length === 0)
    }

    // The ones that are already where they are being sent. Listed, so the reader
    // can see why the numbers do not add up the way they expected, and still
    // droppable.
    if (this.hasAlreadyListTarget) {
      this.alreadyListTarget.replaceChildren(
        ...already.map(([id, entry]) => this.selectionRow(id, entry))
      )
    }
    if (this.hasAlreadySummaryTarget) {
      this.alreadySummaryTarget.textContent =
        I18n.t('stimulus.time_session.selection_already', { count: already.length })
    }
    if (this.hasAlreadyPanelTarget) {
      this.alreadyPanelTarget.classList.toggle('hidden', already.length === 0)
    }

    if (this.hasSelectionPanelTarget) {
      this.selectionPanelTarget.classList.toggle('hidden', this.selection.size === 0)
    }
  }

  // Built with createElement and textContent throughout: a label is a booking's
  // own description or a ticket title, so it is somebody's text, and innerHTML
  // here would put it back on the page as markup.
  // The one-line shape (46px duration slot, then the name) has a server-side
  // twin: app/views/organisations/time_session_groups/_entries.html.erb renders
  // a billing's rows in the SAME shape on purpose — change both or neither.
  selectionRow(id, entry) {
    const row = document.createElement('li')
    row.className = 'flex items-center gap-2 text-xs leading-6 text-cream-700'

    const duration = document.createElement('span')
    duration.className = 'w-[46px] shrink-0 font-mono text-cream-600'
    duration.textContent = this.formatDuration(entry.duration)

    const label = document.createElement('span')
    label.className = 'min-w-0 flex-1 truncate'
    label.textContent = entry.label
    label.title = entry.label

    const drop = document.createElement('button')
    drop.type = 'button'
    // A 44px-ish target on a phone, slim at a desk. It was a bare px-1 glyph,
    // which is about 12px of anything to hit.
    drop.className = 'flex h-9 w-9 shrink-0 items-center justify-center rounded text-cream-500 transition-colors hover:bg-cream-200 hover:text-cream-900 lg:h-6 lg:w-6'
    drop.dataset.action = 'click->time-session-bulk#deselect'
    drop.dataset.timeSessionId = id
    drop.setAttribute('aria-label', I18n.t('stimulus.time_session.deselect'))
    drop.title = I18n.t('stimulus.time_session.deselect')
    drop.textContent = '\u00d7'

    row.append(duration, label, drop)
    return row
  }

  // Dropping one from the list unticks it wherever it is drawn. Both halves of
  // the page carry a checkbox for the same booking, and leaving the hidden one
  // ticked would put the booking back the next time the reader changed the
  // window width.
  deselect(event) {
    const id = event.currentTarget.dataset.timeSessionId
    if (!id) return

    this.selection.delete(id)
    this.checkboxTargets.forEach(checkbox => {
      if (checkbox.value !== id) return
      checkbox.checked = false
      const row = this._findRow(checkbox)
      if (row) delete row.dataset.selected
    })
    this.syncGroupCheckboxes()
    if (this.hasMasterCheckboxTarget) this.masterCheckboxTarget.checked = false

    // Where the keyboard goes next. The button that was just pressed is about to
    // be replaced, and without this the focus falls back to the document: a
    // reader removing three rows would have to find their way back three times.
    const position = Array.from(event.currentTarget.closest('ul').children)
                          .indexOf(event.currentTarget.closest('li'))
    this.updateUI()
    this.focusAfterRemoval(position)
  }

  focusAfterRemoval(position) {
    const rows = this.hasSelectionListTarget ? Array.from(this.selectionListTarget.children) : []
    const next = rows[position] || rows[rows.length - 1]
    const button = next?.querySelector('button')

    if (button) { button.focus() } else if (this.hasPanelTitleTarget) {
      // Nothing left to remove: the panel's title takes the focus, so the reader
      // stays in the panel instead of being dropped at the top of the page. Its
      // tabindex is in the markup, not set here: focus() on an element that is
      // not focusable does nothing, silently, and this is the one moment the
      // reader depends on it.
      // This catches the case where the taken list empties while the panel stays
      // open, so far only "everything picked is already in the target billing".
      // Drop the last selection outright and the panel closes with it, and focus
      // falls to the document; there is nothing left inside to hold it. Measured,
      // not assumed, and true of the old target too.
      this.panelTitleTarget.focus()
    }
  }

  // A row's checkbox means "all of mine", so it must not stay ticked once one of
  // its bookings has been dropped.
  syncGroupCheckboxes() {
    this.groupCheckboxTargets.forEach(groupCheckbox => {
      const container = groupFrom(groupCheckbox)
      if (!container) return
      const boxes = checkboxesIn(container).filter(box => !box.disabled)
      groupCheckbox.checked = boxes.length > 0 && boxes.every(box => box.checked)
    })
  }

  formatDuration(minutes) {
    if (!minutes || minutes === 0) {
      return '00:00'
    }

    const hours = Math.floor(minutes / 60)
    const mins = minutes % 60

    // Padded like every other duration on this screen (TimeSession.format_duration
    // renders 01:06, not 1:06); the panel sits right beside them.
    return `${hours.toString().padStart(2, '0')}:${mins.toString().padStart(2, '0')}`
  }

  cancelBulkAssignment() {
    // Clear all selections
    this.checkboxTargets.forEach(checkbox => {
      checkbox.checked = false
      const row = this._findRow(checkbox)
      if (row) delete row.dataset.selected
    })
    this.groupCheckboxTargets.forEach(gc => gc.checked = false)
    this.selection.clear()
    // The target too. Closing the panel and opening it again used to bring back
    // the billing picked last time, over a selection that no longer existed.
    this.clearTarget()
    this.minimized = false
    this.updateUI()
  }

  // The booking element that carries the selection tint. Its marker is ours, so
  // a wrapper somebody adds cannot change what gets selected.
  _findRow(checkbox) {
    return rowFrom(checkbox)
  }
}
