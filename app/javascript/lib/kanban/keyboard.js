// The board's stops and the way between them (doc/kanban_keyboard_plan.md, S3).
//
// A column is its stops top to bottom: HEAD, one CARD per card, then ADD when
// the column offers "+ Ticket" (a reader's column does not). A position is
// { column, row } into that list. move() answers a key with the next position,
// or the same one where the key leads nowhere. It never skips a column: an
// empty one has its head to land on, and its "+ Ticket" when it has one, so a
// ticket can be made there (37a, section 5).
export const HEAD = "head"
export const CARD = "card"
export const ADD = "add"

export function move(columns, position, key) {
  const column = columns[position.column]
  if (!column) return position
  switch (key) {
    case "ArrowDown": return at(position.column, Math.min(position.row + 1, column.length - 1))
    case "ArrowUp": return at(position.column, Math.max(position.row - 1, 0))
    case "ArrowLeft": return sideways(columns, position, -1)
    case "ArrowRight": return sideways(columns, position, 1)
    case "Home": return at(position.column, firstCard(column) ?? 0)
    case "End": return at(position.column, lastCard(column) ?? column.length - 1)
    default: return position
  }
}

// The neighbour column at the same height. From a head the neighbour's head;
// from "+ Ticket" the neighbour's "+ Ticket", or its last card when the
// neighbour has none; from a card the card at the same index, a shorter
// neighbour's last card, an empty neighbour's head.
function sideways(columns, position, step) {
  const target = position.column + step
  const column = columns[target]
  if (!column) return position
  const kind = columns[position.column][position.row]
  if (kind === HEAD) return at(target, 0)
  if (kind === ADD) {
    const add = column.indexOf(ADD)
    return at(target, add >= 0 ? add : (lastCard(column) ?? 0))
  }
  const count = column.filter(stop => stop === CARD).length
  if (count === 0) return at(target, 0)
  return at(target, Math.min(position.row - 1, count - 1) + 1)
}

function firstCard(column) {
  const row = column.indexOf(CARD)
  return row >= 0 ? row : null
}

function lastCard(column) {
  const row = column.lastIndexOf(CARD)
  return row >= 0 ? row : null
}

function at(column, row) {
  return { column, row }
}
