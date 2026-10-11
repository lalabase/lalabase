// Shared a11y primitives for modal/drawer dialogs — used by help_modal_controller
// and contextual_help_drawer_controller (doc/kontexthilfe_drawer_plan.md, D3:
// share, don't copy). Import via the bare specifier "dialog_a11y" (pinned in
// config/importmap.rb) — NEVER a relative path: relative imports bypass importmap
// resolution and 404 on the undigested URL in production.

// Keep keyboard focus inside `container` while a dialog is open. Call from a
// document-level keydown handler; ignores everything but Tab.
export function trapTabKey(event, container) {
  if (event.key !== "Tab") return

  const focusables = container.querySelectorAll(
    'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), ' +
    'textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
  )
  if (focusables.length === 0) return

  const first = focusables[0]
  const last = focusables[focusables.length - 1]
  const active = document.activeElement

  // Focus on the container itself (tabindex="-1" panels right after opening) or
  // outside it: without this, Shift+Tab escapes the aria-modal dialog into the
  // page behind — redirect into the trap instead.
  if (active === container || !container.contains(active)) {
    event.preventDefault()
    ;(event.shiftKey ? last : first).focus()
    return
  }

  if (event.shiftKey && active === first) {
    event.preventDefault()
    last.focus()
  } else if (!event.shiftKey && active === last) {
    event.preventDefault()
    first.focus()
  }
}

// Announce a message to screen readers via a lazily created polite live region.
// One region per `announcerId` so unrelated dialogs don't overwrite each other.
export function announcePolitely(message, announcerId) {
  let announcer = document.getElementById(announcerId)
  if (!announcer) {
    announcer = document.createElement("div")
    announcer.id = announcerId
    announcer.setAttribute("aria-live", "polite")
    announcer.setAttribute("aria-atomic", "true")
    announcer.className = "sr-only"
    document.body.appendChild(announcer)
  }
  announcer.textContent = message
}
