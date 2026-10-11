import { Controller } from "@hotwired/stimulus"
import { searchTerm, optionMatches, showsEmptyNotice } from "filter_menu_search"

// ⚠️ A CLASS, not the `hidden` property.
//
// Every option is a flex row, and Tailwind's preflight writes the hidden
// attribute as `[hidden]:where(:not([hidden=until-found]))` -- :where() adds no
// specificity, so that rule and `.flex` are both (0,1,0) and the later one
// wins. Setting el.hidden therefore marked the options hidden and left them on
// screen at full height. The field looked dead and was reported as such.
//
// The utility class beats it because Tailwind emits `.hidden` after `.flex`.
// Same fix and same reason as access_matrix_filter_controller, and the same
// trap the stylesheets already record three times (landing.css, layout.css,
// components/rich_text_embeds.css).
const HIDDEN_CLASS = "hidden"


// Narrows the options ALREADY RENDERED in a filter pill's menu by typed text
// (time_sessions/_filter_pill).
//
// Progressive enhancement, deliberately: the options are server-rendered links
// and the menu is a <details>, so without JavaScript the pill still opens and
// still lists every option — which is what it did before this field existed.
// This only hides the ones that do not match, so nothing here may be the only
// way to reach a value.
//
// Why it exists at all: since S6 the subject filter reaches across ALL projects
// (D4), so its menu is as long as the number of tickets and meetings that have
// booked time. The billing menu grows the same way over a year.
//
// Matches against the option's whole text, which includes the subtitle, so
// typing a project name finds the meetings inside it — the case S6 exists for
// is two meetings of the same title in different projects.
export default class extends Controller {
  static targets = ["query", "option", "empty"]

  filter() {
    // Mounted on every pill menu so the wiring census can see the mount as a
    // literal; only the long ones (subject, billing) carry the field. Without it
    // there is nothing to filter by and nothing to hide.
    if (!this.hasQueryTarget) return

    // The rule itself lives in lib/filter_menu_search.js so node:test can pin
    // it: none of it reaches the server, so a request spec cannot see it, and
    // an inverted empty-term check would hide the whole menu of an untouched
    // field. Normalised ONCE here, not per option.
    const term = searchTerm(this.queryTarget.value)
    let visible = 0

    this.optionTargets.forEach((option) => {
      const match = optionMatches(this.haystackFor(option), term)
      option.classList.toggle(HIDDEN_CLASS, !match)
      if (match) visible += 1
    })

    if (this.hasEmptyTarget) this.emptyTarget.classList.toggle(HIDDEN_CLASS, !showsEmptyNotice(visible))
  }

  // textContent is recomputed and re-allocated on every read, so it is cached on
  // the element the first time. The options are server-rendered and never change
  // between renders; a fresh render brings fresh elements and an empty cache.
  haystackFor(option) {
    if (option.dataset.searchHaystack === undefined) {
      option.dataset.searchHaystack = option.textContent
    }

    return option.dataset.searchHaystack
  }
}
