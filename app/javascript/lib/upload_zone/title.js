// The title a file suggests, and whether a title field may take it (S4 of
// doc/dokumentansicht_plan.md, the designer's 43a: "Titel vorbelegt aus dem
// Dateinamen"). Pure, so node:test can say what it does without a browser.

// The file's name without its extension: the last dot and what follows, only
// when something stands before it (".gitignore" keeps its name), any folder
// part dropped, whitespace trimmed. Only the extension goes: "Angebot_v2.final.pdf"
// suggests "Angebot_v2.final"; what the writer chose to call the file stays.
export function titleFromFilename(name) {
  const base = String(name || "").split(/[\\/]/).pop().trim()
  const dot = base.lastIndexOf(".")
  return dot > 0 ? base.slice(0, dot).trim() : base
}

// Whether the title field may take the file's suggestion: only while it is
// empty or still carries the LAST suggestion, never over words the writer
// typed (the plan's risk: the prefill must not overwrite a title typed first).
export function mayPrefill(current, lastSuggestion) {
  const value = String(current || "").trim()
  return value === "" || value === String(lastSuggestion || "")
}
