// Decision logic of the browser-side courtesy check for images inside rich texts
// (spike plan Inline-Bilder, E1 point 3 / D5, D7). The RULE lives on the server
// (RichTextEmbedGuard); this only spares the user a full upload that would end in a
// 422. Lexxy's own `permitted-attachment-types` filters the type, nobody filters the
// size, so the size is checked here from the data attributes the view renders out of
// RichTextEmbeds. Dependency-free so it runs under plain `node --test`.

// limits: { types: ["image/png", ...], maxBytes: Number }
// file:   { type: String, size: Number }
// returns { accepted: true } or { accepted: false, reason: "type" | "size" }
export function acceptsFile(file, limits) {
  const type = String(file?.type || "").toLowerCase()
  const size = Number(file?.size)
  const types = (limits?.types || []).map((t) => String(t).toLowerCase())
  const maxBytes = Number(limits?.maxBytes)

  if (types.length > 0 && !types.includes(type)) return { accepted: false, reason: "type" }
  if (Number.isFinite(maxBytes) && maxBytes > 0 && Number.isFinite(size) && size > maxBytes) {
    return { accepted: false, reason: "size" }
  }
  return { accepted: true }
}

// "image/png,image/jpeg" (the attribute Lexxy reads) -> ["image/png", "image/jpeg"]
export function parsePermittedTypes(attributeValue) {
  return String(attributeValue || "")
    .split(",")
    .map((t) => t.trim().toLowerCase())
    .filter((t) => t.length > 0)
}
