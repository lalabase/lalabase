// What: pluralisation in the Stimulus I18n shim.
// Type: node:test unit spec.
// Why: the shim had none. A key written with one/other resolved to the OBJECT,
//   and the object went straight into textContent as "[object Object]", so every
//   counted string in a controller wrote its own fake plural instead
//   ("2 Zeit-Session(s) ausgewählt"). Nothing raised either way.
import { test } from "node:test"
import assert from "node:assert/strict"
import I18n from "../../../app/javascript/lib/i18n.js"

const withTranslations = (tree, run) => {
  global.window = { translations: tree, locale: "de" }
  try { return run() } finally { delete global.window }
}

const tree = {
  stimulus: {
    time_session: {
      sessions_selected: { one: "%{count} Zeit ausgewählt", other: "%{count} Zeiten ausgewählt" },
      plain: "Ein fester Satz"
    }
  }
}

test("picks the singular for exactly one", () => {
  const result = withTranslations(tree, () =>
    I18n.t("stimulus.time_session.sessions_selected", { count: 1 }))

  assert.equal(result, "1 Zeit ausgewählt")
})

// n-1 / n / n+1 around the only boundary the rule has.
test("picks the plural for none and for many", () => {
  withTranslations(tree, () => {
    assert.equal(I18n.t("stimulus.time_session.sessions_selected", { count: 0 }), "0 Zeiten ausgewählt")
    assert.equal(I18n.t("stimulus.time_session.sessions_selected", { count: 2 }), "2 Zeiten ausgewählt")
  })
})

// The failure this exists to prevent: the object reaching textContent.
test("never returns the forms object itself", () => {
  const result = withTranslations(tree, () =>
    I18n.t("stimulus.time_session.sessions_selected", { count: 3 }))

  assert.equal(typeof result, "string")
  assert.doesNotMatch(String(result), /object Object/)
})

test("leaves a plain string alone, with or without a count", () => {
  withTranslations(tree, () => {
    assert.equal(I18n.t("stimulus.time_session.plain"), "Ein fester Satz")
    assert.equal(I18n.t("stimulus.time_session.plain", { count: 5 }), "Ein fester Satz")
  })
})

// A half-defined key: only one of the two forms exists. The shim answers with
// the form it has instead of leaking the raw key (or undefined) into the page.
test("falls back to the other form when one is missing", () => {
  const halfTree = { stimulus: { time_session: { counted: { other: "%{count} Dinge" } } } }
  withTranslations(halfTree, () => {
    assert.equal(I18n.t("stimulus.time_session.counted", { count: 1 }), "1 Dinge")
    assert.equal(I18n.t("stimulus.time_session.counted", { count: 2 }), "2 Dinge")
  })
})
