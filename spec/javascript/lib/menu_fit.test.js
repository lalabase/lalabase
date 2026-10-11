import test from "node:test"
import assert from "node:assert"
import { menuShift, MENU_MARGIN } from "../../../app/javascript/lib/menu_fit.js"

// What: how far an opened filter menu moves sideways so it stays on the screen
//   (review of #932: the subject menu reached x = 512 on a 390 px phone).
// Why:  the menu hangs from its pill, and where the pill ends up is only known
//   in the browser. The rule is pure so it can be pinned here; the controller
//   only measures and moves the menu.

const box = (left, width) => ({ left, right: left + width })

test("a menu that fits stays where it is", () => {
  assert.equal(menuShift(box(20, 256), 390), 0)
})

test("a menu past the right edge moves left until it ends at the margin", () => {
  const shift = menuShift(box(200, 256), 390)
  assert.equal(shift, 390 - MENU_MARGIN - 456)
  assert.equal(200 + shift + 256, 390 - MENU_MARGIN)
})

// An end-aligned menu hangs leftwards and can cross the LEFT edge.
test("a menu past the left edge moves right until it starts at the margin", () => {
  assert.equal(menuShift(box(-40, 256), 390), MENU_MARGIN + 40)
})

// The edges themselves: exactly at the margin is inside.
test("a menu ending exactly at the margin does not move", () => {
  assert.equal(menuShift(box(390 - MENU_MARGIN - 256, 256), 390), 0)
  assert.equal(menuShift(box(390 - MENU_MARGIN - 255, 256), 390), -1)
})

// Wider than the room between the margins (the CSS cap normally prevents it):
// the start is what the reader reads, so the start wins.
test("a menu wider than the screen starts at the left margin", () => {
  assert.equal(menuShift(box(100, 500), 390), MENU_MARGIN - 100)
})
