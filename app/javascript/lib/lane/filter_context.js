// Which controls of a list page with a lane take the list state when the list
// changes beside an open lane (layout_toggle#syncFilterContext). Pure, so the
// rule can be said without a browser (spec/javascript/lib/lane).
//
// A control belongs to an index when its path is the index or lies below it:
// the page's own index (data-index-url on the wrapper) and, on a page whose
// lane is another list's detail, the index the lane names on its head
// (data-lane-index-url). "Alle Meetings" shows a project's meeting in its
// lane: its edit, delete and search switch live below that project's meetings
// index, not below the overview's, and without the second index they kept the
// state the list had when the lane was opened (doc/meetings_uebersicht_vereinheitlichen_plan.md,
// PR 3). Any other control (a ticket a meeting links to) is left alone: the
// list state of one list means nothing to another one.

// The index pathname a control belongs to, or null. The first match wins; a
// control's path ending in .turbo_stream counts as the path without it.
export function controlIndexPath(path, indexPaths) {
  const plain = path.replace(/\.turbo_stream$/, "")
  for (const index of indexPaths) {
    if (index && (plain === index || plain.startsWith(`${index}/`))) return index
  }
  return null
}

// The index pathnames of a page: its own, then each one a lane head names,
// without repeats (on the project page both are the same).
export function indexPaths(pageIndexUrl, laneIndexUrls, origin) {
  const paths = [pageIndexUrl, ...laneIndexUrls].filter(Boolean).map((url) => new URL(url, origin).pathname)
  return [...new Set(paths)]
}

// A list link that keeps the lane (data-lane-keep, the sort heads of the
// people list) was rendered with the selection of the page request. A row
// click changes the open object in the address only, so at click time the
// link takes the lane part of the live address instead: the object open now,
// or none once the lane was closed. Returns a new URL.
export function withLiveLane(address, current, laneNames) {
  const result = new URL(address.toString())
  for (const name of laneNames) {
    result.searchParams.delete(name)
    for (const value of current.searchParams.getAll(name)) result.searchParams.append(name, value)
  }
  return result
}
