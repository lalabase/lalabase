// What: the two decisions meeting_modal_controller.js makes, as pure functions
//   so node:test can pin them (spec/system does not run in CI, this path does).
// Why:  both were review findings on PR #716, and neither is visible from the
//   server side.
//
//   1. newFormUrl merges the LIVE filter values into the option's URL. The
//      modal sits in the title box, OUTSIDE the meetings_overview_results
//      frame, and the filter row is a frame-scoped GET with no
//      data-turbo-action="advance". So the page never re-renders and the
//      filter values ERB baked into every data-new-url are the ones from the
//      first page load. Without this merge the list after a save shows
//      something other than what the filter controls say.
//   2. submissionClosesModal decides whether a finished submit really saved.
//      Turbo's detail.success is response.ok AFTER fetch followed redirects,
//      so the area gate's redirect_to reads as a success. A modal that closes
//      on that throws away a pasted transcript and shows no reason.

// The page's own filter field names, mapped to the names the nested meetings
// route expects. project_id is the nested route's OWN parameter, so the
// overview's project filter has to travel under a different name -- this map is
// the only place that rename is written down on the client.
export const FILTER_PARAMS = Object.freeze({
  search: 'search',
  participant: 'participant',
  projectId: 'overview_project_id'
})

// Base URL comes from ERB (each <option data-new-url>), so no route is
// assembled here; only values are set or removed. A blank value REMOVES its
// parameter, so clearing a filter and saving does not resurrect it.
export function newFormUrl(baseUrl, filters = {}) {
  if (!baseUrl) return null

  // A dummy origin lets URL parse a path-only value; we return path + search,
  // so the result stays relative and the origin never leaks into the DOM.
  const url = new URL(baseUrl, 'http://meeting-modal.invalid')

  for (const [key, param] of Object.entries(FILTER_PARAMS)) {
    const value = filters[key]
    if (value === undefined || value === null || String(value).trim() === '') {
      url.searchParams.delete(param)
    } else {
      url.searchParams.set(param, String(value))
    }
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
