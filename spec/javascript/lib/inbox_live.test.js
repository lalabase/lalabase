// What: the rule of the live inbox above the organisations (lib/inbox_live.js).
// Why:  three ways to get it wrong, each seen elsewhere: a banner after every own
//   click (the echo of the reader's action), a list that moves under the reader,
//   and a redraw that drops the pages the endless scroll loaded.
import { test } from "node:test"
import assert from "node:assert/strict"
import { liveStep, returnStep, redrawAddress } from "../../../app/javascript/lib/inbox_live.js"

test("a signal equal to the drawn stamp is the echo: no banner, no fetch", () => {
  assert.deepEqual(liveStep({ signal: "a", drawn: "a", counted: null, hidden: false }), { banner: false, fetch: null })
})

test("a newer signal in view: the counts follow, the banner offers the list", () => {
  assert.deepEqual(liveStep({ signal: "b", drawn: "a", counted: null, hidden: false }), { banner: true, fetch: "counts" })
})

test("the counts of one signal are fetched once", () => {
  assert.deepEqual(liveStep({ signal: "b", drawn: "a", counted: "b", hidden: false }), { banner: true, fetch: null })
})

test("a hidden tab waits", () => {
  assert.deepEqual(liveStep({ signal: "b", drawn: "a", counted: null, hidden: true }), { banner: false, fetch: null })
})

test("no signal yet: nothing", () => {
  assert.deepEqual(liveStep({ signal: null, drawn: "a", counted: null, hidden: false }), { banner: false, fetch: null })
})

test("a tab shown again redraws a list that is behind, and only then", () => {
  assert.equal(returnStep({ signal: "b", drawn: "a" }), "list")
  assert.equal(returnStep({ signal: "a", drawn: "a" }), null)
})

test("the redraw keeps the page's filters and the loaded pages", () => {
  const address = new URL(redrawAddress("https://lalabase.test/inbox?org=o1&search=Regal&state_filters%5B%5D=unread&page=3", {
    path: "/inbox", firstPage: "1", throughPage: "4", part: "list"
  }))

  assert.equal(address.pathname, "/inbox")
  assert.equal(address.searchParams.get("org"), "o1")
  assert.equal(address.searchParams.get("search"), "Regal")
  assert.deepEqual(address.searchParams.getAll("state_filters[]"), ["unread"])
  assert.equal(address.searchParams.get("page"), "1")
  assert.equal(address.searchParams.get("through_page"), "4")
  assert.equal(address.searchParams.get("part"), null)
})

test("the counts alone say so, and an old part or through_page does not linger", () => {
  const address = new URL(redrawAddress("https://lalabase.test/inbox?part=counts&through_page=9", {
    path: "/inbox", firstPage: null, throughPage: null, part: "counts"
  }))

  assert.equal(address.searchParams.get("part"), "counts")
  assert.equal(address.searchParams.get("through_page"), null)
  assert.equal(address.searchParams.get("page"), "1")
})
