// What: rebuild a filter link's address from the one currently in the browser.
// Why:  the pills above the time list are rendered ONCE, with the page. The
//   filters below them update a Turbo frame, which never re-renders the pills,
//   so every pill kept the query the page was opened with. Coming from a
//   ticket, setting the ticket filter back to "all" and then clicking any pill
//   put the ticket filter back -- the pill was still pointing at the address
//   from before.
//
//   The server keeps all the meaning: each link says which parameters it OWNS
//   and what they become (an empty value removes one). Everything else is taken
//   from the live address, so a pill can no longer undo a filter it knows
//   nothing about.

// owned: [["expand_all", "1"], ["page", ""]] -- "" removes the parameter.
//
// Ruby twin: #address_for_choosing in
// spec/requests/organisations/time_sessions_billing_choice_spec.rb follows the
// same steps so a request spec can walk the address a choice leads to. A change
// here is a change there.
export function nextQuery(search, owned) {
  const params = new URLSearchParams(search || "")

  for (const [key] of owned) {
    // Rails writes an array as `status_filters[]`; a link may name it either way,
    // so both spellings go before the new value is written.
    const bare = key.endsWith("[]") ? key.slice(0, -2) : key
    params.delete(bare)
    params.delete(`${bare}[]`)
  }
  for (const [key, value] of owned) {
    if (value !== "" && value !== null && value !== undefined) params.append(key, value)
  }
  // A changed filter always starts again at the first page.
  params.delete("page")

  const query = params.toString()
  return query ? `?${query}` : ""
}

// Where a filter CONTROL leads once a value is chosen. A select cannot carry an
// href, so instead of rewriting one it builds the address to visit: what the
// control owns (the widening a choice brings with it), then the control's own
// name and the chosen value.
//
// null means "there is nothing to navigate to": the blank option narrows
// nothing, so it widens nothing either, and the form's ordinary submit may
// answer it inside the frame. Returning a query there would turn "alle
// Abrechnungen" into a full page load that also opened the period and the
// status, which is a filter change nobody asked for.
export function choiceQuery(search, owned, name, value) {
  if (!name || !value) return null

  return nextQuery(search, [...owned, [name, value]])
}

// Reads the declaration off the element: data-query-toggle-owns is a JSON array
// of [key, value] pairs, so a link can own several parameters at once and an
// array parameter can be rewritten whole.
export function ownedFrom(element) {
  try {
    const raw = element?.dataset?.queryToggleOwns
    const parsed = raw ? JSON.parse(raw) : []
    return Array.isArray(parsed) ? parsed.filter((pair) => Array.isArray(pair) && pair.length === 2) : []
  } catch {
    return []
  }
}
