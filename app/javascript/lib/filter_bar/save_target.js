// The target of a folder saved from a type condition (S7). Import-free, so
// node:test can pin it (spec/javascript/lib/filter_bar/save_target.test.js).
//
// A type condition is not a rule of the folder but its target_object_type,
// which is immutable: exactly one type with a target becomes it; two types,
// or one without a target (meetings), make a folder of all types.

export function targetForTypes(types, typeTargets = {}) {
  if (!types || types.length === 0) return null
  if (types.length === 1) return typeTargets[types[0]] || 'All'
  return 'All'
}

// Whether the folder will be wider than the condition said. The reader is
// told before the save (the modal's hint), not after.
export function typeWidened(types, typeTargets = {}) {
  if (!types || types.length === 0) return false
  return types.length > 1 || !typeTargets[types[0]]
}
