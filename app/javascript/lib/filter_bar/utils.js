// Shared utility functions for the filter bar modules

const _escapeDiv = document.createElement('div')

export function escapeHtml(text) {
  _escapeDiv.textContent = text
  return _escapeDiv.innerHTML
}

// For double-quoted attributes. A backslash before the apostrophe would be
// read back literally from data-* (Kund\'s never equals Kund's), so the
// apostrophe becomes its entity like the quote does.
export function escapeAttr(text) {
  return String(text).replace(/'/g, '&#39;').replace(/"/g, '&quot;')
}

export function getOptionsMap(categories, key) {
  const cat = categories.find(c => c.key === key)
  const options = cat ? cat.options : []
  const map = {}
  options.forEach(opt => { map[String(opt.value)] = opt.label })
  return map
}

export function getCSRFToken() {
  const meta = document.querySelector('meta[name="csrf-token"]')
  return meta ? meta.getAttribute('content') : ''
}
