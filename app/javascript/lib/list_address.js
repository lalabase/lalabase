// What: the address of a list page without a lane ("Alle Meetings") after its
//   list frame loaded: the page's path with the list state the server rendered
//   (data-list-filter-query, Meetings::ListState).
// Why:  a column head, a page link and the "+" modal reload only the frame.
//   The filter bar reads sort and the open view from window.location, so an
//   address left behind loses the sort on the next filter and the page on a
//   reload. The project page does the same in layout_toggle#syncUrlFromFrame,
//   which also keeps the lane's own parameters; this page has no lane.
//
// Null when the frame rendered no state (an error page): the address stays.
export function listAddress(path, renderedQuery) {
  if (!path || renderedQuery === undefined || renderedQuery === null) return null

  const query = new URLSearchParams(renderedQuery)
  if (query.get('page') === '1') query.delete('page')
  const search = query.toString()

  return search ? `${path}?${search}` : path
}
