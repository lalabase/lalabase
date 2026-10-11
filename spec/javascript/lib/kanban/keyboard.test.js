// The way between the board's stops. Wrong here and the keyboard skips a
// column, falls off the end of one, or lands on a card that is not there.
import { test } from "node:test"
import assert from "node:assert/strict"
import { move, HEAD, CARD, ADD } from "../../../../app/javascript/lib/kanban/keyboard.js"

// A: three cards; B: one card; C: empty; D: a reader's column, two cards, no "+ Ticket".
const A = [HEAD, CARD, CARD, CARD, ADD]
const B = [HEAD, CARD, ADD]
const C = [HEAD, ADD]
const D = [HEAD, CARD, CARD]
const board = [A, B, C, D]

test("down and up walk a column from the head to + Ticket and stop at both ends", () => {
  assert.deepEqual(move(board, { column: 0, row: 0 }, "ArrowDown"), { column: 0, row: 1 })
  assert.deepEqual(move(board, { column: 0, row: 3 }, "ArrowDown"), { column: 0, row: 4 })
  assert.deepEqual(move(board, { column: 0, row: 4 }, "ArrowDown"), { column: 0, row: 4 })
  assert.deepEqual(move(board, { column: 0, row: 1 }, "ArrowUp"), { column: 0, row: 0 })
  assert.deepEqual(move(board, { column: 0, row: 0 }, "ArrowUp"), { column: 0, row: 0 })
  // A reader's column ends at its last card.
  assert.deepEqual(move(board, { column: 3, row: 2 }, "ArrowDown"), { column: 3, row: 2 })
})

test("right and left keep the height, take a shorter neighbour's last card, an empty one's head", () => {
  // Same height: card 1 of A to card 1 of B.
  assert.deepEqual(move(board, { column: 0, row: 1 }, "ArrowRight"), { column: 1, row: 1 })
  // Shorter neighbour: card 3 of A to B's last (only) card.
  assert.deepEqual(move(board, { column: 0, row: 3 }, "ArrowRight"), { column: 1, row: 1 })
  // Empty neighbour: reached, at its head; never skipped.
  assert.deepEqual(move(board, { column: 1, row: 1 }, "ArrowRight"), { column: 2, row: 0 })
  // Out of the empty column to the right: its head to D's head, its + Ticket to D's last card.
  assert.deepEqual(move(board, { column: 2, row: 0 }, "ArrowRight"), { column: 3, row: 0 })
  assert.deepEqual(move(board, { column: 2, row: 1 }, "ArrowRight"), { column: 3, row: 2 })
  // Heads to heads, + Ticket to + Ticket.
  assert.deepEqual(move(board, { column: 0, row: 0 }, "ArrowRight"), { column: 1, row: 0 })
  assert.deepEqual(move(board, { column: 0, row: 4 }, "ArrowRight"), { column: 1, row: 2 })
  // The edges of the board stay.
  assert.deepEqual(move(board, { column: 0, row: 2 }, "ArrowLeft"), { column: 0, row: 2 })
  assert.deepEqual(move(board, { column: 3, row: 1 }, "ArrowRight"), { column: 3, row: 1 })
  // Left from D's first card to C's head, from B's card to A's card 1.
  assert.deepEqual(move(board, { column: 3, row: 1 }, "ArrowLeft"), { column: 2, row: 0 })
  assert.deepEqual(move(board, { column: 1, row: 1 }, "ArrowLeft"), { column: 0, row: 1 })
})

test("Home and End are the column's first and last card, or the head and + Ticket without cards", () => {
  assert.deepEqual(move(board, { column: 0, row: 4 }, "Home"), { column: 0, row: 1 })
  assert.deepEqual(move(board, { column: 0, row: 0 }, "End"), { column: 0, row: 3 })
  assert.deepEqual(move(board, { column: 2, row: 1 }, "Home"), { column: 2, row: 0 })
  assert.deepEqual(move(board, { column: 2, row: 0 }, "End"), { column: 2, row: 1 })
  assert.deepEqual(move(board, { column: 3, row: 0 }, "End"), { column: 3, row: 2 })
})

test("an unknown key and a position off the board change nothing", () => {
  assert.deepEqual(move(board, { column: 0, row: 1 }, "Enter"), { column: 0, row: 1 })
  assert.deepEqual(move(board, { column: 9, row: 0 }, "ArrowDown"), { column: 9, row: 0 })
  assert.deepEqual(move([], { column: 0, row: 0 }, "ArrowRight"), { column: 0, row: 0 })
})
