import { Controller } from "@hotwired/stimulus"

// Adds and removes rungs in the admin price-ladder form
// (doc/billing_preisliste_rabatt_plan.md D10: the number of rungs must be data,
// not structure — a fixed set of slots would keep the flexibility in the schema
// and out of reach of the operator).
//
// No index bookkeeping on purpose: the fields use the array form
// price_list[tiers][][...], so a cloned row needs no renumbering and cannot
// collide with an existing one. That also sidesteps the nested-attributes trap
// where a non-integer child index is dropped silently by strong parameters.
export default class extends Controller {
  static targets = ["rows", "row", "template"]

  addRow(event) {
    const interval = event.currentTarget.dataset.interval
    const container = this.rowsTargets.find((rows) => rows.dataset.interval === interval)
    if (!container) return

    const markup = this.templateTarget.innerHTML.replaceAll("__INTERVAL__", interval)
    container.insertAdjacentHTML("beforeend", markup)
  }

  removeRow(event) {
    const row = event.currentTarget.closest("[data-price-ladder-target='row']")
    if (!row) return

    // Never remove the last remaining rung of an interval: an empty block is
    // indistinguishable from "this interval is not offered", and the actor
    // would reject the whole submission with a less specific message.
    const container = row.parentElement
    if (container.querySelectorAll("[data-price-ladder-target='row']").length <= 1) return

    row.remove()
  }
}
