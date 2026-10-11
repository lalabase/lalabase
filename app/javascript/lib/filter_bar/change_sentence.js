// The sentence of the save row (F23): it names the change, never the place.
// Pure, so node:test can pin the wording rules; the HTML lives in save_row.js.
//
//   one removed   „in Arbeit" wurde entfernt.
//   two removed   „in Arbeit" und „wartet" wurden entfernt.
//   more removed  3 Werte wurden entfernt.
//   one added     „wartet" kam dazu.
//   more added    2 Werte kamen dazu.
//   both / op     Die Bedingungen sind geändert.

export function fill(template, values = {}) {
  return String(template || '').replace(/%\{(\w+)\}/g, (_, key) => (key in values ? String(values[key]) : ''))
}

// A label may come as { one, other } from the locale file, with a zero form
// where the count of nothing has a word of its own.
export function pickPlural(label, count) {
  if (label && typeof label === 'object') {
    if (count === 0 && label.zero !== undefined) return label.zero
    return count === 1 ? label.one : label.other
  }
  return label
}

export function changeSentence(change, labels = {}, labelFor = (_category, value) => value) {
  const names = list => list.map(({ category, value }) => labelFor(category, value))

  switch (change.kind) {
    case 'removed': {
      const values = names(change.removed)
      if (values.length === 1) return fill(labels.change_value_removed, { value: values[0] })
      if (values.length === 2) return fill(labels.change_two_values_removed, { a: values[0], b: values[1] })
      return fill(labels.change_values_removed, { count: values.length })
    }
    case 'added': {
      const values = names(change.added)
      if (values.length === 1) return fill(labels.change_value_added, { value: values[0] })
      return fill(labels.change_values_added, { count: values.length })
    }
    case 'changed':
      return labels.change_conditions_changed || ''
    default:
      return ''
  }
}

export function countSentence(count, labels = {}) {
  return fill(pickPlural(labels.condition_count, count), { count })
}

// The word of the "+ Filter" trigger when it stands as a sign (tight head,
// components/filter_bar.css): "Filter" with nothing set, "Filter · 1
// Bedingung", "Filter · 3 Bedingungen". NeoFilterBarComponent#filter_sign_title
// writes the same three forms for the first paint; this answers for every
// state render after it. Two writers on purpose, one locale key.
export function filterSignTitle(count, labels = {}) {
  return fill(pickPlural(labels.filter_sign_title, count), { count })
}
