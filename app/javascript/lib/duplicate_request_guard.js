// Which Turbo requests the duplicate guard of application.js may hold back, and under which key.
//
// A duplicate is the same write sent twice inside DUPLICATE_WINDOW_MS: the same method, the same
// target frame and the same address, on the lists that save from a form (tickets, notes,
// documents, times).
//
// A GET is never held back. Turbo cancels the request that a new one replaces: a frame whose
// address is set again, a second visit of a page. Held back, the new one was the only request
// left, and Turbo waited for a resume() that nobody calls. A double click on the "+" that opens
// the ticket form opened nothing, and a double click on a link left the page where it was
// (lalabase/lalabase#262).
export const DUPLICATE_WINDOW_MS = 500

const GUARDED_PATHS = ["/notes", "/tickets", "/documents", "/time_sessions"]

// The key under which the guard remembers a request, or null for one it lets through.
export function duplicateRequestKey(url, method, targetFrame) {
  const verb = String(method || "GET").toUpperCase()
  if (verb === "GET" || !url) return null
  if (!GUARDED_PATHS.some((path) => url.includes(path))) return null

  return `${verb} ${targetFrame || ""} ${url}`
}
