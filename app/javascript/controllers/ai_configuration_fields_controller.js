import { Controller } from "@hotwired/stimulus"

// Shows only the access fields the SELECTED provider actually uses
// (doc/ki_bereich_navigation_plan.md, gap L7).
//
// Which fields belong to which provider is not knowledge this file holds: every field
// wrapper declares its own providers in `data-providers`, rendered server-side from the
// same table Actors::SaveAiConfiguration validates against. A second list here would be
// the classic pair that rots apart — and it would rot silently, because the server would
// keep accepting what the form stopped showing.
//
// Two mechanisms, both load-bearing:
//   * `hidden` on the wrapper — what the admin sees.
//   * `disabled` on the input — what gets SUBMITTED. Without it a hidden field still
//     posts, so switching to a provider that has no endpoint would keep re-submitting
//     the old one, and the two ai_access_token inputs (single-line key vs. multi-line
//     service-account JSON) would post twice under one name.
//
// The initial state is rendered by the server, not by this controller; connect() only
// re-syncs, so the page is correct before any JavaScript runs and stays correct after a
// 422 re-render. Same shape and the same reasoning as
// admin_ai_credential_token_field_controller, which does this for two fixed fields on
// the operator side. Two occurrences of one idea, deliberately not merged yet: that one
// is bound to `ai_credential_*` field ids and to google-or-not. If a third appears, the
// data-driven half below is the one to keep.
export default class extends Controller {
  static targets = ["provider", "group"]

  connect() {
    this.sync()
  }

  sync() {
    const provider = this.providerTarget.value

    this.groupTargets.forEach((group) => {
      const applies = group.dataset.providers.split(" ").includes(provider)
      group.hidden = !applies
      group.querySelectorAll("input, textarea, select").forEach((input) => {
        input.disabled = !applies
      })
    })
  }
}
