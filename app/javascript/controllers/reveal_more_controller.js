import { Controller } from "@hotwired/stimulus"

// One-way "more …" reveal.
//
// Click the trigger -> reveal every hidden [data-more-item] entry inside this
// controller's element and hide the trigger itself. Deliberately NOT reversible:
// the extra entries stay in place once shown, there is no re-collapsing.
//
// Single source of truth for the reveal behaviour. Consumers (grep
// `reveal-more`): the sidebar's project children (neo_sidebar_project_item_component,
// "mehr …") and the time list's status table, which folds the projects without
// hours behind "N Projekte ohne Zeiten anzeigen" (_billing_overview_panel).
export default class extends Controller {
  reveal(event) {
    event.preventDefault()
    event.stopPropagation()

    this.element
      .querySelectorAll("[data-more-item]")
      .forEach((li) => li.classList.remove("hidden"))

    event.currentTarget.classList.add("hidden")
  }
}
