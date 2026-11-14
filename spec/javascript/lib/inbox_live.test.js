// What: the rule of the live inbox above the organisations (lib/inbox_live.js).
// Why:  three ways to get it wrong, each seen elsewhere: a banner after every own
//   click (the echo of the reader's action), a list that moves under the reader,
//   and a redraw that drops the pages the endless scroll loaded.
import { test } from "node:test"
import assert from "node:assert/strict"
import { listActionAddress, liveStep, redrawAddress } from "../../../app/javascript/lib/inbox_live.js"

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

// The head and the timer of the lane: the list state of the page when they leave, the
// loaded pages, and the open row and quiet from their own address (a search drops the
// open row from the page's address).
test("a lane action takes the page's list state, the loaded pages and keeps its own row", () => {
  const list = { dataset: { neoEndlessScrollFirstPageValue: "2", neoEndlessScrollPageValue: "4" } }
  const address = new URL(listActionAddress(
    "https://lalabase.test/inbox?org=o1&search=Karton&state_filters%5B%5D=unread&page=2",
    "/inbox/n1/mark_read?state_filters%5B%5D=read&notification=n1&quiet=1",
    list, { keep: ["notification", "quiet"] }))
  assert.equal(address.pathname, "/inbox/n1/mark_read")
  assert.equal(address.searchParams.get("search"), "Karton")
  assert.deepEqual(address.searchParams.getAll("state_filters[]"), ["unread"])
  assert.equal(address.searchParams.get("org"), "o1")
  assert.equal(address.searchParams.get("page"), "2")
  assert.equal(address.searchParams.get("through_page"), "4")
  assert.equal(address.searchParams.get("notification"), "n1")
  assert.equal(address.searchParams.get("quiet"), "1")
})

test("a lane action names its own row over the page's, and no part of a live redraw", () => {
  const address = new URL(listActionAddress(
    "https://lalabase.test/inbox?notification=other&part=counts",
    "/inbox/n1/archive?notification=n1&quiet=1", null, { keep: ["notification"] }))
  assert.equal(address.searchParams.get("notification"), "n1")
  assert.equal(address.searchParams.get("quiet"), null)
  assert.equal(address.searchParams.get("part"), null)
  assert.equal(address.searchParams.get("page"), "1")
})

