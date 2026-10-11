import test from 'node:test'
import assert from 'node:assert/strict'
// URL construction never uses the HTML encoder; its module allocates a div on import.
globalThis.document = { createElement: () => ({}) }
const { buildFilterUrl } = await import('../../../../app/javascript/lib/filter_bar/url_builder.js')

test('mobile filtering preserves the presentation but resets the page', () => {
  globalThis.window = { location: { origin: 'http://localhost', search: '?viewport=mobile&page=3&sort[column]=title&sort[direction]=asc' } }
  const url = buildFilterUrl({ baseUrl: '/tickets', filters: { status: ['doing'] }, operators: {}, searchValue: 'Rohr' })
  assert.equal(url.searchParams.get('viewport'), 'mobile')
  assert.equal(url.searchParams.get('page'), null)
  assert.equal(url.searchParams.get('filter[status][]'), 'doing')
  assert.equal(url.searchParams.get('search'), 'Rohr')
  assert.equal(url.searchParams.get('sort[column]'), 'title')
})

test('desktop filtering does not introduce a mobile presentation', () => {
  globalThis.window = { location: { origin: 'http://localhost', search: '?search=old' } }
  const url = buildFilterUrl({ baseUrl: '/tickets', filters: {}, operators: {}, searchValue: 'new' })
  assert.equal(url.searchParams.has('viewport'), false)
})
