// What Back and Forward restore (D2 of doc/dateivorschau_plan.md). Pure, so the
// sequences can be said without a browser (spec/javascript/lib/lane).
//
// Three writers push entries: Turbo (the page load, page visits; its entries
// carry state.turbo), the filter bar, and the lane (the row opener, the ✕, a
// lane link). The restorer handles EVERY popped entry on a lane page, Turbo's
// included: the knowledge page says turbo-visit-control reload and caches no
// snapshot, so Turbo's own restoration of its entry is a full reload or, as
// seen in the browser, nothing at all; a reload replaces the document and
// wins, and nothing at all left the address saying "preview" over a lane
// that showed the document.
//
// The restorer compares the popped address with what the page shows: the LIST
// part it rendered its list for (the wrapper's data-list-query, written on
// connect and by every list reload) and the LANE part. A moved list part means
// the whole page (list, filter bar and lane from the server, replacing the
// entry, pushing nothing); a moved lane part alone means the frame, or the
// closed lane when there is no selection.
import { listPart, lanePart } from "lane/params"

// An entry of ANOTHER page (its path is not the one this page shows) is no state of this
// page, however alike the query parts: Turbo restores its own entries of other pages itself,
// and a second visit here would cancel Turbo's and fall to the duplicate-request guard of
// application.js (the address said A, the page stayed B: a link from project A's lane into
// project B, then Back). A lane entry of another page (no Turbo state) is visited as a page.
//
// { kind: "turbo" } | { kind: "page" } | { kind: "close" } | { kind: "frame", selection, preview }
export function restoration({ shownPath, shownListQuery, address, groups, turboEntry = false }) {
  if (shownPath && address.pathname !== shownPath) return turboEntry ? { kind: "turbo" } : { kind: "page" }
  if (listPart(address.search, groups) !== (shownListQuery || "")) return { kind: "page" }
  const lane = lanePart(address.search, groups)
  if (!lane.selection) return { kind: "close" }
  return { kind: "frame", selection: lane.selection, preview: lane.preview }
}

// The frame address of a preview state. The page wrapper carries the preview
// route ONCE with a placeholder for each id (data-lane-preview-url, written by
// LaneHelper with the same two words), so the restorer needs neither the
// document view loaded (its file name links exist only there) nor a route
// shape of its own. Null without a road: the restorer then visits the page.
export const SELECTION_PLACEHOLDER = "__SELECTION__"
export const PREVIEW_PLACEHOLDER = "__PREVIEW__"

export function previewAddress(template, { selection, preview }) {
  if (!template || !selection || !preview) return null
  return template
    .replaceAll(SELECTION_PLACEHOLDER, encodeURIComponent(selection.id))
    .replaceAll(PREVIEW_PLACEHOLDER, encodeURIComponent(preview.id))
}
