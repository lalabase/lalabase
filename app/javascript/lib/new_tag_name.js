// What the tags layer of the bulk panel offers for a typed name: nothing, the
// tag that already exists, a refusal, or a new tag. The spelling mirrors
// Tag.normalize_name and the limits Tag.acceptable_new_name? on the server
// (deliberate copy: the server decides, this only keeps the panel from
// offering what the server refuses). The limits arrive from the page, never
// as numbers of their own.
//
// `existing` holds the values the layer lists, already in stored spelling.

export function normalizeTagName(input) {
  return String(input ?? "").trim().toLowerCase()
}

export function newTagOffer(input, { existing = [], maxLength, separator }) {
  const name = normalizeTagName(input)
  if (name === "") return { name, state: "none" }
  if (existing.includes(name)) return { name, state: "exists" }
  // Characters, not UTF-16 units: Ruby's String#length counts code points,
  // and an emoji would weigh two here otherwise.
  if ([...name].length > maxLength || (separator && name.includes(separator))) return { name, state: "invalid" }
  return { name, state: "new" }
}

// The names a run just gave that the layer does not list yet, in the order
// the layer lists its tags (by name, as TagsController and BulkFields sort).
export function namesToList(listed, given) {
  const known = new Set(listed)
  return [...new Set(given)].filter((name) => name !== "" && !known.has(name)).sort()
}

// Where a name goes among the listed ones: before the first that sorts after it.
export function listPosition(listed, name) {
  const index = listed.findIndex((other) => other > name)
  return index === -1 ? listed.length : index
}
