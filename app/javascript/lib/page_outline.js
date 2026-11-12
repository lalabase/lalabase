// What: which section of a page the reader is in, for the page outline
//   (shared/_page_outline, page_outline_controller.js). Pure, so node:test can
//   pin it; the controller only measures and paints.
// Why:  "the section under the reading line" alone is wrong at both ends of a
//   page, and exactly there a reader looks at the outline:
//   - at the end the last sections are too short to ever reach the line, so the
//     bottom of the page belongs to the last one;
//   - a jump to such a section must mark the one that was CHOSEN, not the one
//     the page happened to stop at. The choice holds while its section is in
//     view and the reader has not scrolled on by hand (the controller drops it).
//
// tops:    the distance of each section's top edge from the top of the window,
//          in page order.
// line:    how far below the top of the window a section counts as "reached".
// atEnd:   the page cannot scroll any further down.
// chosen:  the index of a section the reader just jumped to, or null.
// height:  the height of the window (a chosen section must be inside it).
//
// Returns the index of the current section, or -1 for a page without sections.
export function currentSection({ tops, line, atEnd = false, chosen = null, height = Infinity }) {
  if (tops.length === 0) return -1

  if (chosen !== null && chosen >= 0 && chosen < tops.length && tops[chosen] >= 0 && tops[chosen] < height) {
    return chosen
  }
  if (atEnd) return tops.length - 1

  // The last section whose top has passed the line. Above the first one (the
  // head of the page) the first section is the nearest thing to "here".
  let index = 0
  tops.forEach((top, position) => {
    if (top <= line) index = position
  })
  return index
}
