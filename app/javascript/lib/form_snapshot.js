// Serialises a form's current values into one comparable string, so a layer can tell an
// untouched form from one with unsaved changes (neo_writing_surface_controller, P3-E3).
// Dependency-free for `node --test`: takes an iterable of [name, value] pairs, which is
// what FormData yields; File entries are reduced to name and size.

export function snapshotEntries(entries, { ignore = [] } = {}) {
  const rows = []
  for (const [name, value] of entries) {
    if (ignore.includes(name)) continue
    const printable = value && typeof value === "object" && "size" in value
      ? `file:${value.name || ""}:${value.size}`
      : String(value ?? "")
    rows.push(`${name}=${printable}`)
  }
  return rows.sort().join("\n")
}

// The fields a form carries that change without the user doing anything.
export const VOLATILE_FIELDS = ["authenticity_token", "utf8", "_method"]
