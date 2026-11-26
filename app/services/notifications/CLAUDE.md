# Map: app/services/notifications (as of 2026-11-26)

Processes OutboxEvents into Notifications. The full chain (Trackable → Activity → OutboxEvent →
OutboxConsumeJob → here) is mapped in `docs/architektur/seiteneffekt_ketten.md`.

* **Entry point: `fanout_service.rb`** (~535 LOC) — determines WHO receives a Notification.
  **DUAL-PATH:** Tickets = subscription-based (`NotificationSubscription` + user settings filter),
  non-tickets (Project/Document/Note/…) = score-based. Changes to recipient rules
  must ALWAYS check both paths.
* `score_calculator.rb` — priority score (non-ticket path only)
* `suppressor.rb` — suppresses duplicates/self-notifications
* `group_key_builder.rb` — notification grouping (`find_or_create_group`): when a row accepts an
  event (`can_add_to_group?`, `complete_post_group?`), lookup, keys, locking, creation.
* `row_events.rb` — **the single place** that changes `group_count`, `first_event_at` and `last_event_at` on
  an existing row, together with the event's actor and payload
  (`RowEvents.fold!`): locks the row, reloads it, rejects a read or archived row,
  checks the caller's rule (block) under the lock, only widens the span, and saves with
  `save!` (callbacks, signal). Returns true or false; if false, the builder creates a new row.
  **`last_event_at` is the arrival of the latest event** (since 26 November 2026), not its own time:
  `RowEvents.arrival(at:)` answers the time of the write, never before the event's own time; an
  event without a time of its own (`at: nil`) has arrived now. A fold asks the rule (and never
  moves the row's value back), and so does a new row (`GroupKeyBuilder#create_new_group`).
  `first_event_at` stays the earliest event's own time. Not closed: a row is stamped when it is
  written and visible when the fanout's transaction commits; the clock is the writing process's.
* `broadcast_service.rb` — in-app delivery via Turbo Streams. The “New notifications” banner
  (`notifications/_new_notifications_banner`, shared with the combined inbox) REPLACES the empty
  placeholder, in the recipient's language; until 13 November 2026, the text ended up inside the hidden
  placeholder and was never visible.
* `streams.rb` — the Turbo Stream names (`user:<id>:org:<org_id>:badge|notifications`).
  Publishers and subscribers build the name ONLY here; until
  29 September 2026, a name without an organisation caused org B's inbox count to appear on an open page of org A.
  **A third name without an organisation** (since S2a): `all_inboxes(user)`, only for the
  combined inbox. It carries only a stamp, never a count, a title or an organisation;
  no organisation page subscribes to it (`spec/requests/all_inboxes_live_spec.rb`).
* `unread_signals.rb` + `app/jobs/notifications/unread_signals_job.rb` — the dot on the
  organisation switcher: unread notifications in the OTHER organisations, counted by
  the same rule as the inbox (`Notification.inbox_unread`, also used by
  `User#unread_notifications_count`). Until 29 September 2026, only mentions and
  assignments counted, and the menu showed a smaller number than the inbox after switching
  (desktop, deliberately not mobile). Live updates send a separate version for each organisation on its
  badge stream. Triggered by the callbacks in `notification.rb` (`after_save` records the change,
  `after_commit` triggers delivery so that a second save in the same transaction cannot
  swallow anything) and by `Notification.bulk_transition!`. The job runs serially per user
  (`limits_concurrency`); otherwise, an older run overwrites the newer state. Matches
  beyond `NavigationHelper::ORG_MENU_LIMIT` count towards “All organisations”.
* `inbox_query.rb`: the inbox accessed through an access token (API and MCP), across multiple
  organisations in one query. It asks `Notification.readable` which rows count
  for each organisation, like every other counting location (via `accessible_for`). `meta.by_organisation`
  (since 2 October 2026) breaks down `unread_total` by organisation, including zeros, ordered by name;
  with a token for all organisations, these are the cockpit tiles. `organisation_id`
  (since 7 October 2026) and `project_id` narrow both the list and all counts; an inaccessible
  target raises `NotReachable` with the same response as a nonexistent one.
* **Order and date range of the web app's notification lists** (since 24 November 2026): Every list orders
  through `Notification.recent` (`last_event_at DESC, id DESC`) and narrows the date range through
  `Notification.active_in_period` (the day of the last event in the reader's time zone). The
  time displayed on a row is also `last_event_at`. No web app reader writes
  `order(created_at: …)` or `order(last_event_at: …)` by hand; the only location with its own
  `ORDER BY` is the representative of a bundle in `Inbox::MasterListPresenter` (`DISTINCT ON`
  requires it), using the same rule. The token inbox writes the same order in
  `InboxQuery#relation` itself. Two older renderings still display `created_at`; they are not
  lists governed by this rule: `NeoNotificationCardComponent` (broadcast partial) and
  `notifications/_notification` (response to `?partial=list`).
  Consequences: A row that receives an event (`GroupKeyBuilder` through `RowEvents.fold!`) keeps its
  `created_at` and moves up, also when the event is older than the row and arrives late. A row
  created late (an outbox event after a delay or after retries) stands at its arrival
  (`RowEvents.arrival`), so on top: in the web inbox as in REST and MCP, under the heading and
  inside the date range of the day it arrived, and the `since` cursor of the token inbox returns
  it. The representative of a bundle reads the same column: the row that arrived last stands for
  its ticket, also when another row of the ticket carries the later event. Rows from before
  26 November 2026 keep their time. `Posts::MarkRead` also finds comment rows
  by the span `first_event_at..last_event_at`, which now reaches further to the right: a row with
  `post_ids` is decided by its ids, and every comment row the fanout writes carries them (guards:
  `spec/services/posts/mark_read_spec.rb`, `fanout_service_ticket_simple_spec.rb`). The lookups in fanout
  (`group_key_builder.rb`, `fanout_service.rb`, `score_calculator.rb`) deliberately continue to use
  `created_at`.
* **The inbox above the organisations** (“Combined inbox”, `GET /inbox`, `AllInboxesController`,
  since 13 November 2026): the same list as an organisation's inbox, with the person's reach
  (`PersonalAccessToken::Reach.for_person`). It reads through `InboxQuery.reading`, filters
  and paginates with `Inbox::MasterListPresenter`, and renders with the partials from
  `organisations/notifications/` (one switch: `InboxHelper#inbox_above_organisations?`; since
  S3, a statement by the controller about the page, `page_above_organisations?`, rather than
  `current_organisation.nil?`; a fragment delivered into this page by an organisation controller
  reads it from the referrer; see `app/controllers/concerns/CLAUDE.md`). Both pages
  share the `_inbox_page` wrapper.
  ⚠️ The page has no tenant: everything a row displays is loaded inside the `reading`
  block (`presenter.load!`); lazily loading an association later raises `NoTenantSet`. It never sets
  the session's organisation; the filter is therefore called `org`, not `organisation_id`
  (which `ApplicationController#load_tenant_from_session` uses to read the tenant).
  **The lane above the organisations (S3, 14 November 2026):** a ticket row opens the organisation's entire lane
  on this page. `GET /inbox?...&notification=<id>` with `Turbo-Frame: ticket_pane` responds
  with only the lane: `Notifications::Selection` finds the organisation (each organisation under
  its own tenant); rendering runs in `ActsAsTenant.with_tenant` for that organisation, with it as
  the request's current organisation. The lane context belongs to the `InboxLane` concern
  (`app/controllers/concerns/inbox_lane.rb`), included by both inbox controllers; every
  rejection above the organisations (another person's row, hidden row, email row, organisation the person has left, no ticket) produces
  the same `pane_missing`. A full-page request renders the lane open and loads it in a separate
  request. Writes go to the organisation's routes; the session stays unchanged because it only
  follows pages (`full_page_request?`). The lane's header and 5-second timer use the row actions of
  `/inbox` (the response targets `#inbox_pane_status_pills` with the Notification ID, regardless
  of the referrer; delayed responses therefore cannot affect another lane;
  `quiet:` without a toast). The lane never removes tenant scoping and does not read through the token inbox. Guard:
  `spec/requests/all_inboxes_lane_spec.rb`.
  **What a row opens (S4a, 14 November 2026):** no longer “is it a ticket”, but
  `Inbox::LaneKind.for(notification)` (`app/services/inbox/lane_kind.rb`), the SINGLE owner of
  this question for both inboxes: loader (`InboxLane`), row (`NeoInboxMasterItemComponent`), page above the organisations
  (`render_lane`, `open_lane_head`) and row-action responses. The EVENT determines the
  kind, not the type: a notification belongs to a ticket or a PROJECT, and for a project the
  subject is `Activities::ProjectTarget.call(activity)` (the activity from
  `payload['activity_id']`). ⚠️ There is no notification attached to a note: no row ever satisfies `notifiable.is_a?(Note)`.
  Three answers: `:inline` (the ticket, rendered by the inbox as before),
  `:frame` (a subject with its own display, currently notes and documents (S4b): the lane holds
  `turbo-frame#ticket_display_frame` with the subject's frame URL as `src`, rendered
  by its own controller under its own policy; the inbox renders and copies none of that),
  `:card` (an event without a display: new member, permissions, deleted meeting; or the subject
  has been deleted or the activity removed by retention: a “no longer exists” card, never an empty
  frame). `nil` for a subject without an entry (person, time group, repository, old row attached to
  a note): the row leaves the page as before. The registry (`REGISTRY`, class →
  entry) is closed and fail-closed, never `constantize`. A new kind = one row there plus
  its audit (what the display requests and returns when embedded in another page).
  ⚠️ Known from the document audit, also on the activity page: “New version” and
  “Delete document” respond with a stream for `knowledge_display_frame`, which exists only on the
  knowledge page. In the lane, the form stays open or the deleted document remains visible until
  the row is reopened (then: the new version is visible or the “no longer exists” card appears).
  Same category: “Set as current” (stream for `knowledge_display_frame`) and “Delete
  version” (redirect to the display without `frame=content`).
  Fixed because it was wrong only in the `/inbox` lane: a version's “Text version” is a file
  and no longer changes the session's organisation (`DocumentsController#serves_pages?`).
  A version's preview adds `preview=` to the inbox URL and removes it again.
  The lane restores it on back/forward navigation and reload: through the
  authorized notification, then only through its document's versions (`InboxLane#inbox_lane_frame_path`).
  Missing versions or versions belonging to another document fall back to the document view. Version rows use
  `lane-link` and `_self` to determine their enclosing frame on click, including after a broadcast.
  `Inbox::ObjectFrame` builds the frame URL, also for a project's activity page.
  Permissions remain with the existing rules: the row through the notifications' policy scope (the event's
  area), the subject through `authorize target, :show?` in the loader; its controller checks
  again when loading the frame. Above the organisations, every rejection produces the same `pane_missing`.
  **Nothing is loaded per row:** `for` reads only the notification; the subject's title and name
  come from the payload (`Inbox::ActivityLine#object_title`, `#object_name`). The lane reads
  the activity and subject only under the row's tenant. A row for ONE event with a
  title in the payload shows that title; a bundle shows the project name. The lane redraws the open
  row with the same bundle size (`Inbox::MasterListPresenter.bundle_size`). “What was new”
  reads the unread notifications for the selected row's subject (ticket or project), still
  through the policy scope: an event in an area the person cannot read is not a
  row there. The lane header is ONE partial (`organisations/notifications/_pane`) around the
  kind's content. Guards: `spec/services/inbox/lane_kind_spec.rb` (also: every project event
  has an answer), `spec/requests/inbox_lane_kinds_spec.rb`, `all_inboxes_lane_spec.rb`.
  **Live (S2a):** after the switcher's dots, `UnreadSignals.call` sends
  a signal on `Streams.all_inboxes`: only `InboxQuery.stamp` (HMAC over ordered
  fingerprints of every in-app row within reach, including state and modification time).
  A maximum per state misses older writes that commit later.
  The page renders the same stamp
  with its list; if the signal differs, it fetches the counts (`GET /inbox` as turbo_stream,
  `part=counts`) and shows the banner. The list changes only when the banner is activated
  (`all_inboxes_live_controller`). `load_list` reads the stamp, counts and rows in a
  repeatable-read transaction; the request specs therefore use `:real_transactions`.
  The model trigger is broader than “unread
  yes/no”: every new row, every transition between unread, read and archived, a new
  event in a group (`last_event_at`), every deletion. **Row actions** (read, unread, archive, restore) have
  their own URLs (`PATCH /inbox/:id/...`) because every URL under `/org/:id` changes the session's
  organisation. `InboxQuery.row` finds the row (owned by the person, within reach, visible,
  otherwise 404); the policy and write run under the ROW's tenant. Writes go through
  `Actors::ChangeNotificationState`, the same actor as in an organisation's inbox: it
  includes the other notifications for the same subject (one ticket = one row), except for
  “unread”. The list state travels in the action URL, not in the referrer.
  **Bulk actions (S2b):** the organisation inbox's toolbar, on its own URLs
  (`PATCH /inbox/selection/{mark_read,archive}`, in `routes.rb` BEFORE the row's `:id` scope).
  Selection only: without IDs, 422; the page has no “all” option. Exceeding
  `AllInboxesController::MAX_SELECTION` (500) also returns 422. `selection.rb`
  (`Notifications::Selection`) finds the rows WITHOUT `without_tenant`: for each of the person's active organisations,
  it uses the notifications' policy scope under `with_tenant` (anything that is not an owned, visible
  in-app row there is silently skipped; the rest of the selection is changed). The entire bulk-action
  path, from lookup to write, therefore stays within tenant scoping; reading the LIST
  (`InboxQuery.reading`, `.stamp`, `.row`) still removes that scoping. The
  policy is checked under the tenant of every affected organisation. Writes go through
  `Actors::ChangeNotificationStates`, the same actor as the toolbar's IDs path within an
  organisation: one transaction across all organisations, ordered by their IDs, each
  under `with_tenant`; “read” changes only unread rows, “archive” only rows not already archived,
  so a repeated request changes nothing. **What a row includes and how locking works
  is defined once** in `subject_bundle.rb` (`Notifications::SubjectBundle`: visible
  in-app notifications for the same subject, ONE locking statement in ID order), for both the
  row actor and the bulk actor. The response reports the number of ROWS found (a ticket
  counts once) in the page's flash (`#flash`). The browser asks for confirmation before an action across multiple
  organisations (`inbox_bulk_select_controller`); the server does not require it.
  ⚠️ The path WITHOUT IDs within an organisation (bell dropdown, entire inbox) and
  `Api::V1::NotificationsController#mark_all_as_read` still write directly through
  `bulk_transition!`, without bundling and without locking.
  Guards: `spec/requests/all_inboxes_spec.rb`, `spec/requests/all_inboxes_row_actions_spec.rb`,
  `spec/requests/all_inboxes_bulk_actions_spec.rb`,
  `spec/services/actors/change_notification_states_spec.rb` (also `_concurrency_spec.rb`),
  `spec/services/notifications/selection_spec.rb`,
  `spec/requests/all_inboxes_live_spec.rb`, `spec/services/notifications/inbox_query_stamp_spec.rb`,
  `spec/system/all_inboxes_spec.rb`.
* **One counting rule for “unread in organisation X”** (since 2 October 2026): cockpit tile,
  badge, mobile navigation, bell dropdown, organisation switcher, inbox list and token inbox
  count through `Notification.inbox_unread` / `Notification.readable` (active projects the
  person can read, plus rows without a project). **Per area since 7 October 2026:** a notification
  for a ticket, note or document counts only while the person may read that
  area (`Notification::AREA_BY_NOTIFIABLE_TYPE`, a mapping also used by
  fanout, `gated_area_for`). **Since 8 October 2026, also notifications ABOUT THE PROJECT** (moved
  ticket, bulk change, new note, new meeting, new member): they count in their EVENT's area,
  `payload['action']` through `Activities::AreaRegistry`
  (`Notification.area_for(notifiable, action:)`, `.project_actions_by_area`). Project announcements
  (`project.updated`, etc.) apply to every area; an event without a rule applies to no one.
  Previously, a project notification applied to the entire project, and every member (automatically
  subscribed on joining) could read the titles and numbers of moved tickets through the token inbox.
  Everything else is checked against the whole project. ⚠️ A row WITHOUT a project counts as a system notification and
  always passes: this is why `ProjectDeletionJob` deletes notifications for a deleted project
  (since 8 October 2026; previously, it only cleared `project_id`, making hidden content reappear), and
  the `notifications:purge_project_leftovers` backfill cleans up old leftovers. Exception: an
  email row with a mail log remains without a project because a later bounce or
  spam complaint can find the person only through it (`EmailWebhookProcessorJob`,
  `EmailLog#check_and_disable_notifications`). It is invisible because EVERY inbox reader
  filters on `channel_in_app`: a new reader without this filter would display it. Guards: `area_rights_spec.rb`,
  `fanout_service_area_gate_spec.rb`, `project_event_area_spec.rb`,
  `spec/requests/api/project_event_notifications_spec.rb`. **Who receives a project event**
  (since 31 October 2026; previously only subscribers, because of a nonexistent area):
  everyone who can read the event's area, including account admins and roles with
  access to all projects, plus subscribers; project announcements reach everyone with
  any permission in the project (`Project#users_with_any_access`). The lookup has no
  `rescue`: if it fails, the event fails. This applies to every run:
  `OutboxEvent#process!` rolls back a failed run completely and then reschedules it, so the retry
  starts from scratch (guard: `spec/models/outbox_event_failed_run_spec.rb`).
  Users can disable each event type in their settings; a subscription in
  `mute` mode stays silent. ⚠️ For these recipients, this is inbox-only: an email goes out immediately
  at a score of 80 or higher, and no project event reaches that score without a subscription. To ensure this,
  `project.created` is a `project_announcement`, not a `system_message` (base score 80). A new event
  belongs in the table in `fanout_service_project_event_recipients_spec.rb`. **Every reader** (list, count,
  badge, dot) goes through `inbox_unread` / `accessible_for` / `policy_scope`, never through
  bare `user.notifications` or `Notification.where`: enforced by
  `spec/architecture/notification_read_guard_spec.rb` (exception list with counts per file,
  may only shrink). Until 7 October 2026, eight locations bypassed the rule. Before then there were four rules: the tile
  excluded archived projects, the badge and token inbox did not, and navigation and the dropdown did not check
  at all. Guard: `spec/services/notifications/unread_count_parity_spec.rb`. Every new
  counting location belongs there as an example. The set of projects is resolved **once per request**,
  per area (`Current.notification_source_projects`); a spec that changes access midway through an
  example and counts again simulates the second request with `Current.reset`.
* `update_preferences_service.rb`, `index_outcome_notifier.rb`

Important:
1. Event types/mappings live in `app/models/concerns/notifications/constants.rb` — always
   use fully qualified references in jobs/services (`Notifications::Constants::…`, thread safety).
2. Email delivery follows downstream: `EmailDeliveryJob` → `notification_mailer.rb` → `email_log`.
3. User preference checks go through the User facades (`app/models/user/notification_settings.rb`,
   via `delegate` in `user.rb`) — hot path; do not change signatures without checking fanout.
4. Testing pitfall: `after_create_commit` fanout fires unreliably in request specs —
   test fanout behavior directly through the service, not indirectly through the callback.
5. **Bulk state changes only through `Notification.bulk_transition!`**, never through a
   bare `update_all(state: …)`: `update_all` skips `after_commit`, leaving the dot on
   the organisation switcher incorrect until reload. Guard:
   `spec/models/notification_bulk_transition_guard_spec.rb`.
6. **Only `RowEvents.fold!` writes the event fields of an existing row.** A new writer
   calls it instead of setting `group_count`, `first_event_at` or `last_event_at` itself; the rule
   for the span (only widen it, since #274) is defined there once. On creation, the fields are set by
   `create_new_group` and `Notification#set_timestamps`; for `last_event_at`, `create_new_group` asks
   the same rule as a fold (`RowEvents.arrival`) and does no arithmetic of its own. A new writer of
   a row that carries an event does the same. Guard:
   `spec/architecture/notification_row_events_guard_spec.rb` (reads `app/` and `lib/` with Prism; its
   header describes what it cannot see). Locking is verified by `row_events_concurrency_spec.rb`.
