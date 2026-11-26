# Map: app/javascript/controllers (as of 2026-11-24)

~109 Stimulus controllers, deliberately kept FLAT: subdirectories would change every identifier through
`eagerLoadControllersFrom` (`meetings/row_controller.js` →
`data-controller="meetings--row"`) — too much churn across ~145 `data-controller` locations in ERB.
The domain is encoded in the filename prefix (`ticket_*`, `time_session_*`, `meeting*`, `neo_*`).

Conventions:
* `neo_*` (~20) = design-system controllers (counterparts of the Neo ViewComponents).
  Unprefixed controllers are legacy or feature-specific.
* Wiring runs ONLY through `data-controller` attributes in ERB. To find controller→view: grep for the
  identifier (filename without `_controller`, underscores → hyphens). Beware:
  some mounts are built by joining Ruby arrays — a literal grep may falsely report “unused”.
* **After every creation/deletion/rename: run `rails importmap:auto_pin` and commit**
  (otherwise production precompilation breaks). NEVER run `rails stimulus:manifest:update` directly —
  see the root `CLAUDE.md`, “Critical Bug Fixes”.
* Guard: `spec/architecture/stimulus_controller_wiring_spec.rb` (no mount without a controller file,
  no action targeting a controller that no template mounts). ⚠️ When replacing a popup, lane or
  form, update its trigger too: Stimulus binds an action only beneath a
  mount and does not report a missing mount; the click then does nothing. This affected the ticket list's
  empty-state button until 2026.11.1 (lalabase/lalabase#259). A selector in a script
  (`[data-controller="x"]`) looks for a mount; it is not a mount.
* Modals: ALWAYS first read `docs/dokumentation/modal_pattern.md` and `README_MODAL_PATTERN.md`
  (in this directory). The reference implementation is `ticket_relation_modal_controller.js`
  (focus trap through `dialog_a11y`, close via backdrop and Escape, return focus to the
  trigger). `meeting_modal_controller.js` was deleted on 17 October 2026 (“New meeting” on
  “All meetings” opens in the lane), `time_session_modal_controller.js` on 16 September 2026.
  Its form has NO shared scope with the trigger: the modal is the content of a
  frame beside the section; both triggers are links with `data-turbo-frame`. Connecting means
  opening; closing clears the frame. Each opening carries its own ID (token): rejection and
  save target only that opening; a late response to a closed modal finds nothing. The
  focus-return target lives on the frame, not the instance.
  Another modal of the same shape inherits the controller instead of copying it
  (`participant_link_modal_controller.js`, since 27 October 2026: only the first field differs;
  `term_correction_modal_controller.js`, since 5 November 2026: focus on the “Correct” field, the count
  loads into its own frame; `person_takeover_modal_controller.js`, since 16 November 2026:
  focus on the target, the visibility sentence and duplicate question follow the selection; the
  trigger is in a `<details>` menu that the controller closes on opening (a click
  inside does not close it, Escape belongs to the modal), and focus always returns to “···”:
  to the button named by the frame (`data-person-takeover-return-id`, the card above the
  organisations, where ONE menu opens dialogs for several contacts), otherwise to the contact's
  button (`returnId`).
* `transcript_selection` (K4b, 5 November 2026): selecting transcript text shows “Correct”
  (above the selection, below it on phones where the system menu would otherwise appear). The button is
  a link into the dialog frame; the controller only keeps its URL current:
  selection, context and offset in CODE POINTS over the visible text
  (`lib/transcript_mark.js`, pin `transcript_mark`, Node tests). ⚠️ Never send HTML positions
  to the server: the page displays Markdown; `Meetings::TranscriptMark` locates the passage. Not mounted in the panel
  beside a ticket.
* `all_inboxes_live` (S2a, 13 November 2026): keeps the combined inbox current. Two targets each carry
  a stamp: `signal` (replaced by the `Notifications::Streams.all_inboxes` stream) and `drawn`
  (replaced with every list). The rule is pure (`lib/inbox_live.js`, pin `inbox_live`,
  Node tests): equal = nothing, visible = fetch counts + banner, hidden tab = fetch the
  list on return. After Cable reconnect/online, counts are reconciled with the server
  even if both local stamps match; `X-Inbox-Stamp` provides the
  current state. Requests are discarded on disconnect, new signals and row actions.
  Before the synchronous replace batch, the URL, list and targets are checked again.
  A page range that has grown in the meantime is fetched again. Transient errors are
  retried with increasing delays (at most 30 seconds) while the context remains valid.
* `inbox_master_item` (click on an inbox row): since S3 (14 November 2026), also opens the lane in the
  combined inbox; the `lane` value has been deleted, both pages behave identically (wide:
  load frame, write URL, open lane; narrow: full view within the organisation).
* `inbox_lane_head` (S3, 14 November 2026) and `pane_mark_read_delay` with `followAddress`: the header and
  5-second timer of the lane above the organisations write the PAGE's list state into their URL on submit
  (`listActionAddress` from `lib/inbox_live.js`, including infinite-scroll pages), but retain
  the open row and `quiet` from their own URL (a search removes `notification` from
  the page URL). The bulk toolbar (`inbox_bulk_select#_carryListState`) follows the same rule
  with its own copy; consolidate when next touched.
  ⚠️ The timer renders a response only if it still belongs to the lane that requested it (`disconnect`
  aborts the request; a closed lane, removed element and superseded request
  discard it). Above the organisations, it applies streams itself without Turbo's queue: the list only
  if the page URL, list element and action URL are still the same; the header through the
  selector with `data-notification-id`, thus never another notification's header. It understands only
  `replace`: if the quiet response contains another action, the entire response is discarded (server-side guard:
  “answers the timer with replace alone” in `all_inboxes_row_actions_spec.rb`).
* `inbox_bulk_select` (inbox toolbar, also in the combined inbox since S2b): retains selection
  across every redraw and newly loaded page. In the combined inbox
  (`followAddress`), two additional tasks, both on submit in `guardSubmit`: the form URL
  receives the list state from the PAGE's URL and the loaded pages
  (`redrawAddress` from `inbox_live`), because the toolbar is outside the frame reloaded by
  search, and its rendered URL may be older than the list. And if the
  selection spans more than one organisation (`data-organisation-id` on the checkbox), it sets
  `data-turbo-confirm` on the form with the count and names; Turbo reads the attribute only after
  the form's `submit` listener. No confirmation within one organisation.
  The list never moves by itself underneath the reader.
  ⚠️ Without a line in `config/importmap.rb`, a new controller loads in development
  (`pin_all_from`), but NOT in test or production; this initially caused a browser spec to fail.
* **Escape belongs to the topmost element** (`lib/escape_owner.js`, since 17 October 2026): Every controller
  that responds to Escape answers `ownsEscape()` (true while its next Escape closes
  something of its own). An overlay built by a script outside a controller carries
  `data-owns-escape`. The lane (`layout-toggle`) checks this in the capture phase on `window`,
  before any listener has run, and closes only if no one claims it. Previously,
  `layout-toggle` held a selector list, and every forgotten overlay closed the lane
  BEHIND it. Guard: `spec/architecture/escape_owner_guard_spec.rb` (also `keydown.esc->` in
  templates; closed `NOT_OWNERS` list with reasons). ⚠️ An `ownsEscape()` that remains true
  when nothing is open keeps the lane open forever: tie it to the state checked by
  its own Escape handler.
* `neo_autosuggest` has two modes: without `url`, it filters preloaded options in the browser; with `url`,
  it queries the server. Confirmed selection, request numbering, debouncing and cancellation live in
  `lib/autosuggest_search.js` (pin `autosuggest_search`, Node tests).
* ⚠️ No `#anchor` links on a lane page: they create a history entry, so “Back” is treated
  as a lane change and reloads the lane (losing the comment draft), and the hash spreads into URLs
  built from `window.location`. For jumps, use `scroll_into_view` (button, scrolls and
  focuses, URL unchanged).
* Lane history (`index_page` + `lib/lane/history.js`): an entry with a DIFFERENT path belongs to
  another page; Turbo restores its own entries. Otherwise, “link to project B, Back”
  aborted Turbo's visit and hit the 500-ms double-click protection in `application.js`.

Similarly named controllers — analysis 2026-07-13 (AI DX slice 5), NOT duplicates:
* `toggle` (generic reversible show/hide, targets `content`/`icon`, 13+ mounts) vs.
  `neo_toggle` (form switch with visuals + `relatedSelect`/`relatedInput`) vs. `reveal_more`
  (ONE-WAY reveal: shows `[data-more-item]` beneath its element + hides the trigger, no
  collapse) — three distinct purposes. From ONE source, `reveal_more` powers
  the sidebar's project “more …” (`neo_sidebar_project_item_component`) AND, since S5b (2 September 2026),
  the time list's status table, which collapses projects without recorded time
  (`time_sessions/_billing_overview_panel`). Org navigation (`_navigation_application`) no longer
  uses it.
* `clamp_toggle` is the FOURTH in this family and the only one with a preview:
  it shortens a long block to a preview height and expands it again. The
  clamping class comes from outside through the Stimulus Classes API, so it is content-neutral.
  ⚠️ **Do not wire its markup manually anymore** — since 4 September 2026, it belongs to
  `Neo::MarkdownPreviewComponent` (transcript, analysis preview, ticket summary).
  It shows the button only when the text actually exceeds the clamped height; a block
  that cannot be measured at `connect()` (`clientHeight === 0`, hidden lane)
  retains both clamping and button.
* `neo_price_interval` (public pricing page, `doc/billing_preisliste_rabatt_plan.md` §7.4)
  is NOT another `toggle`: it does not show/hide one element, but chooses **one of n**
  variants by `data-interval` — all server-rendered; it only flips `hidden`. The
  page is complete without JavaScript; rebuilding this as on/off loses precisely that
  property.
* `billing_form` (billing form, `doc/billing_stammdaten_plan.md` §9) is also NOT
  another `toggle`: it does not show/hide something on a button click, but derives which fields
  apply from the selected country. All lists and subdivisions arrive as
  `data-*` values from `Accounts::BillingRules` and the `countries` gem, never as copies in JS.
  Deliberately does NOT set `required`: the form must remain fully clearable (E3);
  server validation in the `:billing` context is authoritative.
* `dropdown` (targets `menu`/`button`) vs. `neo_dropdown` (target `trigger`, auto-close value,
  keyboard navigation) — both live. **Prefer `neo_dropdown` for new code**; migrate `dropdown` mounts
  opportunistically (Boy Scout). ⚠️ **Exception: an interface that must remain
  complete without JavaScript.** `neo_dropdown` shows its menu through JS, so without JS there is
  no menu at all. The time list's filter row (S7, `time_sessions/_filter_pill`) therefore uses
  `<details>` + `details_autoclose`: the period filter previously consisted of nine links and would otherwise
  have lost its no-JS behavior.
* Since S7, `details_autoclose` has **two** consumers: the navigation's organisation switcher and
  every time-list pill. Its `panel` target and `reposition` belong only to the first (they
  anchor to `#sidebar`); the pills mount it without a target and use only outside clicks and
  Escape. Everything in the `reposition` path checks `hasPanelTarget`; this must stay that way.
* `filter_menu_search` (S7) filters the already rendered links of ONE pill menu by
  typed text. Pure enhancement: without JS, the menu simply lists everything. The mount is
  literal on every menu, even without a search field — the wiring census reads mounts as
  literals and cannot see a condition built in Ruby.
* `project_cascade` was **deleted** in S7: its only mount was the time list's project picker.
  What it did (changing project clears both reference IDs) is now encoded in
  each menu option's URL, so it also works without JavaScript.
* `slim_select` (wrapper around the SlimSelect library) vs. `neo_select` — separate purposes.
* `ticket_selection` (8 September 2026, `doc/ticket_bulk_edit_plan.md` slice 1): ticket-list
  selection. State in `lib/ticket_selection.js` (pin `ticket_selection`, Node tests), mounted
  AROUND the header and list frame in `_index_desktop`, rerenders after every load.
  ⚠️ Listens for `turbo:frame-load` in the CAPTURE phase on the mount: on the ticket page, the
  event does NOT reach `document` (observed 8 September 2026; every other frame event does). Thus,
  the `document` listeners of `filter_bar` (`_hits` stays at the old value after
  loading), `column_picker` and `keyboard_navigation` are also blind. Cause unresolved, open
  finding, separate workstream.
* `ticket_bulk_panel` (slices 3 and 4): the lane panel, skeleton from the server, adds
  change rows from `<template>` elements, fetches current data (`bulk_summary.json`) after every
  selection change and communicates with `ticket_selection` through window events (`:ready`,
  `:close`, `:draft`, `ticket-selection:change`), because panel (lane frame) and selection
  (list column) live in different frames. `ticket_selection` preserves the draft (`lib/ticket_bulk_draft.js`, pin
  `ticket_bulk_draft`, Node tests) when switching between the panel and a ticket.
  `ticket_selection` intercepts the lane's close button in the
  capture phase on `document` while a selection exists. `execute` (slice 6) sends selection, draft and current-data digests as JSON to
  `bulk_update` (URL state in the query), renders the Turbo Stream response itself
  (`Turbo.renderStreamMessage`) and reports changed IDs as `ticket-bulk-panel:done`;
  `ticket_selection#afterRun` turns them into the new selection. ⚠️ Turbo applies a stream
  only on the next repaint: IDs come from the response text (`runTicketIds`), and
  `ticket_selection#onStreamRender` checks the new rows' boxes through the `render` hook
  of `turbo:before-stream-render`, not through `setTimeout`. Slice 7: the other
  actions below the button open native `<dialog>` elements in the panel (`openMove`/`openDelete`), fetch
  counts via `POST bulk_impact` (JSON body, as also used by `bulk_summary` since slice 7: 200 IDs
  do not fit in a request line) and respond like a run; `done` with `clear: true` clears
  the selection, and `ticket_selection` retains the result row without a selection until ✕ (`dismissResult`).
* `filter_bar` is the SINGLE filter bar (tabs, pills, save row; state comes from the
  URL, logic in `lib/filter_bar/change_set.js`). The frozen copy `filter_bar_legacy`,
  together with `lib/filter_bar_legacy/` and the user flag, was deleted on 7 September 2026.
* `sidebar_layer` (12 November 2026) is mounted on the sidebar (`<aside id="sidebar">`) of an
  organisation page and controls the account layer (`common/_account_layer`, assignment table F47):
  clicking one's own name slides “My account” up from the bottom to just below the logo,
  leaving the page behind it. It only sets attributes (`hidden`, `data-state="open"`,
  `aria-expanded`, `inert` on the covered content); the surface and motion belong to
  `components/sidebar_layer.css`. Close: name, cross, Escape (`ownsEscape()`), click
  outside, and `turbo:before-cache` (otherwise the layer reopens on “Back”).
  Without JS, the name links to the account page. ⚠️ The layout's stage is ONE
  grid cell and deliberately NOT positioned: the organisation switcher's menu attaches
  to the `aside` (`details_autoclose#reposition`). NOT another `toggle`/`dropdown`: it opens
  a layer over an entire area and disables what lies beneath.
* `preferences_autosave` (12 November 2026) is mounted on every section of the preferences page
  (`user_preferences/_section`): a change submits the section's form immediately
  (JSON), and the result appears beside the heading. If the server answers `reload: true`
  (different language, different session duration), the page reloads. Without JS, the button in
  `<noscript>` submits. `user_preferences` (date/time) supports it: a rejected format is marked
  invalid through `setCustomValidity` and is not submitted; a hidden row becomes
  valid again. Browser spec: `spec/system/preferences_page_spec.rb`.
* `page_outline` (12 November 2026) is mounted on a long page's jump list
  (`shared/_page_outline`, assignment table F46; currently preferences): the links are
  plain `#anchor` links; the controller only sets the marker (`aria-current="location"`),
  styled in `components/page_outline.css`. `lib/page_outline.js` decides which section is current
  (pin `page_outline`, Node tests): the last one above the
  reading line, the last one at the page bottom, and a just-selected section remains current while it is in view
  and no one scrolls manually (`wheel`, `touchmove`, `keydown`).
  ⚠️ Turbo follows a same-page anchor link itself and emits its own `hashchange`
  BEFORE changing the URL: read the target from `event.newURL`, never `window.location`.
  ⚠️ Not on a lane page (see above: use `scroll_into_view` there).
* Actual duplicates/dead code were deleted on 2026-07-13 (`sort`, `search_clear`, `search_input`,
  `permission_radio`, `neo_grouped_notification`, `.disabled` files) — the census guard
  reports new ones.

## Rich text (since inline images package 2, 2026-08-23)

Lexxy is the only editor; Trix has been removed from the importmap, JS and CSS
(guard: `spec/views/no_trix_guard_spec.rb`). Two controllers belong to it:

* `neo_rich_text_embeds` is mounted on `<lexxy-editor>` (attributes from
  `RichTextEmbedsHelper#lexxy_embed_editor_options`), listens for `lexxy:file-accept` and checks ONLY
  new files against the types and sizes from `RichTextEmbeds` (`lib/rich_text_embed_accept.js`,
  `node:test`). Rejected files go into the form's attachment field, found through
  a selector in the enclosing `form`. ⚠️ Never set Lexxy's own
  `permitted-attachment-types`: Lexxy also filters on LOAD and discards
  existing attachments.
* `neo_rich_text_zoom` is mounted on the wrapper of every rendered rich text
  (`layouts/action_text/contents/_content.html.erb`), never on the image: ActionText strips
  `data-*` from attachment partials. A delegated click on `a.attachment__zoom`
  (`lib/rich_text_zoom.js`) opens a native `<dialog>`; without JS, the link opens the
  large variant. Works in Turbo Streams because the listener is attached to the wrapper.
* `neo_writing_surface` (package 3) is mounted on the large ticket writing surface
  (`tickets/_writing_surface.html.erb`, rendered in `turbo-frame#writing_surface` by
  `tickets#new` and `#edit`; the empty frame belongs to the application layout so the list,
  dashboard AND inbox pane can reach it). ⚠️ Deliberately NOT `turbo-frame#modal`:
  `filter_bar_controller` revisits the page after every successful submit in `#modal`,
  and the URL still contains the previously selected ticket. It handles only the way OUT without saving: Escape and Cancel close
  an unchanged form immediately, otherwise `window.confirm`; clicking outside never closes it.
  “Changed” is a comparison of FormData snapshots (`lib/form_snapshot.js`,
  `node:test`), excluding transient fields such as `authenticity_token`. Saving is closed
  by the controller response's Turbo Stream `update('writing_surface', '')`, not by this controller.

## Assistant companion panel (S3a T4, 2026-08-24)

Two controllers, one reason for the separation: the panel sits at body level (it must, to be
`data-turbo-permanent` and escape the sidebar's `transform`/`overflow`),
while the sidebar row is in navigation. They therefore do NOT share a Stimulus scope.

* `assistant_panel` is mounted on the permanent node `#assistant_panel`
  (`layouts/_assistant_panel.html.erb`). Turbo TRANSPLANTS this node on every
  Drive visit, so the rule throughout is: state belongs on the node, not in the
  instance — Stimulus values (`open`, `width`) do exactly that because they are attributes.
  ⚠️ `disconnect()` fires on EVERY transplant, not only teardown: do not
  clean up there, and especially do not MEASURE (`scrollTop` reads 0 there; the node is already
  detached). ⚠️ A permanent node never sees the freshly rendered version — server-side
  changes to its attributes do not arrive; the path from server to node is the URL
  (`?assistant_chat_id=`, `honourRequestedChat`; likewise `?assistant=full`,
  `honourRequestedMode`). The same applies in reverse to the panel HEADER:
  it never knows which conversation the frame currently displays. This is why “Previous
  conversations” is a button, not a link — `showHistory` reads the open ID from the chat frame
  (`#assistant-panel-chat[data-chat-id]`, set by `ChatContainerComponent`) and builds
  the URL itself.
  ⚠️ Anyone adopting state from the URL MARKS that URL (`dataset.honouredChat`,
  `dataset.honouredMode`, `dataset.honouredArtefact`) — a morph refresh revisits the same
  URL and would otherwise undo a user's decision. Anyone WRITING it
  (`publishArtefactAddress`, `replaceState`) marks it at the same time.
* **Three states, ONE node** (S3c T2): Full view is a CLASS on the same node
  plus a grid inside, never a page — a page would take the draft, scroll position and ongoing
  stream away. The grid from `layout.css` is unsuitable (it lives in `<main>`); rules
  belong in `components/assistant_panel.css`.
* ⚠️ **A marker in the panel node is NOT unique.** `showHistory` asks whether the
  conversation list is already open, and must ask the CHAT FRAME, not
  `this.element`: since T2, the history lane renders the same component with the same
  `data-assistant-history` inside the same node. Visiting full view loaded the lane,
  the marker remained in the DOM afterwards (the lane is merely `display:none`), and the clock button did
  nothing until the next reload. Found in PRODUCTION, not in a test. When looking for
  a marker or ID here, query the surface that owns it.
* **`showSettings`** (gear, 30 August 2026) follows the same structure as `showHistory`: third
  state of the chat frame (`?settings=1`), `data-assistant-settings` as marker, and the
  open conversation travels as `?current=` so the return path lands where the gear
  was pressed. Without this parameter, the return path falls back to the panel default, the
  NEWEST conversation. ⚠️ A test for this is meaningful only if the target conversation is not
  itself the newest: otherwise, fallback and correct return are indistinguishable
  (observed, `spec/system/assistant_panel_spec.rb`).
* **The artefact lane** (S3c T3) is the third column, visible only when BOTH classes
  are set (`assistant-panel--full` + `assistant-panel--artefact`). A single delegated
  click handler (`handleClick`) handles both cases: a link with `data-assistant-artefact`
  opens the lane in full view instead of navigating, and every link that LEAVES the panel
  first collapses it back to the companion panel — otherwise, the page loads behind a
  full-screen panel and the click appears to do nothing (the defect shipped in T2).
  Links targeting a frame INSIDE the panel (`data-turbo-frame="assistant_panel_body"`)
  are exempt. ⚠️ The frame `src` is ALWAYS built from its own endpoint
  (`artefactSrcValue`) plus query, never from an entire URL value.
  ⚠️ `handleClick` exits immediately on ⌘/Ctrl/Shift/Alt and `button !== 0`. Both
  branches would otherwise be wrong: `preventDefault()` swallows the new tab, and
  collapsing hides the panel even though Turbo itself ignores modified clicks
  and the page does not navigate. The same applies to `#` anchors and `mailto:`/`tel:`.
* ⚠️ **`turbo_stream.update` does NOT fire `turbo:frame-load`.** The context offer
  (S4 T2 step 5b) needs to know which subject the page currently displays, and a
  frame-load listener almost never answers that: `#ticket_display_frame` has EIGHT
  writers, and exactly one (`list_row_controller`, sets a `src`) is a
  load. The rest are streams, plus two locations that assign `innerHTML` directly
  (`turbo_cache_controller`, and the Kanban expander on closing), firing
  nothing at all. Three review defects came down to this one fact. Hence
  a `MutationObserver` — **on `<main>`, not `document.body`**: the panel is a
  sibling of `<main>`, and an ongoing answer rewrites the conversation for each token,
  so a body-wide observer would run sixty times per second during every answer.
* **The offer lives in the FRAME, no longer in the shell** (27 August 2026). Its markup is
  `Neo::Chat::ContextOfferComponent`, rendered by `ChatContainerComponent`, ONLY
  for `PANEL_FRAME_ID`: it now sits directly above the row whose reference it intends to set,
  because no one looked at it at the panel's bottom edge. The cost is described above: anything the client
  writes into `assistant_panel_body` disappears on the next frame load. This is handled at
  the load event itself: `handleChatFrameLoad` checks again, TWICE:
  immediately and in the next `requestAnimationFrame`. Stimulus finds the targets of a freshly
  replaced subtree through a `MutationObserver`, a microtask AFTER
  `turbo:frame-load`; the first call may still address the detached
  node. Since 10 September 2026, the empty state also renders the offer. Without a saved
  conversation, accepted references appear in `DraftReferencesComponent` as visible chips
  and hidden form fields (`chat[reference_keys][]`). The permanent panel node
  preserves this selection across navigation; “New chat” replaces the form and clears it.
  `Actors::SaveChat` checks the collection through `Tools::Scope#references` and saves it
  with the first message before the response job starts. Errors rerender the message
  with the references that remain readable. While sending, the controller locks
  selection and further submits. With a Turbo Stream response, the old form
  stays locked until replacement: `submit-end` can fire before the response text is read.
  `offerTargetConnected` also renews the offer after a stream replacement.
  The conversation list and settings still render no offer.
* **`chat_scroll_controller` has two acts, and the second is new** (27 August 2026): the
  jump (the user's own question to the top) and then FOLLOWING, which keeps the end of
  the conversation visible as the answer arrives token by token. Both are armed only
  by the controller's own composer's `turbo:submit-end`, never by a broadcast.
  ⚠️ Detecting that the reader scrolled manually uses NO scroll listener: a
  programmatic scroll fires the same events as a real one; a stored
  position distinguishes them. The jump is therefore deliberately NOT smooth: an
  ongoing smooth scroll would have no reliable reference position, and following
  would overwrite it (the former grace period `JUMP_SETTLE_MS` no longer exists).
* **Showing the end on opening** (10 September 2026) belongs to the PANEL controller, not the
  scroll controller: `showTranscriptEnd` runs in `open()` and on the chat frame's `turbo:frame-load`.
  ⚠️ Not in the scroll controller's `connect()`: that fires on every
  transplant and would overwrite the reading position that `restoreTranscriptScroll`
  has just restored. Navigating with the panel open retains the position;
  every opening and conversation switch shows the end. If an answer is pending,
  resync reloads the frame on navigation anyway, and the fresh conversation
  then also shows the end (observed: a conversation whose last bubble
  carries `data-answer-pending="true"` is fetched again on every visit).
* ⚠️ **The permanent node dies on every page WITHOUT an organisation** (org switcher,
  account pages, admin, `/hilfe`): `assistant_available?` requires `current_organisation`,
  so the layout does not render the panel there and Turbo transplants nothing. But the listeners
  on `document`/`window` do not die with it; they keep the dead instance and
  detached subtree alive, one more per round trip. `disconnect()` cannot
  clean this up (a transplant fires it too), so listeners unsubscribe themselves
  (`releaseIfGone`) — only after a SECOND check in a later task, because a
  transplant briefly removes the node from the document.
* ⚠️ **There is no event for the result of a chip write.** `turbo:submit-end`
  fires before the stream has replaced the chip row, and a div replacement is not a
  frame load. Cleaning up too early offers the just-set ticket again;
  never cleaning up silences that ticket for the tab's lifetime. `settleAfterScopeWrite`
  therefore waits until the row REALLY changes, with a frame budget as fallback
  if it returns unchanged — exactly what a rejection looks like.
* **References form a COLLECTION, and its vocabulary is the key `<Type>:<uuid>`**
  (reference collection S1, 27 August 2026, `doc/assistent_bezug_sammlung_plan.md` §7.1/§8.3).
  The same value appears in the URL segment, form field, `data-reference-keys` on the chip and
  `dismissedContexts`/`refusedContexts`/`pendingContext`; meeting entry points additionally keep
  their unfulfilled intent in `pendingMeetingIntents`. The key is assembled
  in exactly two places:
  `assistant_trigger#adopt` from its two values, and `pageContext()` from
  `data-assistant-context` plus `data-assistant-context-type`. On the server, ONE owner writes
  both attribute sets: `AssistantContextHelper`
  (`assistant_context_attributes` for the marker, `assistant_trigger_attributes` for the
  button), since Knowledge renders them alongside Tickets (10 September 2026,
  `doc/assistent_wissen_kontext_plan.md`). ⚠️ `pageContext()` skips markers in a
  CLOSED lane (`.layout.hide-content`): ✕ hides the column through a class and
  leaves the content in place; otherwise, the just-closed note would remain offered. Thus,
  besides `<main>`'s child list, `observePageContent` observes the `class` attribute
  of the `.layout` node, and only that attribute. `standingReferenceKeys()`
  reads the whole string (which `settleAfterScopeWrite` compares);
  `standingKeySet()` answers the membership question. Writes use POST to
  `.../assistant_chats/:id/references`, removal uses DELETE on the key.
  A server REJECTION goes into `refusedContexts` (S2, §8.3); otherwise, the
  limit of 10 creates a loop: click, 422 “höchstens zehn” (“at most ten”), offer reappears. It is
  not inferred from an unchanged row, but read only from `success:false` WITH
  `fetchResponse` from the controller's own context form; a network error must not
  silence the reference for the tab. `settleAfterScopeWrite` still waits for the
  actually rendered chip row before reevaluating the offer and meeting intent.
  ⚠️ Multiple scope writes can cancel one another in Turbo. Therefore,
  `contextSubmissionsInFlight` counts per key already BEFORE `requestSubmit()`: only the last
  settle may clear `pendingContext` and `pendingMeetingIntents` or activate the mode.
* `assistant_trigger` dispatches a custom event on `window`: besides the reference, a
  meeting entry point optionally carries `analysis` or `ticket-suggestions` as intent. The panel
  controller fulfills it only once `Meeting:<uuid>` is visibly in the current collection.
  A second click on the same in-flight reference replaces only the intent;
  another `requestSubmit()` would cancel Turbo's first adoption request.
* ⚠️ While such a meeting intent waits for reference adoption,
  `guardPendingMeetingIntentSubmit` blocks only the message form. Other
  forms in the panel — accept/dismiss suggestions, retry a run, delete a chip or chat —
  remain usable. The guard listens in the capture phase, shows its
  `role="alert"` status from `ComposerComponent` in BOTH new and existing chats, and thus prevents
  a visible old task mode from accidentally submitting for meeting A
  while the entry for meeting B is still being checked.
* `assistant_suggestion_composer` (meeting migration step 3) adds a visible, cancelable task mode
  to the existing message field. The hidden
  `ticket_suggestion_meeting_id` field carries its intent; `assistant_panel` preserves it
  along with the draft during frame reconciliation. Targets come from adopted meeting references
  and an authorization-checked endpoint, never from the currently open page. An
  explicit meeting entry waits only while the specific fetch that can resolve that
  meeting is running. After an error, the intent is dropped and normal messages
  can be sent again; the visible retry button or the same entry point reloads
  the selection.
* `meeting_section_sync` keeps saved analyses and the shared suggestion list of the
  open meeting in sync with assistant cards. `assistant:analyses-changed` and
  `assistant:suggestions-changed` are only signals: the meeting page loads its own
  authorized rendering with `Turbo-Frame: meeting_display_frame`, coalesces
  events during an in-flight fetch and retries a transient error once.
  Only successful ticket adoption carries `refreshLinks` and also replaces the links list
  in the same fetch; start, completion and dismissal preserve any unsubmitted
  autosuggest draft there. A queued event must not lose this flag
  even if the first fetch fails.
* `assistant_suggestion_result` refreshes exactly one stored run through HTTP
  while panel, document and card are visible and the run is active (backoff up to
  30 seconds, at least 60 seconds on 429). Completed cards refresh explicitly
  or on return, with at least 60 seconds since the last fetch.
  Redocking resets the observer marker and triggers no fetch.
  A server digest includes action errors but ignores changing CSRF tokens. Before inserting a response, it rechecks visibility; if the card is hidden during
  the fetch, it remains `stale` and catches up immediately when next shown.
  `disconnect` aborts the request and invalidates old timers through a generation counter.
  Closed result surfaces receive no content. General chat resync
  skips these results so two polling paths do not refresh the same job.
* `glossary_run_poll` (K5b, 8 November 2026) reloads the glossary review list's frame every 5 s
  (value `interval`) while an extraction run is active. Mounted on the run bar INSIDE
  the frame: the fresh bar decides whether to continue (`active`). HTTP 408, 429 and 5xx
  are retried after 5 s while the bar is active and connected; 429/503 respect a
  valid `Retry-After` (seconds or HTTP date, at least the interval, within the
  browser timer range). Invalid values fall back to the interval. Network errors
  retain their existing retry cadence. Other HTTP errors, redirects and
  responses without a list stop polling; disconnect, inactive or removed bars prevent
  late responses from rendering or starting a timer. Hidden tabs send no requests.
  No broadcast; permissions remain in the view (same shape as
  `meeting_section_sync`, Node tests).
  Second caller since K5c (9 November 2026): the glossary button in a document's lane
  (`documents#glossary_source`), while text is missing or another run is active. Value
  `maxWait` limits the wait for text (10 min, including retries); the deadline lives
  in the outer frame's `dataset`, because each response replaces the controller itself and a deadline
  on the controller would restart at every `connect`. A fragment without `maxWait` (run active, text present)
  clears it again.
* The live node's boundaries are documented in `doc/persoenlicher_assistent_plan.md` §7.7.
  Briefly: org switching and global search use `turbo: false`, and
  `knowledge/index.html.erb` carries `<meta name="turbo-visit-control" content="reload">` —
  each path is a full reload and kills the node along with the typed draft. The
  cookie (`AssistantPanelState`) then restores geometry and open state.
  Guard against the return of the DEAD attribute variant:
  `spec/architecture/turbo_visit_control_guard_spec.rb`.
## Ticket-list column selection (7 September 2026, `doc/spaltenwahl_plan.md`)

* `column_picker` is mounted on the ticket-list wrapper (`tickets/index.html.erb`) and from there reaches
  the grid (target `grid`, class `column-picker-open`), the panel
  (`Neo::ColumnPickerComponent`, outside the list frame, survives every reload) and the
  trigger in the filter bar (`[data-column-picker-trigger]`, since 20a/S2; previously
  in the table header). `placePanel` decides whether the panel floats and writes
  `data-floating` on the panel itself — the stylesheet does not infer it from grid classes.
  Three tasks: open/close (Escape, outside click; slides through `column-picker-entering`
  on the grid, for one frame on opening and throughout closing; when floating, the panel sits 10 px
  beside the list, `placePanel`), measure **fit** (list width minus number and title, excluding the trigger cell,
  against minimum widths in ranked order; `data-fit` on `<table>`, boundary line at the same
  position in the panel; recalculated on every list-column resize and frame load), and **save every change
  immediately** (user, 7 September 2026: no draft): PATCH `cols[]` to the folder's
  or base view's `columns` endpoint, then `frame.reload()`. Only “apply to all views” is a
  separate step (form, `fillApplyForm`). Non-editable view: `editable=false`, no
  checkboxes. Pure parts without imports in `lib/column_picker/fit.js` and `order.js` (node:test).
  ⚠️ `applyFit` reads minimum widths from panel rows (`data-min`), or without a panel from
  `th[data-col-min]`; both come from `ViewConfiguration::COLUMN_MIN_WIDTH_PX`.
* `table_config`, `view_config_modal` and `filter_bar_legacy` have been deleted (7 September 2026):
  they served the legacy filter bar and its single-list modal, both now gone along with the
  `new_filter_bar?` flag. `smart_folder_display` has also been deleted
  (the expert form's column section is gone, D8).

- **`lane_split`** (Tickets AND Knowledge since 10 September 2026, key per context) — the boundary between list and detail lane, dragged by the handle on the
  dividing line. ONE value owns it: `--list-split` on the grid, read by BOTH the track and the
  handle so the handle cannot drift from the edge it moves. Stored as a
  PROPORTION (localStorage, per area), applied in pixels: a pixel width remembered from
  a large monitor leaves a phone-sized list on a laptop.
- **`list_row` on a row with its own controls** (17 November 2026, people above
  the organisations): the row is a `<tr>` with a checkbox and a menu. The row click
  skips only `a, button, form, .dropdown, .no-click`; a checkbox (`<input>` inside a
  `<label>`) and a `<details>` menu are neither, so their cell carries `no-click`;
  otherwise, checking the box opens the card. This row's DETAIL URL is the page's
  own URL (`/people?card=…`): the server recognizes the lane by its frame's header. Each
  row carries only its OWN address as `id` (the row's first source). Until the review
  of #197 (18 November 2026), the open row received the address-bar URL; search,
  however, redraws the rows without the card, so the row lost its highlight and
  clicking it reloaded the card instead of closing the lane. If the URL identifies the person
  through another source, `layout_toggle#renameResolvedSelection` rewrites it to the row's address in the SAME history entry
  (`renamedSelection`, `{ card: [requested, row_address] }`, from
  `all_people_renamed_lane_params`), and rows refresh their highlights (`lane:restored`).
- **A form with `data-lane-keep`** (18 November 2026): like a link marked this way, it carries
  the URL's lane state on click and submit, as hidden fields
  (`layout_toggle#keepLiveLane`), including a GET form whose own fields otherwise
  remain untouched. The “Merge” toolbar and organisation picker for people
  above the organisations carry it: opening the card changes only the URL; without this,
  merging or choosing another organisation closed the open card.
- **`list_row`** (`ticket_row` until 10 September 2026; `knowledge_row` was incorporated into it,
  `doc/wissen_als_bahn_plan.md` S2) is mounted on the ticket table row, board card
  AND knowledge row: one controller, three mounts. Values: `url` (the DETAIL URL
  loaded by the frame), `id`, `param` (its own selection parameter), `params` (ALL of the
  page's selection parameters, mutually exclusive), `frame`, `navigate` (meeting results leave the
  page). URL logic is pure in `lib/list_row/address.js` (node:test). The single
  highlight is `.selected-row` (same for server row and client). The URL is the source of truth (index + `ticket_id`, built
  from `data-index-url` on the container, found with `closest`), and every element highlights
  itself from the URL on `connect`; the highlight therefore survives any card or
  board replacement without “reapply after X”. `index_page` normalizes the deep link
  `/tickets/:id` to this URL on load (D7). `kanban_board` no longer opens anything
  (no `openTicket`); it handles dragging, keeps arrows current through a `ResizeObserver` and
  scrolls the selected card into view using rectangles (`revealSelected`, never
  `scrollIntoView`). `kanban_ticket_modal` has been deleted. ⚠️ The board listens for
  `turbo:frame-load` in the capture phase on `document`, for the reason described above under `ticket_selection`.
  ⚠️ Since then, the duplicate guard in `application.js` keys on method + target frame,
  not merely the URL: otherwise, the board's reload GET after “+ Ticket” would have been
  swallowed within the 500-ms window.
- **Lane in another list** (17 October 2026, “All meetings”, PR 3): the overview displays a
  project's meeting in its lane. `layout_toggle#syncFilterContext` passes list state
  only to links and forms under the page's index (`data-index-url`) AND under the index
  named by the lane header (`data-lane-index-url`, rule in `lib/lane/filter_context.js`,
  node:test). Without the second index, edit and save retained the filter from opening time. A
  deletion in the lane sends `closeLane` (application.js): `layout_toggle#closeLane` closes it
  and removes `meeting_id` from the URL in the SAME history entry. `list_address` has been deleted; the
  overview, like the project page, has ONE URL writer (`layout_toggle#syncUrlFromFrame`).
  In addition, `syncFilterContext` appends the `laneContext` value (for the overview,
  `{"list_context":"organisation"}`) to every request from the other list's lane, including links from
  broadcasts and section updates rendered without context. Otherwise, clicking
  “refresh” loads the lane in project mode, and the next save does not redraw
  the overview list.
  The URL names only what the server opened: a `meeting_id` it could not resolve
  or a `new` it did not render appears in `unresolvedSelection` (name and
  value, `meeting_list_page_data`). `layout_toggle#dropUnresolvedSelection` removes them from
  the URL on connect, before `hasSelection()` and `index-page` read them. Otherwise,
  a deleted or foreign meeting opens an empty lane.

## Mobile application (PR #807)

`mobile_shell` handles project switching (loaded as a lazy frame only on opening),
header tools and the selection header. `neo_mobile_nav` contains organisation destinations and
switches to the action bar in selection mode. `mobile_ticket_list` adds
long press and the native editor dialog to the central `ticket_selection`. The result
remains in the dialog while editing and in the list afterwards, including undo.

The breakpoint is `FULL_PAGE_BELOW_PX` from `list_row/address` (1024), not
`MOBILE_BREAKPOINT` (768) from the older lists. Only ticket requests receive the
viewport identifier. Header and footer are sticky; the document scrolls.
`viewport` is presentation state and belongs in `ADDRESS_NOISE`, not in the filter.
Close project dialogs before Turbo caching. The mobile assistant sheet
closes only on `turbo:visit`; clicks, canceled confirmations and
Turbo Stream write actions leave it open. Browser regressions run in `.github/workflows/guards.yml`.

On a full frame replacement, `ticket_selection` protects the existing page selection
throughout `event.detail.render` until after its DOM callbacks. A timer started
before rendering expires too early because Turbo may wait until the next paint.
