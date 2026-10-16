// What: the two decisions meeting_modal_controller.js makes, as pure functions
//   so node:test can pin them (spec/system does not run in CI, this path does).
// Why:  both were review findings on PR #716, and neither is visible from the
//   server side.
//
//   1. newFormUrl adds the list's LIVE state to the option's URL. The modal sits
//      in the title box, OUTSIDE the meetings_overview_results frame, and the
//      filter bar reloads only that frame. So the page never re-renders, and a
//      state ERB baked into every data-new-url would be the one from the first
//      page load. The list frame writes its state into data-list-filter-query
//      at every load; without it, the list after a save would show something
//      other than what the bar says.
//   2. submissionClosesModal decides whether a finished submit really saved.
//      Turbo's detail.success is response.ok AFTER fetch followed redirects,
//      so the area gate's redirect_to reads as a success. A modal that closes
//      on that throws away a pasted transcript and shows no reason.

// Base URL comes from ERB (each <option data-new-url>), so no route is
// assembled here; the list query is added as it stands. The server wrote it
// from its own whitelist (Meetings::ListState), so it names nothing of the
// route. A name the base already carries (frame) is the base's: the list
// state never overrides it.
export function newFormUrl(baseUrl, listQuery = '') {
  if (!baseUrl) return null

  // A dummy origin lets URL parse a path-only value; we return path + search,
  // so the result stays relative and the origin never leaks into the DOM.
  const url = new URL(baseUrl, 'http://meeting-modal.invalid')
  const own = new Set(url.searchParams.keys())

  for (const [key, value] of new URLSearchParams(listQuery || '')) {
    if (own.has(key)) continue
    url.searchParams.append(key, value)
  }

  return `${url.pathname}${url.search}`
}

// Turbo exposes the response as fetchResponse.header(name); the raw Response is
// read as a fallback so a shape change does not silently turn every submit into
// a "success".
export function responseContentType(fetchResponse) {
  if (!fetchResponse) return ''
  if (typeof fetchResponse.header === 'function') return fetchResponse.header('Content-Type') || ''

  const headers = fetchResponse.response && fetchResponse.response.headers
  if (headers && typeof headers.get === 'function') return headers.get('Content-Type') || ''

  return ''
}

// Only a turbo-stream answer means the server actually ran the save and
// refreshed the list. A validation error is a 422 (success false, stays open),
// a denied write or an expired session is an HTML page after a redirect
// (success TRUE, but nothing was written -- must NOT close).
export function submissionClosesModal(detail) {
  if (!detail || detail.success !== true) return false

  return responseContentType(detail.fetchResponse).includes('turbo-stream')
}
