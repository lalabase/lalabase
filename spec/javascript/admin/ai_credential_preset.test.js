// What: the field list the admin credential-preset controller copies into the form.
// Type: node:test unit spec (no DOM, no Stimulus runtime — see below).
// Why (philosophy): this controller used to carry a hand-maintained PRESET_FIELDS
//   array beside AiCredential::EU_CHAT_PRESETS, and it rotted at the first
//   opportunity: E12 added `company_domicile` to all three presets and to the form,
//   the array was not extended, and picking a preset silently left the domicile
//   blank — which made AiPackage#eu_company? false and hid the resulting package
//   from the very EU filter the preset exists to satisfy. Nothing failed; the model
//   spec splats the preset hash directly and is blind at exactly this decision point.
// Contract: every key a preset carries reaches #fill. Not "these five keys reach it"
//   — that is the assertion that rotted. A new preset attribute must be copied
//   without anyone remembering to extend a list.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const HERE = dirname(fileURLToPath(import.meta.url))
const CONTROLLER = join(HERE, "../../../app/javascript/controllers/admin_ai_credential_preset_controller.js")

// Importing the module would pull in @hotwired/stimulus, which is served by the
// importmap and is not resolvable from node. The behaviour under test is a single
// expression, so the source is asserted directly — the alternative (a Stimulus test
// harness) would cost more than the rule is worth.
const source = readFileSync(CONTROLLER, "utf8")

test("copies every key the preset carries, not a hand-maintained subset", () => {
  assert.match(
    source,
    /Object\.keys\(preset\)\.forEach\(\(field\) => this\.fill\(field, preset\[field\]\)\)/,
    "the preset's own keys must be the field list"
  )
})

test("keeps no second list of preset attributes beside EU_CHAT_PRESETS", () => {
  assert.doesNotMatch(
    source,
    /const PRESET_FIELDS\s*=/,
    "a literal field array is the defect this test exists for"
  )
})

test("still forces the provider, which is NOT a preset key", () => {
  // provider is the one value that does not come from the hash: all presets ride
  // the openai_compatible rail, and the hash does not repeat it three times.
  assert.match(source, /this\.fill\("provider", PRESET_PROVIDER\)/)
  assert.match(source, /const PRESET_PROVIDER = "openai_compatible"/)
})

test("guards a preset key that has no matching form input", () => {
  // What makes keying on the hash safe: an unknown key is a no-op, not a crash.
  assert.match(source, /const input = this\.element\.querySelector\(`#ai_credential_\$\{field\}`\)\s*\n\s*if \(!input\) return/)
})
