// The address and the timing of a reload of a list frame (Turbo.StreamActions.reloadFrame).
//
// The page's address carries the filters and the open ticket. Sort and page live only in the
// frame's own src: a click on a column head or on page 2 navigates the frame, not the page.
// Reloading from the address alone would throw them away, so they come from the frame.

// More than the duplicate guard in application.js blocks (500 ms): the same GET again inside
// that window is dropped unseen, and the row of the later write would never reach the list.
export const RELOAD_GAP_MS = 600

const frameOwned = (name) => name === "page" || name.startsWith("sort")

export function listFrameAddress(liveAddress, frameSource) {
  if (!frameSource) return liveAddress

  const address = new URL(liveAddress)
  const frame = new URL(frameSource, liveAddress)

  Array.from(address.searchParams.keys()).filter(frameOwned)
    .forEach((name) => address.searchParams.delete(name))
  frame.searchParams.forEach((value, name) => {
    if (frameOwned(name)) address.searchParams.append(name, value)
  })

  return address.toString()
}

export function reloadWait(lastReloadAt, now) {
  if (lastReloadAt === undefined) return 0

  return Math.max(0, lastReloadAt + RELOAD_GAP_MS - now)
}
