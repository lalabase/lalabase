// The page's lane parameters, ONE definition in three groups (D9 of
// doc/dateivorschau_plan.md):
//   selection  the parameters that name the open object (note_id, document_id;
//              ticket_id on the ticket page)
//   preview    the sub-state of the open object (preview: a version in the lane)
//   form       a form as a state of the page (new)
//   ignore     page-mode parameters that are neither list nor lane state and
//              come and go on their own (viewport, written by the viewport
//              controller after the page has rendered): the list part leaves
//              them out, or every entry after the page load would look like a
//              changed list to the restorer
// Rendered once on the page wrapper as data-lane-params (LaneHelper#lane_params_json)
// and read by every controller that touches the address. Each reader derives ITS
// rule from the groups; there is no one list for every purpose, because a preview
// is not a selection: openSelection must not take ?preview=V for an open object,
// and the pagination must keep it while a row click drops it.
export const EMPTY_LANE_PARAMS = Object.freeze({ selection: [], preview: [], form: [], ignore: [] })

export function parseLaneParams(json) {
  if (!json) return EMPTY_LANE_PARAMS
  let raw
  try {
    raw = JSON.parse(json)
  } catch {
    return EMPTY_LANE_PARAMS
  }
  return { selection: names(raw.selection), preview: names(raw.preview), form: names(raw.form), ignore: names(raw.ignore) }
}

// The groups of the page an element sits on, from the nearest wrapper that
// carries them; `fallback` for a page that has none yet (the inbox pane mounts
// list-row without one and names its selection on the row).
export function readLaneParams(element, fallback = EMPTY_LANE_PARAMS) {
  const host = element && typeof element.closest === "function" ? element.closest("[data-lane-params]") : null
  return host ? parseLaneParams(host.dataset.laneParams) : fallback
}

// The lane part of an address: the selection and its preview. What a row click
// and the ✕ clear, what never travels into a frame fetch, what the filter bar
// carries through a list reload.
export function laneParamNames(groups) {
  return [...groups.selection, ...groups.preview]
}

// The list part of an address, as a comparable string: everything but the lane
// part, every pair sorted by name and value, so two spellings of one query
// (filter[tag][]=a&…=b and b&…=a) compare equal. A form state belongs to the
// page, so it stays in the list part. What the page rendered its list for;
// Back compares against it (lib/lane/history).
export function listPart(search, groups) {
  const lane = new Set([...laneParamNames(groups), ...(groups.ignore || [])])
  const pairs = [...new URLSearchParams(search).entries()].filter(([name]) => !lane.has(name))
  pairs.sort(([a, x], [b, y]) => (a < b ? -1 : a > b ? 1 : x < y ? -1 : x > y ? 1 : 0))
  return new URLSearchParams(pairs).toString()
}

// The lane part of an address, read: { selection: { param, id } | null, preview: { param, id } | null }.
export function lanePart(search, groups) {
  const query = new URLSearchParams(search)
  return { selection: first(query, groups.selection), preview: first(query, groups.preview) }
}

// A page address with a lane state set or removed (the preview opened, the way
// back to the document): the current address, `remove` deleted, `set` written.
// A destination with the lane part of the CURRENT address: a page turn, a
// change of the items per page keep the open object and its preview, read at
// navigation time, so an object or a preview opened after the links were
// rendered travels along (the rendered hrefs stay the server's plain fallback).
export function withLanePartOf(url, { current, groups }) {
  const address = new URL(url, current.origin)
  for (const name of laneParamNames(groups)) {
    address.searchParams.delete(name)
    for (const value of current.searchParams.getAll(name)) address.searchParams.append(name, value)
  }
  return address.toString()
}

export function withLaneState(current, { set = {}, remove = [] } = {}) {
  const address = new URL(current.toString(), current.origin)
  for (const name of remove) address.searchParams.delete(name)
  for (const [name, value] of Object.entries(set)) address.searchParams.set(name, value)
  return address
}

function first(query, params) {
  for (const param of params) {
    const id = query.get(param)
    if (id) return { param, id }
  }
  return null
}

function names(value) {
  return Array.isArray(value) ? value.map(String) : []
}
