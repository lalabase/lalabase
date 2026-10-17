// Who takes an Escape. Menus, modals, drawers and the like close on Escape,
// and so does the detail lane behind them; only the topmost thing may react.
// Their listeners sit on the element, the document or the window, so the order
// in which they run proves nothing, and event.defaultPrevented alone depends
// on that order.
//
// The rule, one per owner instead of one list in the lane:
//   * every Stimulus controller that reacts to Escape answers ownsEscape():
//     true while its next Escape would close or undo something of its own;
//   * a layer a script builds outside any controller carries
//     data-owns-escape while it stands in the page;
//   * a native <dialog open> owns it by itself.
// The lane asks before any listener has run (layout_toggle_controller).
// Guard: spec/architecture/escape_owner_guard_spec.rb.
export const OWNS_ESCAPE_ATTRIBUTE = 'data-owns-escape'

export function escapeOwned(controllers, root) {
  if (root.querySelector(`dialog[open], [${OWNS_ESCAPE_ATTRIBUTE}]`)) return true

  return controllers.some((controller) => typeof controller?.ownsEscape === 'function' && answers(controller))
}

// One owner that throws must not take Escape away from every lane: it is
// reported and counts as not owning.
function answers(controller) {
  try {
    return Boolean(controller.ownsEscape())
  } catch (error) {
    console.error('ownsEscape() failed', controller.identifier, error)
    return false
  }
}
