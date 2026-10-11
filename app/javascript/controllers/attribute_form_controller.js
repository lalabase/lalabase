import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"
import I18n from "i18n"

export default class extends Controller {
  static targets = ["optionsContainer", "optionsList", "lengthValidation", "deadlineSection", "systemFunctionsTemplate", "systemFunctionsToggle", "submitButton"]

  connect() {
    this.systemFunctionsVisible = false
    this.updateFieldOptions()
    this.initSortable()
    this.initDirtyTracking()
  }

  disconnect() {
    if (this.sortable) {
      this.sortable.destroy()
    }
    if (this.boundCheckDirty) {
      this.element.removeEventListener('input', this.boundCheckDirty)
      this.element.removeEventListener('change', this.boundCheckDirty)
    }
  }

  // ── Dirty tracking ──────────────────────────────────────────────

  initDirtyTracking() {
    if (!this.hasSubmitButtonTarget) return

    requestAnimationFrame(() => {
      this.initialFormState = this.serializeForm()
    })

    this.boundCheckDirty = this.checkDirty.bind(this)
    this.element.addEventListener('input', this.boundCheckDirty)
    this.element.addEventListener('change', this.boundCheckDirty)
  }

  serializeForm() {
    const formData = new FormData(this.element)
    const entries = []
    for (const [key, value] of formData.entries()) {
      entries.push(`${key}=${value}`)
    }
    return entries.join('&')
  }

  checkDirty() {
    if (!this.hasSubmitButtonTarget || this.initialFormState === undefined) return
    const isDirty = this.serializeForm() !== this.initialFormState
    this.setSubmitEnabled(isDirty)
  }

  setSubmitEnabled(enabled) {
    const btn = this.submitButtonTarget
    btn.disabled = !enabled
    // Styling comes from Neo::Buttons::ButtonComponent (primary). Here we only
    // toggle the disabled look, identical to the component's disabled_classes.
    btn.classList.toggle('opacity-50', !enabled)
    btn.classList.toggle('cursor-not-allowed', !enabled)
    btn.classList.toggle('pointer-events-none', !enabled)
  }

  // ── Sortable ────────────────────────────────────────────────────

  initSortable() {
    if (!this.hasOptionsListTarget) return

    this.sortable = Sortable.create(this.optionsListTarget, {
      animation: 150,
      handle: '.drag-handle',
      ghostClass: 'sortable-ghost',
      chosenClass: 'sortable-chosen',
      onEnd: () => this.checkDirty()
    })
  }

  // ── Field type toggling ─────────────────────────────────────────

  updateFieldOptions() {
    const fieldType = this.element.querySelector('select[name="ticket_attribute_definition[field_type]"]').value

    // Show/hide options container
    if (['select', 'multiselect'].includes(fieldType)) {
      this.optionsContainerTarget.classList.remove('hidden')
    } else {
      this.optionsContainerTarget.classList.add('hidden')
    }

    // Show/hide length validation (only for text fields)
    if (fieldType === 'text') {
      this.lengthValidationTarget.classList.remove('hidden')
    } else {
      this.lengthValidationTarget.classList.add('hidden')
    }

    // Show/hide the deadline marker (only for date fields)
    if (this.hasDeadlineSectionTarget) {
      this.deadlineSectionTarget.classList.toggle('hidden', fieldType !== 'date')
    }
  }

  // ── System functions ────────────────────────────────────────────

  toggleSystemFunctions(event) {
    event.preventDefault()
    this.systemFunctionsVisible = !this.systemFunctionsVisible

    // Toggle all system-functions-panel elements
    this.element.querySelectorAll('.system-functions-panel').forEach(panel => {
      panel.classList.toggle('hidden', !this.systemFunctionsVisible)
    })

    // Toggle active state on the gear button
    if (this.hasSystemFunctionsToggleTarget) {
      this.systemFunctionsToggleTarget.classList.toggle('text-gray-400', !this.systemFunctionsVisible)
      this.systemFunctionsToggleTarget.classList.toggle('text-lime-600', this.systemFunctionsVisible)
      this.systemFunctionsToggleTarget.classList.toggle('bg-lime-50', this.systemFunctionsVisible)
    }
  }

  // Update the meta line when a system function checkbox changes
  updateIndicator(event) {
    const optionItem = event.target.closest('.option-item')
    if (!optionItem) return

    const checked = optionItem.querySelectorAll('.sf-checkbox:checked')
    const names = Array.from(checked).map(cb => {
      // Get label text from the parent label element
      const label = cb.closest('label')
      if (!label) return cb.value
      // Get text content excluding the icon and checkbox
      return label.textContent.trim()
    })

    // Find or create the meta line
    let metaLine = optionItem.querySelector('.sf-meta-line')
    let sfSpan = metaLine ? metaLine.querySelector('.sf-meta-functions') : null

    if (checked.length > 0) {
      if (!metaLine) {
        // Create meta line if it doesn't exist
        const firstRow = optionItem.querySelector('.flex.gap-2')
        metaLine = document.createElement('div')
        metaLine.className = 'ml-8 mt-0.5 flex items-center gap-1.5 text-[11px] text-gray-400 sf-meta-line'
        firstRow.insertAdjacentElement('afterend', metaLine)
      }

      if (!sfSpan) {
        // Add separator if there's already content
        if (metaLine.children.length > 0 && !metaLine.querySelector('.sf-meta-sep')) {
          const sep = document.createElement('span')
          sep.className = 'text-gray-300 sf-meta-sep'
          sep.innerHTML = '&middot;'
          // Insert before the merge link if present, otherwise append
          const mergeLink = metaLine.querySelector('a')
          if (mergeLink) {
            mergeLink.previousElementSibling?.classList.contains('sf-meta-sep') ||
              metaLine.insertBefore(sep, mergeLink.previousElementSibling || mergeLink)
          } else {
            metaLine.appendChild(sep)
          }
        }
        sfSpan = document.createElement('span')
        sfSpan.className = 'sf-meta-functions text-violet-400'
        // Insert before merge separator+link if present
        const mergeLink = metaLine.querySelector('a')
        if (mergeLink && mergeLink.previousElementSibling) {
          metaLine.insertBefore(sfSpan, mergeLink.previousElementSibling)
        } else if (mergeLink) {
          metaLine.insertBefore(sfSpan, mergeLink)
        } else {
          metaLine.appendChild(sfSpan)
        }
      }

      sfSpan.innerHTML = `<i class="bi bi-gear text-[9px]"></i> ${names.join(', ')}`
    } else {
      // Remove sf span and its separator
      if (sfSpan) {
        const prevSep = sfSpan.previousElementSibling
        if (prevSep && prevSep.classList.contains('sf-meta-sep')) prevSep.remove()
        sfSpan.remove()
      }
      // Remove meta line entirely if nothing else in it
      if (metaLine && metaLine.children.length === 0) {
        metaLine.remove()
      }
    }
  }

  // ── Options management ──────────────────────────────────────────

  addOption(event) {
    event.preventDefault()

    const index = this.optionsListTarget.children.length

    // Build system functions HTML from template if available
    let systemFunctionsHtml = ''
    if (this.hasSystemFunctionsTemplateTarget) {
      // Replace __INDEX__ and respect current visibility state
      const raw = this.systemFunctionsTemplateTarget.innerHTML.replace(/__INDEX__/g, index)
      if (this.systemFunctionsVisible) {
        systemFunctionsHtml = raw.replace('system-functions-panel hidden', 'system-functions-panel')
      } else {
        systemFunctionsHtml = raw
      }
    }

    const optionTemplate = `
      <div class="option-item" data-option-index="${index}">
        <div class="flex gap-2 items-center">
          <span class="drag-handle cursor-grab text-gray-400 hover:text-gray-600 px-1"><i class="bi bi-grip-vertical text-lg"></i></span>

          <input type="text"
                 name="ticket_attribute_definition[options][]"
                 value=""
                 class="flex-1 px-4 py-2 border-2 border-black rounded-lg focus:outline-none focus:ring-2 focus:ring-lime-400"
                 placeholder="Option ${index + 1}">

          <input type="color"
                 name="ticket_attribute_definition[option_colors][]"
                 value="#000000"
                 class="w-12 h-10 border-2 border-black rounded cursor-pointer"
                 title="${I18n.t('stimulus.attribute_form.choose_color')}">

          <button type="button"
                  data-action="click->attribute-form#removeOption"
                  class="py-2 px-3 relative inline-flex flex-row items-center justify-center rounded text-sm tracking-[.00714em] font-medium border border-black bg-red-200 hover:bg-red-300 focus:bg-red-300 text-black hover:shadow-[2px_2px_0_0_#000000] focus:shadow-[2px_2px_0_0_#000000]">
            <i class="bi bi-trash"></i>
          </button>
        </div>
        ${systemFunctionsHtml}
      </div>
    `

    this.optionsListTarget.insertAdjacentHTML('beforeend', optionTemplate)
    this.checkDirty()
  }

  removeOption(event) {
    event.preventDefault()
    event.currentTarget.closest('.option-item').remove()
    this.checkDirty()
  }

}
