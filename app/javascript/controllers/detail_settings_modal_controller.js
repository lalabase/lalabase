import { Controller } from "@hotwired/stimulus"

/**
 * Detail Settings Modal Controller
 *
 * Modal for ticket detail header settings with auto-save and live preview.
 * Listens for change events (radio inputs + checkboxes), updates the preview and saves via PATCH JSON.
 */
export default class extends Controller {
  static targets = ["modal", "saveIndicator", "radioLabel", "checkboxLabel",
    "previewAssignee", "previewHeadingDate", "previewTime",
    "previewSubscriber", "previewActionBar", "previewSubtasks", "colorHint"]
  static values = { updateUrl: String }

  static classes = ["active"]

  connect() {
    this.dirty = false
    this.debounceTimer = null
    this.highlightLabels()
  }

  disconnect() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
  }

  open() {
    // Move entire controller element to body to escape stacking context
    this.originalParent = this.element.parentNode
    this.originalNextSibling = this.element.nextSibling
    document.body.appendChild(this.element)

    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    this.dirty = false
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")

    // Move controller element back so DOM stays consistent
    if (this.originalParent) {
      this.originalParent.insertBefore(this.element, this.originalNextSibling)
      this.originalParent = null
      this.originalNextSibling = null
    }

    if (this.dirty) {
      window.Turbo.visit(window.location.href, { action: "replace" })
    }
  }

  closeOnBackdrop(event) {
    if (event.target === event.currentTarget) {
      this.close()
    }
  }

  // Escape owner (lib/escape_owner.js): the lane behind stays open while this is true.
  ownsEscape() {
    return this.hasModalTarget && !this.modalTarget.classList.contains("hidden")
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && this.ownsEscape()) {
      this.close()
    }
  }

  onChange() {
    this.highlightLabels()
    this.updatePreview()
    this.debouncedSave()
  }

  highlightLabels() {
    this.radioLabelTargets.forEach(label => {
      const radio = label.querySelector('input[type="radio"]')
      if (radio && radio.checked) {
        label.classList.add("border-lime-600", "bg-lime-100", "text-lime-800", "font-medium")
        label.classList.remove("border-gray-300", "text-gray-700")
      } else {
        label.classList.remove("border-lime-600", "bg-lime-100", "text-lime-800", "font-medium")
        label.classList.add("border-gray-300", "text-gray-700")
      }
    })

    this.checkboxLabelTargets.forEach(label => {
      const checkbox = label.querySelector('input[type="checkbox"]')
      if (checkbox && checkbox.checked) {
        label.classList.add("border-sky-600", "bg-sky-100", "text-sky-800", "font-medium")
        label.classList.remove("border-gray-300", "text-gray-700")
      } else {
        label.classList.remove("border-sky-600", "bg-sky-100", "text-sky-800", "font-medium")
        label.classList.add("border-gray-300", "text-gray-700")
      }
    })
  }

  updatePreview() {
    const settings = this.collectFormData()
    const targetMap = {
      assignee_display: "previewAssignee",
      heading_date: "previewHeadingDate",
      time_display: "previewTime",
      subscriber_display: "previewSubscriber",
      action_bar: "previewActionBar",
      subtasks_display: "previewSubtasks"
    }

    for (const [key, targetName] of Object.entries(targetMap)) {
      const value = settings[key]
      if (value === undefined) continue

      const targets = this[`${targetName}Targets`]
      targets.forEach(el => {
        el.classList.toggle("hidden", el.dataset.previewMode !== value)
      })
    }

    // Toggle simple field previews (tags) based on field_toggle radios
    const fieldToggles = this.collectFieldToggles()
    for (const [key, value] of Object.entries(fieldToggles)) {
      this.modalTarget.querySelectorAll(`[data-preview-field="${key}"]:not([data-preview-custom-mode])`).forEach(el => {
        el.classList.toggle('hidden', value === 'off')
      })
    }

    // Toggle custom field previews based on custom_field_display radios
    const customModes = this.collectCustomFieldDisplay()
    let anyColored = false
    for (const [key, mode] of Object.entries(customModes)) {
      if (mode === 'colored') anyColored = true
      this.modalTarget.querySelectorAll(`[data-preview-field="${key}"]`).forEach(el => {
        const elMode = el.dataset.previewCustomMode
        if (!elMode) return
        if (mode === 'off') {
          el.classList.add('hidden')
        } else {
          el.classList.toggle('hidden', elMode !== mode)
        }
      })
    }

    // Show/hide color hint based on whether any custom field uses "colored"
    if (this.hasColorHintTarget) {
      this.colorHintTarget.classList.toggle('hidden', !anyColored)
    }
  }

  debouncedSave() {
    if (this.debounceTimer) clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => this.save(), 300)
  }

  async save() {
    const detailSettings = this.collectFormData()
    const headerColumns = this.collectHeaderColumns()

    // Add custom_field_display to detail_settings
    detailSettings.custom_field_display = this.collectCustomFieldDisplay()

    try {
      const response = await fetch(this.updateUrlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("[name='csrf-token']").content,
          "Accept": "application/json"
        },
        body: JSON.stringify({
          view_configuration: {
            detail_settings: detailSettings,
            header_columns: headerColumns
          }
        })
      })

      if (response.ok) {
        this.dirty = true
        this.showSaveIndicator()
      }
    } catch (error) {
      console.error("Detail settings save failed:", error)
    }
  }

  collectFormData() {
    const data = {}
    const radios = this.modalTarget.querySelectorAll('input[type="radio"]:checked')
    radios.forEach(radio => {
      const name = radio.name.match(/detail_settings\[(\w+)\]/)
      if (name) {
        data[name[1]] = radio.value
      }
    })
    return data
  }

  // Collect on/off toggles for simple fields (tags) and date fields
  collectFieldToggles() {
    const toggles = {}
    this.modalTarget.querySelectorAll('input[name^="field_toggle["]:checked').forEach(radio => {
      const key = radio.dataset.fieldKey
      if (key) toggles[key] = radio.value
    })
    return toggles
  }

  // Collect custom field display modes (off/text/colored)
  collectCustomFieldDisplay() {
    const modes = {}
    this.modalTarget.querySelectorAll('input[name^="custom_field_display["]:checked').forEach(radio => {
      const key = radio.dataset.customFieldKey
      if (key) modes[key] = radio.value
    })
    return modes
  }

  collectHeaderColumns() {
    const columns = []

    // Assignees always included
    columns.push('assignees')

    // Simple fields and date fields: "on" → include
    const fieldToggles = this.collectFieldToggles()
    for (const [key, value] of Object.entries(fieldToggles)) {
      if (value === 'on') columns.push(key)
    }

    // Custom fields: "text" or "colored" → include, "off" → exclude
    const customModes = this.collectCustomFieldDisplay()
    for (const [key, mode] of Object.entries(customModes)) {
      if (mode !== 'off') columns.push(key)
    }

    return columns
  }

  showSaveIndicator() {
    if (!this.hasSaveIndicatorTarget) return

    const indicator = this.saveIndicatorTarget
    indicator.classList.remove("opacity-0")
    indicator.classList.add("opacity-100")

    setTimeout(() => {
      indicator.classList.remove("opacity-100")
      indicator.classList.add("opacity-0")
    }, 1500)
  }
}
