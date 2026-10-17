// What: the naming form of the save row (lib/filter_bar/save_row.js).
// Type: node:test unit spec.
// Why: a list of the whole organisation ("Alle Meetings") has no project. Its
//   form must not post an empty project_id: the server reads a present
//   project_id as "this project", and the new view belongs to no project.
import { test } from "node:test"
import assert from "node:assert/strict"

// The HTML encoder allocates a div on import; the CSRF token is read from a meta tag.
globalThis.document = {
  querySelector: () => null,
  createElement: () => {
    let text = ""
    return {
      set textContent(v) { text = String(v) },
      get innerHTML() { return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    }
  }
}
globalThis.window = { location: { search: "" } }

const { buildNamingRowHtml } = await import("../../../../app/javascript/lib/filter_bar/save_row.js")

const build = (projectId) => buildNamingRowHtml({
  saveUrl: "/org/1/smart_folders/create_from_filters",
  projectId,
  filters: { participant: ["anna"] },
  operators: {},
  suggestion: "Anna"
})

test("a list of one project posts its project_id", () => {
  assert.match(build("p-1"), /<input type="hidden" name="project_id" value="p-1">/)
})

test("a list without a project posts no project_id at all", () => {
  for (const projectId of ["", null, undefined]) {
    assert.doesNotMatch(build(projectId), /name="project_id"/)
  }
})
