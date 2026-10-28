// What: the pure part of person_details_controller.js (the additional details
//   of a person in the people form), so node:test can pin it.
// Why:  the rows travel as an indexed hash (person[additional_details][3][...]),
//   and the server orders them by that index. A new row needs an index no other
//   row has, or two rows merge into one on the server. The kinds, their inputs
//   and the limit come from the server (PersonDetail): nothing here knows a kind.

// The index of a new row: one above the highest present, 0 for none. Gaps from
// removed rows stay; only the order matters to the server.
export function nextIndex(indexes) {
  const numbers = indexes
    .map((value) => (/^\d+$/.test(String(value)) ? Number(value) : NaN))
    .filter((number) => Number.isSafeInteger(number))
  return numbers.length === 0 ? 0 : Math.max(...numbers) + 1
}

// The markup of the row template with its placeholder index filled in.
export function fillIndex(html, index) {
  return html.replaceAll("__INDEX__", String(index))
}

// Whether one more row fits under the limit.
export function canAdd(count, max) {
  return Number.isInteger(max) && count < max
}

// The value field of a kind, from the server's kinds map
// ({ phone: { input: "tel", maxlength: 255, list: "..." }, ... }): a textarea
// for a multi-line kind, else an input of the given type. An unknown kind gets
// a plain text input without suggestions.
export function valueField(kinds, kind) {
  const config = (kinds && Object.hasOwn(kinds, kind) && kinds[kind]) || {}
  const multiLine = config.input === "textarea"
  return {
    tag: multiLine ? "textarea" : "input",
    type: multiLine ? null : config.input || "text",
    maxlength: config.maxlength ?? null,
    list: config.list || null
  }
}

// A multi-line value (an address) for a single-line field: its lines, trimmed,
// joined with ", ", so a kind switch keeps what was typed readable.
export function singleLine(value) {
  return String(value)
    .split(/\r\n|\r|\n/)
    .map((line) => line.trim())
    .filter((line) => line !== "")
    .join(", ")
}
