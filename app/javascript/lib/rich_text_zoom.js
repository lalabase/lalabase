// Which zoom link, if any, a click inside a rendered rich text belongs to
// (neo_rich_text_zoom_controller). Kept dependency-free for `node --test`: the controller
// hands in the clicked element and a root, this decides whether the click is a zoom.
//
// A zoom link is `a.attachment__zoom` rendered by active_storage/blobs/_blob.html.erb
// around the inline image. Clicks with a modifier key (new tab) and clicks outside a zoom
// link are left to the browser.
export function zoomLinkFor(target, root, modifiers = {}) {
  if (!target || typeof target.closest !== "function") return null
  if (modifiers.metaKey || modifiers.ctrlKey || modifiers.shiftKey || modifiers.altKey) return null

  const link = target.closest("a.attachment__zoom")
  if (!link) return null
  if (root && !root.contains(link)) return null
  return link
}
