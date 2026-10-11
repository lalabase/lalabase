// The difference the people menu of the ticket head sends when it closes
// (inline_assignees_controller): who got a tick since the menu opened, who
// lost one. Both lists keep the menu's order, so a request reads like the
// menu. A person ticked and unticked again stands in neither list: no
// difference, and the controller sends nothing.
export function assigneeDiff(shown, checked) {
  const before = new Set(shown || [])
  const after = new Set(checked || [])
  return {
    add: (checked || []).filter(id => !before.has(id)),
    remove: (shown || []).filter(id => !after.has(id))
  }
}
