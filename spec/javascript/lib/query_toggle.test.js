// What: rebuilding a filter pill's address from the live one.
// Type: node:test unit spec.
// Why: the pills sit outside the Turbo frame and are rendered once, with the
//   page. Every one of them kept the query the page was opened with, so coming
//   from a ticket, setting the ticket filter back to "all" and then clicking any
//   pill put the ticket back. Each link now owns only the parameters it changes.
import { test } from "node:test"
import assert from "node:assert/strict"
import { choiceQuery, nextQuery, ownedFrom } from "../../../app/javascript/lib/query_toggle.js"

test("keeps every parameter the link does not own", () => {
  const result = nextQuery("?ticket_id=abc&date_range=all", [["expand_all", "1"]])

  assert.match(result, /ticket_id=abc/)
  assert.match(result, /date_range=all/)
  assert.match(result, /expand_all=1/)
})

// THE case this exists for: the filter was changed after the page was rendered.
test("does not resurrect a filter the live address no longer has", () => {
  const result = nextQuery("?date_range=all", [["expand_all", "1"]])

  assert.doesNotMatch(result, /ticket_id/)
})

test("an empty value removes the parameter it owns", () => {
  const result = nextQuery("?ticket_id=abc&expand_all=1", [["expand_all", ""]])

  assert.doesNotMatch(result, /expand_all/)
  assert.match(result, /ticket_id=abc/)
})

test("owning a parameter replaces it rather than adding a second one", () => {
  const result = nextQuery("?date_range=this_month", [["date_range", "all"]])

  assert.equal(result, "?date_range=all")
})

// Status filters travel as an array. The server hands over the whole new array,
// so the old one has to go completely, brackets and all.
test("rewrites an array parameter whole", () => {
  const result = nextQuery("?status_filters%5B%5D=billed&status_filters%5B%5D=open&x=1", [
    ["status_filters[]", "billed"],
  ])

  assert.equal(result.match(/status_filters/g).length, 1)
  assert.match(result, /billed/)
  assert.doesNotMatch(result, /open/)
  assert.match(result, /x=1/)
})

// A changed filter starts again at the first page: page 3 of the old result set
// says nothing about the new one.
test("always drops the page", () => {
  assert.doesNotMatch(nextQuery("?page=3&x=1", [["expand_all", "1"]]), /page=3/)
})

test("an empty address yields an empty query, not a bare question mark", () => {
  assert.equal(nextQuery("", [["expand_all", ""]]), "")
})

test("reads the declaration off the element, and survives nonsense in it", () => {
  assert.deepEqual(ownedFrom({ dataset: { queryToggleOwns: '[["a","1"]]' } }), [["a", "1"]])
  assert.deepEqual(ownedFrom({ dataset: { queryToggleOwns: "not json" } }), [])
  assert.deepEqual(ownedFrom({ dataset: {} }), [])
  assert.deepEqual(ownedFrom(null), [])
  assert.deepEqual(ownedFrom({ dataset: { queryToggleOwns: '[["a","1"],"junk"]' } }), [["a", "1"]])
})

// --- choiceQuery: a filter CONTROL, not a link (S4) -------------------------
//
// A select has no href to rewrite, so it builds the address to visit. What is
// pinned here is the one decision in it: the blank option leads nowhere, and a
// real choice carries the widening with it.

test("a choice takes its widening with it", () => {
  const owned = [["date_range", "all"], ["start_date", ""], ["status_filters[]", "billed"]]

  const result = choiceQuery("?date_range=this_month&start_date=2026-09-01", owned,
                             "time_session_group_id", "abc")

  assert.match(result, /date_range=all/)
  assert.doesNotMatch(result, /date_range=this_month/)
  assert.doesNotMatch(result, /start_date/)
  assert.match(result, /status_filters%5B%5D=billed/)
  assert.match(result, /time_session_group_id=abc/)
})

// THE case S4 exists for: the period and the status standing in the live
// address are the two filters that would hide the billing just chosen.
test("replaces the narrower status the address is on, in both spellings", () => {
  const owned = [["status_filters[]", "billed"], ["status_filters[]", "in_billing"]]

  const result = choiceQuery("?status_filters[]=without_billing&status_filters=in_billing", owned,
                             "time_session_group_id", "abc")

  assert.doesNotMatch(result, /without_billing/)
  assert.match(result, /status_filters%5B%5D=billed/)
  assert.match(result, /status_filters%5B%5D=in_billing/)
})

test("keeps a filter the choice knows nothing about", () => {
  const result = choiceQuery("?project_id_filter=p1&page=3", [["date_range", "all"]],
                             "time_session_group_id", "abc")

  assert.match(result, /project_id_filter=p1/)
  // A changed filter starts again at the first page.
  assert.doesNotMatch(result, /page=/)
})

test("the blank option leads nowhere", () => {
  // Not "" and not the widening on its own: the form's ordinary submit answers
  // "alle Abrechnungen" inside the frame, and a query here would turn it into a
  // full page load that also opened the period and the status.
  assert.equal(choiceQuery("?date_range=this_month", [["date_range", "all"]], "time_session_group_id", ""), null)
  assert.equal(choiceQuery("?date_range=this_month", [["date_range", "all"]], "time_session_group_id", null), null)
})

test("a control without a name leads nowhere", () => {
  assert.equal(choiceQuery("?a=1", [["date_range", "all"]], "", "abc"), null)
})

test("the chosen value wins over the one in the address", () => {
  const result = choiceQuery("?time_session_group_id=old", [], "time_session_group_id", "new")

  assert.match(result, /time_session_group_id=new/)
  assert.doesNotMatch(result, /old/)
})

// --- the two subject ids are one Bezug (S6 review) --------------------------
//
// A booking has ONE subject or none, and the database says so
// (check constraint time_sessions_single_subject). So an address carrying both
// ticket_id and meeting_id can never have a row, and a control that can build
// one is a control that empties the list for good: until S7 there is no visible
// meeting filter to switch off again.
//
// The Ruby twin of this declaration is TimeSessions::ListFilters::SUBJECT_REMOVAL, built
// from TimeSession::SUBJECT_FILTER_PARAMS; the request spec pins that the subject
// pill's options carry it.
//
// ⚠️ choiceQuery itself has had no consumer since S7: it is the SELECT half of
// query-toggle (#visit reads event.target.name), and the filter line has no
// selects left. The rule this test describes is alive and pinned on the Ruby
// side; the path through here is not. Removing #visit and choiceQuery is its
// own small cut, deliberately not folded into S7.
test("picking a ticket drops the meeting filter instead of ANDing with it", () => {
  const result = choiceQuery("?project_id_filter=p1&meeting_id=m1&date_range=all",
                             [["meeting_id", ""]], "ticket_id", "t1")

  assert.match(result, /ticket_id=t1/)
  assert.doesNotMatch(result, /meeting_id/)
  assert.match(result, /project_id_filter=p1/)
  assert.match(result, /date_range=all/)
})

// "Alle Tickets" is the blank option: it narrows nothing, so it widens nothing
// either and the form's own submit may answer it inside the frame. The meeting
// filter is the reader's arrival state there, not something the choice built.
test("the blank ticket option navigates nowhere and so takes nothing away", () => {
  assert.equal(choiceQuery("?meeting_id=m1", [["meeting_id", ""]], "ticket_id", ""), null)
})
