// The 768px boundary for legacy list layouts (Knowledge, Meetings, Help).
// Ticket full-page navigation and the application shell use FULL_PAGE_BELOW_PX
// from list_row/address; they deliberately switch at a wider boundary.
//
// The same decision is also expressed in one place JavaScript cannot import from:
//   * Tailwind's `md:` prefix (768px by default; config/tailwind.config.js does not override
//     `screens`) — used in ~109 views
//
// (A third place, the `@media (max-width: 768px)` rules in actiontext.css, is gone with
// Trix; see Paket 2 of the inline images, 2026-08-23.)
//
// Deliberate duplication across that boundary: if this value moves, Tailwind moves with it,
// otherwise the layout switches at a different width than the JS believes it does.
export const MOBILE_BREAKPOINT = 768
