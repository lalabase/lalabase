// What the inbox above the organisations does with a live signal
// (all_inboxes_live_controller). Pure, so the rule is tested without a browser.
//
// Three stamps (Notifications::InboxQuery.stamp, opaque):
//   signal:  the latest one the stream sent
//   drawn:   the one the list on the screen was drawn with
//   counted: the one the counts were last fetched for
// Equal signal and drawn: the list is current (the echo of the reader's own
// action, or a redraw that already caught up). Otherwise the list is behind:
// while the tab is hidden nothing happens until it is shown again, then the list
// is redrawn; while it is visible the counts follow at once and the banner
// offers the list, which never moves under the reader by itself.

export function liveStep({ signal, drawn, counted, hidden }) {
  if (!signal || signal === drawn) return { banner: false, fetch: null }
  if (hidden) return { banner: false, fetch: null }

  return { banner: true, fetch: signal === counted ? null : "counts" }
}

// A tab that comes back into view with a list behind the signal redraws it.
export function returnStep({ signal, drawn }) {
  return signal && signal !== drawn ? "list" : null
}

// The address of a redraw: the page's own address (filters, organisation, search,
// period), the pages the endless scroll has loaded, and the part.
export function redrawAddress(pageAddress, { path, firstPage, throughPage, part }) {
  const address = new URL(pageAddress)
  address.pathname = path
  address.searchParams.delete("part")
  address.searchParams.delete("through_page")
  address.searchParams.set("page", String(firstPage || 1))
  if (throughPage) address.searchParams.set("through_page", String(throughPage))
  if (part === "counts") address.searchParams.set("part", "counts")
  return address.toString()
}
