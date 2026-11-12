import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

// The date and time section of the preferences page (user_preferences/edit): which rows
// show (a custom format, one format for all areas, a custom format per area) and whether
// a typed format is one we can read.
//
// The section saves on every change (preferences_autosave_controller, mounted on the
// section around this one). Two things here are for it: a format this controller refuses
// is marked invalid on the field (setCustomValidity), so the form is not sent with it,
// and a row that is hidden loses its mark, because a hidden invalid field would block
// every later save without anybody seeing why. "Back to the defaults" sets the fields
// and reports a change, which saves like any other.
export default class extends Controller {
  static targets = ["globalFormat", "customFormatRow", "useGlobalCheckbox", "areaSettings", "areaFormatSelect"]

  connect() {
    this.toggleCustomFormat()
    this.checkGlobalUsage()
    this.initializeAreaCustomFormats()
  }

  toggleCustomFormat() {
    if (!this.hasGlobalFormatTarget) return

    const globalFormat = this.globalFormatTarget.value
    if (this.hasCustomFormatRowTarget) {
      this.#toggleFormatRow(this.customFormatRowTarget, globalFormat === 'custom')
    }
  }

  toggleAreaSettings() {
    if (!this.hasUseGlobalCheckboxTarget || !this.hasAreaSettingsTarget) return

    const useGlobal = this.useGlobalCheckboxTarget.checked
    const areaSelects = this.areaSettingsTarget.querySelectorAll('select')
    // One format for all: the per-area rows say nothing then, and five disabled
    // fields only make the page longer. Without JavaScript they all stay visible.
    this.areaSettingsTarget.hidden = useGlobal

    if (useGlobal) {
      areaSelects.forEach(select => {
        select.value = 'inherit'
        select.disabled = true
        select.classList.add('opacity-50')
      })
      this.#hideAreaFormatRows()
    } else {
      areaSelects.forEach(select => {
        select.disabled = false
        select.classList.remove('opacity-50')
      })
    }
  }

  checkGlobalUsage() {
    if (!this.hasAreaSettingsTarget || !this.hasUseGlobalCheckboxTarget) return

    const areaSelects = this.areaSettingsTarget.querySelectorAll('select')
    const allInherit = Array.from(areaSelects).every(select => select.value === 'inherit')

    this.useGlobalCheckboxTarget.checked = allInherit
    this.areaSettingsTarget.hidden = allInherit

    if (allInherit) {
      areaSelects.forEach(select => {
        select.disabled = true
        select.classList.add('opacity-50')
      })
    }
  }

  resetDefaults() {
    if (I18n.confirm('stimulus.user_preferences.confirm_reset_defaults')) {
      // Reset global format
      if (this.hasGlobalFormatTarget) {
        this.globalFormatTarget.value = 'relative'
      }

      // Reset custom format
      const customFormat = document.querySelector('[name="preferences[date_display][custom_format]"]')
      if (customFormat) customFormat.value = '%d.%m.%Y %H:%M'

      // Reset all areas to inherit
      if (this.hasAreaSettingsTarget) {
        const areaSelects = this.areaSettingsTarget.querySelectorAll('select')
        areaSelects.forEach(select => {
          select.value = 'inherit'
          select.disabled = true
          select.classList.add('opacity-50')
        })
        this.areaSettingsTarget.hidden = true
      }

      this.#hideAreaFormatRows()

      // Check the global usage checkbox
      if (this.hasUseGlobalCheckboxTarget) {
        this.useGlobalCheckboxTarget.checked = true
      }

      // Update UI
      this.toggleCustomFormat()

      // The fields were set by a script, which fires no event: report the change, so
      // the section saves (preferences_autosave_controller listens on the form).
      if (this.hasGlobalFormatTarget) {
        this.globalFormatTarget.dispatchEvent(new Event('change', { bubbles: true }))
      }
    }
  }

  // Shows or hides a custom format row. Hidden, its field is valid again: nobody can
  // see or correct a hidden field, and it is not used while its format is not chosen.
  #toggleFormatRow(row, visible) {
    row.style.display = visible ? 'block' : 'none'
    if (!visible) row.querySelectorAll('input').forEach(input => this.clearFormatError(input))
  }

  #hideAreaFormatRows() {
    this.element.querySelectorAll('.area-custom-format-row').forEach(row => this.#toggleFormatRow(row, false))
  }

  toggleAreaCustomFormat(event) {
    const select = event.currentTarget
    const area = select.dataset.area
    const customFormatRow = document.querySelector(`.area-custom-format-row[data-area="${area}"]`)

    if (customFormatRow) {
      this.#toggleFormatRow(customFormatRow, select.value === 'custom')
    }
  }

  initializeAreaCustomFormats() {
    const areaSelects = document.querySelectorAll('.area-format-select')
    areaSelects.forEach(select => {
      if (select.value === 'custom') {
        const area = select.dataset.area
        const customFormatRow = document.querySelector(`.area-custom-format-row[data-area="${area}"]`)
        if (customFormatRow) {
          customFormatRow.style.display = 'block'
        }
      }
    })
  }

  validateCustomFormat(formatString) {
    const validCodes = ['%Y', '%y', '%m', '%d', '%H', '%M', '%S', '%B', '%b', '%A', '%a']
    const invalidChars = /[<>|\\:"*?]/

    if (invalidChars.test(formatString)) {
      return { valid: false, message: I18n.t('stimulus.user_preferences.format_invalid_chars') }
    }

    const hasValidCode = validCodes.some(code => formatString.includes(code))
    if (!hasValidCode && formatString.includes('%')) {
      return { valid: false, message: I18n.t('stimulus.user_preferences.unknown_format_codes') }
    }

    try {
      const testDate = new Date()
      const testResult = this.formatDate(testDate, formatString)
      if (testResult.includes('undefined') || testResult === formatString) {
        return { valid: false, message: I18n.t('stimulus.user_preferences.format_code_unsupported') }
      }
      return { valid: true, preview: testResult }
    } catch (e) {
      return { valid: false, message: I18n.t('stimulus.user_preferences.invalid_format') }
    }
  }

  formatDate(date, format) {
    const pad = (num) => num.toString().padStart(2, '0')

    const replacements = {
      '%Y': date.getFullYear(),
      '%y': date.getFullYear().toString().slice(-2),
      '%m': pad(date.getMonth() + 1),
      '%d': pad(date.getDate()),
      '%H': pad(date.getHours()),
      '%M': pad(date.getMinutes()),
      '%S': pad(date.getSeconds())
    }

    let result = format
    for (const [key, value] of Object.entries(replacements)) {
      result = result.replace(key, value)
    }

    return result
  }

  showFormatError(input, message) {
    const existingError = input.parentNode.querySelector('.format-error')
    if (existingError) existingError.remove()

    input.classList.add('border-red-500')
    input.classList.remove('border-black')
    input.setCustomValidity(message)

    const errorDiv = document.createElement('div')
    errorDiv.className = 'format-error text-xs text-red-600 mt-1'
    errorDiv.textContent = message
    input.parentNode.appendChild(errorDiv)
  }

  clearFormatError(input) {
    const existingError = input.parentNode.querySelector('.format-error')
    if (existingError) existingError.remove()

    input.classList.remove('border-red-500')
    input.classList.add('border-black')
    input.setCustomValidity('')
  }

  validateGlobalFormat(event) {
    const input = event.currentTarget
    const format = input.value.trim()

    if (!format) {
      this.clearFormatError(input)
      return
    }

    const validation = this.validateCustomFormat(format)
    if (validation.valid) {
      this.clearFormatError(input)
    } else {
      this.showFormatError(input, validation.message)
    }
  }

  validateAreaFormat(event) {
    const input = event.currentTarget
    const format = input.value.trim()

    if (!format) {
      this.clearFormatError(input)
      return
    }

    const validation = this.validateCustomFormat(format)
    if (validation.valid) {
      this.clearFormatError(input)
    } else {
      this.showFormatError(input, validation.message)
    }
  }
}
