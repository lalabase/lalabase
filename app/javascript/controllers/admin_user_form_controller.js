import { Controller } from "@hotwired/stimulus"
import I18n from "i18n"

export default class extends Controller {
  static targets = ["newOrgFields", "existingOrgFields", "roleFrame", "orgSelect"]

  connect() {
    this.toggleMode()
  }

  toggleMode() {
    const mode = this.element.querySelector('input[name="organisation_mode"]:checked')?.value
    const isNew = mode !== "existing"

    this.newOrgFieldsTarget.classList.toggle("hidden", !isNew)
    this.existingOrgFieldsTarget.classList.toggle("hidden", isNew)

    // Disable hidden fields so they don't submit
    this.newOrgFieldsTarget.querySelectorAll("input, select").forEach(el => el.disabled = !isNew)
    this.existingOrgFieldsTarget.querySelectorAll("input, select").forEach(el => el.disabled = isNew)
  }

  loadRoles() {
    const orgId = this.orgSelectTarget.value
    if (orgId) {
      this.roleFrameTarget.src = `/admin/organisations/${orgId}/roles`
    } else {
      // Clear the frame content when no org is selected
      this.roleFrameTarget.innerHTML = `<turbo-frame id="role_select"><p class="text-sm text-gray-500 mt-2">${I18n.t('stimulus.admin_user_form.select_organisation_first')}</p></turbo-frame>`
    }
  }
}
