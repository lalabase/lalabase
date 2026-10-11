import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

// Controls the multi-step token creation form:
//   - Toggles the custom expiry datepicker
//   - Switches between "selected organisations" and "all organisations, including future ones"
//   - Shows/hides the project selection per org
//   - Switches between "all projects" and "selected projects"
//   - Updates the live summary
export default class extends Controller {
  static targets = [
    "expiryPresetSelect",
    "customExpiryWrapper",
    "customExpiryInput",
    "organisationMode",
    "organisationList",
    "orgBlock",
    "orgCheckbox",
    "projectScopeWrapper",
    "projectList",
    "summaryList",
    "summaryPlaceholder",
    "summaryExpiry",
  ]

  static values = {
    organisations: Array, // [{ id, name }, ...]
  }

  connect() {
    this.updateSummary()
  }

  // -------- Expiry --------

  toggleCustomExpiry() {
    const isCustom = this.expiryPresetSelectTarget.value === "custom"
    this.customExpiryWrapperTarget.classList.toggle("hidden", !isCustom)
    if (!isCustom) {
      this.customExpiryInputTarget.value = ""
    }
    this.updateSummary()
  }

  // -------- All organisations or selected ones --------

  // "all" hides the per-organisation choice. The ticked boxes stay as they are, so
  // switching back restores them; the server ignores them while "all" is chosen.
  toggleOrganisationMode() {
    this.organisationListTarget.classList.toggle("hidden", this.allOrganisations())
    this.updateSummary()
  }

  allOrganisations() {
    return this.organisationModeTargets.some((radio) => radio.checked && radio.value === "all")
  }

  // -------- Org/Project blocks --------

  toggleOrg(event) {
    const checkbox = event.currentTarget
    const block = checkbox.closest("[data-neo-personal-access-token-form-target='orgBlock']")
    const wrapper = block.querySelector("[data-neo-personal-access-token-form-target='projectScopeWrapper']")
    wrapper.classList.toggle("hidden", !checkbox.checked)

    if (!checkbox.checked) {
      // Reset radio + checkboxes when an org is unchecked.
      const radios = wrapper.querySelectorAll("input[type='radio']")
      radios.forEach((r) => { r.checked = r.value === "all" })
      const projectList = wrapper.querySelector("[data-neo-personal-access-token-form-target='projectList']")
      projectList.classList.add("hidden")
      projectList.querySelectorAll("input[type='checkbox']").forEach((c) => { c.checked = false })
    }
    this.updateSummary()
  }

  toggleProjectMode(event) {
    const radio = event.currentTarget
    const wrapper = radio.closest("[data-neo-personal-access-token-form-target='projectScopeWrapper']")
    const projectList = wrapper.querySelector("[data-neo-personal-access-token-form-target='projectList']")
    projectList.classList.toggle("hidden", radio.value !== "selected")
    this.updateSummary()
  }

  // -------- Summary --------

  // The name from the organisations value the view passes. Called since the form was
  // built, defined only on 2026-10-02: until then ticking an organisation threw and the
  // summary stayed on its placeholder.
  organisationName(orgId) {
    return this.organisationsValue.find((organisation) => organisation.id === orgId)?.name || ""
  }

  // One summary line per ticked organisation, with its project choice.
  selectedOrganisationItems() {
    const items = []

    this.orgBlockTargets.forEach((block) => {
      const checkbox = block.querySelector("[data-neo-personal-access-token-form-target='orgCheckbox']")
      if (!checkbox.checked) return

      const orgId = block.dataset.orgId
      const orgName = this.organisationName(orgId)
      const wrapper = block.querySelector("[data-neo-personal-access-token-form-target='projectScopeWrapper']")
      const selectedMode = wrapper.querySelector("input[type='radio']:checked")?.value || "all"

      if (selectedMode === "all") {
        items.push(I18n.t('stimulus.personal_access_token.all_projects', { org: orgName }))
      } else {
        const selected = wrapper.querySelectorAll("input[type='checkbox']:checked")
        const count = selected.length
        if (count === 0) {
          items.push(I18n.t('stimulus.personal_access_token.no_projects', { org: orgName }))
        } else {
          const names = Array.from(selected).map((c) => c.parentElement.textContent.trim())
          items.push(I18n.t('stimulus.personal_access_token.projects_count', { org: orgName, count: count, names: names.join(", ") }))
        }
      }
    })

    return items
  }

  updateSummary() {
    const items = (this.hasOrganisationModeTarget && this.allOrganisations())
      ? [I18n.t('stimulus.personal_access_token.all_organisations')]
      : this.selectedOrganisationItems()

    // Render summary list
    this.summaryListTarget.innerHTML = ""
    if (items.length === 0) {
      const li = document.createElement("li")
      li.className = "text-gray-500 italic"
      li.textContent = this.summaryPlaceholderTarget.textContent
      this.summaryListTarget.appendChild(li)
    } else {
      items.forEach((text) => {
        const li = document.createElement("li")
        li.textContent = text
        this.summaryListTarget.appendChild(li)
      })
    }

    this.updateSummaryExpiry()
  }

  updateSummaryExpiry() {
    const preset = this.expiryPresetSelectTarget.value
    const target = this.summaryExpiryTarget
    const template = target.dataset.template
    if (!template) {
      // Cache the template once so we can re-render with new dates.
      target.dataset.template = target.textContent
    }

    let validUntil
    if (preset === "custom" && this.customExpiryInputTarget.value) {
      validUntil = new Date(this.customExpiryInputTarget.value)
    } else {
      const days = parseInt(preset, 10) || 30
      validUntil = new Date()
      validUntil.setDate(validUntil.getDate() + days)
    }

    const formatted = validUntil.toLocaleDateString(
      document.documentElement.lang || "de-DE",
      { year: "numeric", month: "2-digit", day: "2-digit" }
    )

    // Replace the date in the cached template; if pattern not found, leave it.
    const cached = target.dataset.template
    target.textContent = cached.replace(/\d{2}[./]\d{2}[./]\d{2,4}/, formatted)
  }
}
