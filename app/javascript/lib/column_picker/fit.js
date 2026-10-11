// The fit rule of the column picker (doc/spaltenwahl_plan.md, "The model"):
// how many of the ranked columns, in rank order, fit into the list next to
// the two fixed columns. Pure arithmetic over numbers so
// node:test can pin it; the controller measures, this decides. No imports on
// purpose: bare specifiers do not resolve under node.

// The width the ranked columns may share: the list's inner width minus what
// number and title take. The picker trigger is outside the table.
export function availableWidth(listWidth, fixedWidth) {
  return Math.max(0, (listWidth || 0) - (fixedWidth || 0))
}

// How many leading widths fit into `available`. The columns come in rank
// order, so the answer is a count, never a selection: rank 3 is never in
// while rank 2 is out.
export function fitCount(available, minWidths) {
  let used = 0
  let count = 0
  for (const width of minWidths || []) {
    if (used + width > available) break
    used += width
    count += 1
  }
  return count
}

// The width of a ranked column in FULL mode (the lane shut): its share of
// the table, but never less than its minimum. A value is not cut while a
// neighbour has room; the title, width auto, takes the rest and is cut last
// (designer, 09.09.2026). Computed here and not in the stylesheet, because a
// fixed table layout reads width alone and Blink treats max() with a
// percentage on a cell as auto. share is a fraction (0.14), not a percent.
export function fullModeWidth(minWidth, share, tableWidth) {
  const fromShare = Math.round((share || 0) * (tableWidth || 0))
  return Math.max(minWidth || 0, fromShare)
}
