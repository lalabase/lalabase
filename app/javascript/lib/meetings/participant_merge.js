// Merge rule for LLM-detected participant names (Gespräche Slice 5) — pure and
// DOM-free so `node --test` covers the four contract cases from the plan §5
// data-flow diagram. The LLM only ever ADDS suggestions; chips are user
// territory:
//
//   new name              → returned (caller adds it as a suggestion chip)
//   chip already exists   → not returned (existing chip stays untouched)
//   removed by the user   → not returned (a dismissal is permanent for LLM runs)
//   edited by the user    → not returned when the edit normalizes to the same
//                           person (umlaut/case/whitespace variants) — never a
//                           rename, never a replacement
//
// The `normalize` fn is injected (not imported) on purpose — same rule as
// participant_parser.js: callers pass name_normalizer's normalizeName (browser
// via pinned specifier, node via filesystem path), so there is exactly one
// normalization implementation and no import that breaks in either environment.
//
// `existingKeys` / `dismissedKeys` are Sets of ALREADY-normalized keys (the
// Stimulus controller builds them via chipKeys() and its dismissal tracking).
export function mergeDetections({ detected, existingKeys, dismissedKeys, normalize }) {
  const toAdd = []
  const seen = new Set()

  for (const raw of detected || []) {
    const name = String(raw || "").trim().replace(/\s+/g, " ")
    if (!name) continue

    const key = normalize(name)
    if (!key || seen.has(key)) continue
    seen.add(key)

    if (existingKeys.has(key)) continue // already present → leave untouched
    if (dismissedKeys.has(key)) continue // user removed it → stays gone

    toAdd.push(name)
  }

  return toAdd
}
