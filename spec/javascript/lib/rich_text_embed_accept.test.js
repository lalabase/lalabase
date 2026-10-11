// What: the decision logic behind the browser-side image check for rich texts.
// Type: node:test unit spec (no DOM, no Stimulus runtime).
// Why: the rule itself lives in RichTextEmbedGuard (server); this function only decides
//   whether to spare the user an upload that ends in a 422. Its inputs are the attribute
//   Lexxy reads (`permitted-attachment-types`) and `data-max-bytes`, both rendered from
//   RichTextEmbeds, so type and size verdicts must match the server for the same limits.
import { test } from "node:test"
import assert from "node:assert/strict"
import { acceptsFile, parsePermittedTypes } from "../../../app/javascript/lib/rich_text_embed_accept.js"

const limits = { types: ["image/png", "image/jpeg", "image/gif", "image/webp"], maxBytes: 10 * 1024 * 1024 }

test("accepts a PNG within the limit", () => {
  assert.deepEqual(acceptsFile({ type: "image/png", size: 2 * 1024 * 1024 }, limits), { accepted: true })
})

test("accepts exactly the limit and refuses one byte above", () => {
  assert.equal(acceptsFile({ type: "image/png", size: limits.maxBytes }, limits).accepted, true)
  assert.deepEqual(acceptsFile({ type: "image/png", size: limits.maxBytes + 1 }, limits), { accepted: false, reason: "size" })
})

test("refuses a PDF by type, before looking at the size", () => {
  assert.deepEqual(acceptsFile({ type: "application/pdf", size: 10 }, limits), { accepted: false, reason: "type" })
})

test("compares types case-insensitively and tolerates a missing type", () => {
  assert.equal(acceptsFile({ type: "IMAGE/PNG", size: 10 }, limits).accepted, true)
  assert.equal(acceptsFile({ type: "", size: 10 }, limits).accepted, false)
})

test("without a type list only the size rule applies", () => {
  assert.equal(acceptsFile({ type: "application/pdf", size: 10 }, { types: [], maxBytes: 100 }).accepted, true)
  assert.equal(acceptsFile({ type: "application/pdf", size: 101 }, { types: [], maxBytes: 100 }).accepted, false)
})

test("parses Lexxy's attribute value", () => {
  assert.deepEqual(parsePermittedTypes("image/png, Image/JPEG ,,"), ["image/png", "image/jpeg"])
  assert.deepEqual(parsePermittedTypes(null), [])
})
