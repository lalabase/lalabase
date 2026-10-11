// The addresses of a list page with a lane (doc/wissen_als_bahn_plan.md, S2).
// Pure functions over URLs, so list_row_controller stays a thin mount and the
// rules can be tested without a browser (spec/javascript/lib/list_row).
//
// Three addresses, and they are three different things:
//   the PAGE address    the index with the live query and ONE selection
//                       parameter (/knowledge?type=all&search=x&note_id=A);
//                       what the address bar shows, what a reload renders;
//   the DETAIL address  the resource the lane's frame fetches
//                       (/notes/A?frame=content&frame_id=…), never the page;
//   the WAY BACK        the page address without any selection.
//
// A page may know several selection parameters (knowledge: note_id and
// document_id). They EXCLUDE each other: note A, then document B, must leave
// ?document_id=B alone. With both in the address the server takes the first
// registry hit (KnowledgeController#set_selected_item), so the lane would show
// B and a reload A. The `params` of these functions are the names a step
// CLEARS: the selection and, since doc/dateivorschau_plan.md (D9), the preview
// of the open object, which goes wherever the selection goes; the page's
// groups come from lib/lane/params.

const NEVER_TRAVEL = ["format", "frame", "frame_id"]

// Narrower than this the lane would cover the list: the page instead, whose
// head carries the way back as a word. ONE number for the row opener and the
// lane link (doc/dateivorschau_plan.md, D2).
export const FULL_PAGE_BELOW_PX = 1024

// The selection the address names: { param, id } or null.
export function openSelection(search, params) {
  const query = toParams(search)
  for (const param of params) {
    const id = query.get(param)
    if (id) return { param, id }
  }
  return null
}

export function isOpen(search, param, id) {
  const open = openSelection(search, [param])
  return Boolean(open && open.id === id)
}

// The page address for `id`: the index (or the current path when the page
// names no index), the live query, every other selection parameter gone,
// this one set.
export function canonicalAddress({ current, indexUrl, param, params, id }) {
  const address = new URL(indexUrl || current.pathname, current.origin)
  address.search = current.search
  for (const other of params) address.searchParams.delete(other)
  address.searchParams.set(param, id)
  return address
}

// The page address with no selection at all (the way back on a narrow page).
export function withoutSelection(url, params) {
  const address = new URL(url.toString(), url.origin)
  for (const param of params) address.searchParams.delete(param)
  return address
}

// What the frame fetches: the resource, frame=content, the lane's frame id,
// and the page's live query minus the selection and the frame plumbing.
// Built with the URL API: a resource path that already carries a query must
// not get a second "?". A repeated parameter (filter[tag][]=a&filter[tag][]=b)
// travels whole: every value is appended, not the last one set (the review of
// doc/dateivorschau_plan.md reproduced the loss).
export function detailAddress({ url, current, frame, params }) {
  const address = new URL(url, current.origin)
  address.searchParams.set("frame", "content")
  if (frame) address.searchParams.set("frame_id", frame)
  for (const key of new Set(current.searchParams.keys())) {
    if (params.includes(key) || NEVER_TRAVEL.includes(key)) continue
    address.searchParams.delete(key)
    for (const value of current.searchParams.getAll(key)) address.searchParams.append(key, value)
  }
  return address.toString()
}

function toParams(search) {
  return search instanceof URLSearchParams ? search : new URLSearchParams(search)
}
