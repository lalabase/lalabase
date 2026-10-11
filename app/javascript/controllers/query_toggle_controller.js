import { Controller } from "@hotwired/stimulus"
import { choiceQuery, nextQuery, ownedFrom } from "query_toggle"

// Points a filter pill at the address the browser is ACTUALLY on, not at the one
// the page was rendered with. See lib/query_toggle.js for why that differs.
//
// The href stays a real address, so the link still works without JavaScript --
// it is simply the page-load version, which is what it was before this existed.
export default class extends Controller {
  rewrite(event) {
    const link = event.currentTarget
    const owned = ownedFrom(link)
    if (owned.length === 0) return

    const url = new URL(link.getAttribute("href"), window.location.origin)
    link.setAttribute("href", `${url.pathname}${nextQuery(window.location.search, owned)}`)
  }

  // The same idea for a control that has no href to rewrite: a select declares
  // what its choice brings with it, and the address is visited instead.
  //
  // The WHOLE page, not the list frame the form aims at: the period segments sit
  // outside that frame and are not re-rendered with it, so a frame answer would
  // leave "Diesen Monat" standing over a list showing every month (S4 of the
  // filter-line plan). stopPropagation keeps the form's auto-submit from firing
  // a second, narrower request at the same time -- the same reason
  // project_cascade_controller.js stops it.
  visit(event) {
    const owned = ownedFrom(event.currentTarget)
    const query = choiceQuery(window.location.search, owned, event.target.name, event.target.value)
    if (query === null) return

    event.stopPropagation()
    Turbo.visit(`${window.location.pathname}${query}`)
  }
}
