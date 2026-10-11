import { Controller } from "@hotwired/stimulus"

// Prefills the admin "new AI credential" form from a curated EU chat preset
// (AiCredential::EU_CHAT_PRESETS, serialized into presetsValue by the view).
// Presets ride the existing openai_compatible rail; every field stays editable
// afterwards — a preset is a starting aid, not a lock-in.

// All presets configure the one provider that serves custom endpoints.
const PRESET_PROVIDER = "openai_compatible"

// The preset's OWN keys are the field list — deliberately not a second, hand
// maintained array beside EU_CHAT_PRESETS. That array existed and it rotted at
// the first opportunity: E12 added `company_domicile` to all three presets and
// to the form, and the list was not extended, so picking a preset silently left
// the domicile blank — which made eu_company? false and hid the resulting
// package from the very EU filter the preset exists to satisfy. Two places
// listing the same facts is the defect; one place is the fix.
//
// Field ids follow the Rails convention ai_credential_<attribute>
// (Admin::AiCredential.model_name is pinned to 'AiCredential'). A preset key
// with no matching input is a no-op — #fill guards it — so a key that is not a
// form field costs nothing.

export default class extends Controller {
  static values = { presets: Object }

  apply(event) {
    const preset = this.presetsValue[event.target.value]
    if (!preset) return

    this.fill("provider", PRESET_PROVIDER)
    Object.keys(preset).forEach((field) => this.fill(field, preset[field]))
  }

  fill(field, value) {
    if (value == null) return
    const input = this.element.querySelector(`#ai_credential_${field}`)
    if (!input) return
    input.value = value
    // Programmatic value writes fire no change event — dispatch one so other
    // controllers on the form (token-field toggle) can react to the provider.
    input.dispatchEvent(new Event("change", { bubbles: true }))
  }
}
