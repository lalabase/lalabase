// How far an opened menu has to move sideways to stay on the screen.
//
// Entry point: menuShift
//
// The filter pills' menus hang from their pill (shared/_filter_pill), and on a
// phone a pill can sit anywhere in a wrapped row: the subject menu reached
// x = 512 on a 390 px screen and the drawer scrolled sideways (review of
// #932). CSS caps the menu's width to the screen; this moves it into view. A
// pure function, so node:test can pin it; details_autoclose_controller.js
// measures and moves the menu.

// The room kept free at each edge, in CSS pixels.
export const MENU_MARGIN = 8

// `box` is the menu's measured { left, right } with no shift applied.
// Returns the pixels to move it: negative is left, positive is right.
export function menuShift(box, viewportWidth, margin = MENU_MARGIN) {
  const width = box.right - box.left
  // Wider than the room: the start is what the reader reads, so it wins.
  if (width > viewportWidth - margin * 2) return margin - box.left
  if (box.right > viewportWidth - margin) return viewportWidth - margin - box.right
  if (box.left < margin) return margin - box.left
  return 0
}
