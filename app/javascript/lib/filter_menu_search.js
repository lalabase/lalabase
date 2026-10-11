// What: the one decision filter_menu_search_controller.js makes per option, as
//   a pure function so node:test can pin it. The controller around it is a
//   loop, a counter and two DOM writes.
// Why:  the field narrows the options ALREADY RENDERED in a filter pill's menu
//   (time_sessions/_filter_pill). Its rule has two halves that are easy to get
//   backwards and impossible to see in a request spec, because nothing about
//   them reaches the server: an EMPTY term matches everything rather than
//   nothing, and the match runs over the option's WHOLE text, which includes
//   the project name printed beside a subject -- the case S6 exists for is two
//   meetings of the same title in different projects, and typing the project is
//   the only way to tell them apart.

// Normalised once by the caller, per keystroke, rather than per option.
export function searchTerm(raw) {
  return (raw || "").trim().toLowerCase()
}

// An empty term matches every option: the field is an enhancement over a menu
// that lists everything, so "nothing typed" must never hide anything.
export function optionMatches(text, term) {
  if (term === "") return true

  return (text || "").toLowerCase().includes(term)
}

// Whether the "nothing found" line is shown. Deliberately asked of the number
// of VISIBLE options, not of the term: the blank option ("Alle Bezüge") is an
// option too and matches an empty term, so an empty menu can only ever be the
// result of a term that really excludes everything.
export function showsEmptyNotice(visibleCount) {
  return visibleCount === 0
}
