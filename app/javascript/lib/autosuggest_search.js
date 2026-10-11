// What: the server search of NeoAutosuggest (url: on the component), as plain logic so
//   node:test can pin it (spec/javascript/lib/autosuggest_search.test.js). The Stimulus
//   controller only renders what this decides.
// Why:  with a server list the options change under the user (doc/ticket_relations_plan.md,
//   revision 4, §7, review 5). The client-filtered picker restored the chosen text from the
//   options it was showing; with changing results it could send A while B was on screen.
//   So four rules:
//   1. The CONFIRMED choice (value + text) is kept apart from the results.
//   2. Typing drops the confirmed choice explicitly: the field holds a search, not a choice.
//   3. Every request carries a sequence number, and only the latest answer is used; an
//      answer to an older term, or one that arrives after a choice or a close, lands nowhere.
//   4. Closing cancels the pending debounce and aborts the request in flight.
//   5. Typing makes the shown results stale at once (onLoading), not when the debounce
//      runs out: until then a keyboard mark on an old result would still be taken by
//      Enter (review of #944).

export const DEFAULT_DEBOUNCE_MS = 250

const NO_SELECTION = Object.freeze({ value: "", text: "" })

// The base URL comes from ERB and may carry parameters of its own (exclude=...); only q is
// set here. A dummy origin lets URL parse a path-only value, and the result stays relative.
export function searchUrl(baseUrl, term) {
  const url = new URL(baseUrl, "http://autosuggest.invalid")
  url.searchParams.set("q", term)
  return `${url.pathname}${url.search}`
}

// The server contract: { options: [{ value, text, detail }] }. Only well-formed entries
// survive; the text is rendered as text, never as HTML.
export function parseOptions(payload) {
  const list = payload && Array.isArray(payload.options) ? payload.options : []
  return list
    .filter((option) => option && typeof option.value === "string" && typeof option.text === "string")
    .map((option) => ({
      value: option.value,
      text: option.text,
      detail: typeof option.detail === "string" ? option.detail : ""
    }))
}

export class ServerSearch {
  constructor({
    url,
    fetch = (...args) => globalThis.fetch(...args),
    debounceMs = DEFAULT_DEBOUNCE_MS,
    setTimer = (fn, ms) => setTimeout(fn, ms),
    clearTimer = (id) => clearTimeout(id),
    selection = NO_SELECTION,
    onResults = () => {},
    onError = () => {},
    onIdle = () => {},
    onLoading = () => {}
  }) {
    this.url = url
    this.fetch = fetch
    this.debounceMs = debounceMs
    this.setTimer = setTimer
    this.clearTimer = clearTimer
    this.callbacks = { onResults, onError, onIdle, onLoading }
    this.chosen = selection && selection.value ? { value: selection.value, text: selection.text || "" } : NO_SELECTION
    this.sequence = 0
    this.timer = null
    this.controller = null
  }

  get selection() {
    return { ...this.chosen }
  }

  get hasSelection() {
    return this.chosen.value !== ""
  }

  // The user typed: rule 2, then a debounced search (rule 4 for the one before).
  input(term) {
    this.chosen = NO_SELECTION
    this.cancel()

    const trimmed = String(term || "").trim()
    if (trimmed === "") {
      this.callbacks.onIdle()
      return
    }
    this.callbacks.onLoading(trimmed)
    this.timer = this.setTimer(() => this.run(trimmed), this.debounceMs)
  }

  // A choice ends the search: nothing still in flight may reopen the list.
  choose(option) {
    this.cancel()
    this.chosen = { value: option.value, text: option.text }
  }

  // Close, or a new term: rules 3 and 4.
  cancel() {
    if (this.timer !== null) this.clearTimer(this.timer)
    this.timer = null
    if (this.controller) this.controller.abort()
    this.controller = null
    this.sequence += 1
  }

  async run(term) {
    this.timer = null
    this.sequence += 1
    const sequence = this.sequence
    const controller = new AbortController()
    this.controller = controller

    try {
      const response = await this.fetch(searchUrl(this.url, term), {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        signal: controller.signal
      })
      if (!response.ok) throw new Error(`Search answered ${response.status}`)
      const payload = await response.json()
      if (sequence !== this.sequence) return

      this.callbacks.onResults(parseOptions(payload), term)
    } catch (error) {
      if (sequence !== this.sequence || (error && error.name === "AbortError")) return

      this.callbacks.onError(error)
    } finally {
      if (this.controller === controller) this.controller = null
    }
  }
}
