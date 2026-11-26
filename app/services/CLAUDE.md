# Map: app/services (as of 2026-11-19)

**Entry-point convention for NEW services: `Klass.call(**kwargs)`** (class method; an
instance `#call` implementation behind it is allowed). Required: at least 1 comment line
above the class explaining what the service does. Read/query objects with domain verbs (`can?`,
`fetch_results`) are allowed as exceptions if the header declares the entry point —
exact marker: `# Entry point: <method>`. `#initialize` takes only keyword arguments.
Guard: `spec/services/service_convention_guard_spec.rb` (existing code is on a legacy allowlist,
shrink-only; anyone making substantial changes to an allowlisted file migrates it and removes it from the list.
Exempt subtrees with their own contract: `actors/`, `lalabase/tools/`).

**Writes**: nontrivial write → command object under `actors/` (contract: root `CLAUDE.md`,
“Actor pattern”, guard: `spec/services/actors/actor_contract_guard_spec.rb`). A trivial
single `update!` without side effects stays in the controller.

* An actor writes and checks no rights. Exceptions lock first and authorize again under the lock (`AcceptTicketSuggestion`, `StartTicketSuggestionRun`, `CorrectMeetingTerm`).
* A second exception spans two tenants: `TakeOverPerson` (People S0, 2026-11-16) asks `PersonPolicy#create?` under the TARGET's tenant, which only the actor opens, and reads the source through `People::Lookup` under the source's. ⚠️ A write into another tenant than the request's runs its whole transaction under that tenant (it overrides `with_actor_context`): commit callbacks (`Trackable`'s activity) run after `#perform`, and acts_as_tenant sets a new row's organisation from the thread's tenant.
* Finding belongs to one object per domain (`Tickets::ReadableForToken`, `Tickets::RelationAccess`, `People::Lookup`, `Glossary::Lookup`); they share the question, not code. Where `nil` would drop a limit, the keyword is required.
* The policy decides yes or no.
* The caller words the answer (status, text, 404 form).
* A guard holds where a mistake discloses data (`ticket_token_lookup_guard_spec.rb`, `ticket_relation_actor_callers_guard_spec.rb`).

Directory overview (selection):
* `knowledge/` — `lookup.rb` (`Knowledge::Lookup`, REST R2, 29 October 2026) is the SINGLE reader
  of a project's knowledge (notes, documents) by title, for the MCP tool
  `search_knowledge` and `GET /api/v1/projects/:project_id/knowledge`: permissions per type through
  `Pundit.policy_scope!` (no title or count for a type without read permission), merged pagination
  across two tables (`updated_at DESC, id ASC`, the same tie-break in SQL and Ruby), total count,
  serialization with the link from `Documentation::KnowledgeLink`. Without a search term, it lists
  everything readable (only REST uses this; MCP requires `q`). `.options(args, strict:)`: MCP treats
  unreadable values as defaults and clamps `per_page`; REST (`strict: true`) rejects them
  (`InvalidOption`, 422), pagination values through `ListPaging.strict_number` (rule and text for all
  strict lists). A new search rule belongs here; a new strict pagination rule belongs in
  `list_paging.rb`; neither belongs in a wrapper.
* `time_sessions/` — read objects for the time domain. `viewing_scope.rb` is the SINGLE owner of the
  “own or all times” rule (`:all`/`:own`/`:none` plus `#apply(relation)`), which
  `ProjectPolicy#area_access?(:time_sessions)` cannot express (`can_view_own ||
  can_view_all`). Fail-closed: only a PERSISTED `TimeSessionPermission` counts, not the
  unsaved default row from `User#time_session_permission_for`; since 27 September 2026, it also requires
  a live `ProjectPermission` behind it (`TimeSessionPermission.backed_by_project_access`,
  guard `spec/architecture/time_session_permission_guard_spec.rb`). Two entry points, ONE
  rule: `.call(user:, project:)` for one project, `.for_organisation(user:, organisation:)`
  for all projects in an organisation from ONE read of the permission rows (`#apply`,
  `#tier_for`, since 1 September 2026 also `#projects` and `#sees_anything?`: which projects and whether
  anything is visible at all; `time_session_navigation_service.rb` is now only a thin entry point in front of it, plus
  `#bookable_projects` for the write question `can_create_own`). Consumers:
  `TimeSessionPolicy::Scope`, the org-wide entry point of every list and every
  dashboard tile (since 30 August 2026; previously a second, handwritten copy of the rule that
  did not account for deactivated memberships), the tool
  `lalabase/tools/summarize_time_sessions.rb` (assistant and, since MCP 0.12.0, also
  `/api/mcp` in project mode, thus an entry point for every token), `subject_time_summary_service.rb`
  (hours chip) and `time_sessions/open_hours.rb` (`GET /api/v1/time_sessions/open`, since
  8 October 2026; previously, the API also exposed bookings hidden by the web time list). Anyone building
  another report on booked time goes through this, instead of writing the precedence rule
  manually for a sixth time. `bucket_totals.rb` is the
  second owner alongside it: aggregation into the three billing buckets, in ONE query,
  shared by `SummarizeTimeSessions` and the assistant's report panel — classification
  itself remains with `TimeSession.billing_bucket_for`. `booking.rb` (since 29 October 2026,
  REST R6) is the SINGLE rule for booking time through a token: the MCP tool
  `create_time_session` and `POST /api/v1/tickets/:ticket_id/time_sessions` both book
  through it (duration required, exactly one; `occurred_on` as a calendar day in the profile time zone;
  write through `Actors::SaveTimeSession`); wrappers check permissions between `parse`,
  `build` and `save`, and own refusal texts too. `date_bound.rb` is the
  third: the SINGLE answer to “is this a date boundary I may pass to
  the database?”. `empty_reason.rb` is the fourth: WHY the time list is empty. Drop-one, one
  `EXISTS` per active filter and only when the list is already empty; it determines “active” from
  the built SQL (`to_sql` comparison) rather than the parameters, so the rule is not duplicated
  alongside `TimeSessionFilterService`. All filters are AND conditions,
  so omitting one can only yield more rows: the page may promise what this object reports.
  ⚠️ `Date.strptime` alone is NOT enough — `%Y` accepts arbitrarily many digits and
  a sign; `999999999-01-01` is a valid Ruby Date and a
  `PG::DatetimeFieldOverflow` in the next query. The four-digit check must run BEFORE
  parsing; precisely this half was lost when the rule was copied into the report panel.
  Three more belong to the ticket table's time columns:
  `subject_billing_status.rb` folds ONE subject's buckets into one word
  (`:billed`/`:in_billing`/`:open`/`:mixed`/`:no_sessions`) — shared by the hours chip and
  billing-status column so they do not label the same ticket differently;
  `subject_totals.rb` is the batch counterpart of `subject_time_summary_service.rb`
  (minutes + status per ticket for an entire page in ONE query);
  `subject_totals_cache.rb` holds ONE reader's answers (`new(user:)`) in ONE request
  (page registered through `Tickets::LazyPagePreload`, loaded on first read per project of the
  tickets, like the subtask and waiting caches). ⚠️ Its fallback is the point: a row the
  preload never saw (single-row rerender via Turbo Stream after a save) is looked up
  INDIVIDUALLY instead of being zeroed — an empty cell is an incorrect number, not a
  missing one, and nothing about it looks broken.
  ⚠️ Vocabulary (since S1, 1 September 2026): ONE set of names. The subject's answer is a bucket from
  `TimeSession::BILLING_STATUS_FILTERS` as a symbol, plus `:mixed` and `:no_sessions`. The
  former translation `without_billing` -> `:open` (`BUCKET_TO_STATUS`) is gone. ONLY
  `time_billing_state_label` supplies the label;
  `SubjectBillingStatus.percent_billed` supplies the proportion. The words themselves live once under
  `views.time_sessions.billing_status.*`; guards:
  `spec/locales/time_list_billing_words_spec.rb` and
  `spec/architecture/billing_state_vocabulary_guard_spec.rb`. Do not add a second name —
  before S1 there were nine locations and five different German words.
* `activities/` — the activity-history access gate (S3b, §13-11). ⚠️ `area_registry.rb`
  maps by **`key`**, not `trackable_type`: there are only four Trackable types,
  and `Project` carries note, document, meeting, membership and permission events
  simultaneously. `visible_to.rb` attaches each row to its project (Ticket rows through
  a subquery, Project rows through `trackable_id`) and filters by area reach;
  `project_reach.rb` is the single-project adapter so the activity PAGE and the
  chat tool use the same gate. Fail-closed on every axis: unknown
  key, empty reach and no clause return nothing, never everything.
  ⚠️ `visible_to.rb` has a SECOND output: `reached_project_ids` owns the
  L7 coverage count. Deriving a history's coverage from ONE area
  (`coverage(area: :tickets)`) describes the wrong reach; observed: an answer from
  three projects beneath “Durchsucht: 0 von 3 Projekten” (“Searched: 0 of 3 projects”).
  The activity PAGE displays an event's subject in
  `turbo-frame#ticket_display_frame` via `src`. Since 14 November 2026,
  `inbox/object_frame.rb` (`Inbox::ObjectFrame.path`) builds this frame URL for both the page and the inbox lane
  (`inbox/lane_kind.rb`, what an inbox row opens; map in `notifications/CLAUDE.md`).
  No second `case target` list.
* `assistant/` — occupants of the artefact lane (S3c T3, plan §8.1). `panel_registry.rb`
  maps panel kind to panel class, **fail-closed** like `ContentAreaRegistry`: the kind
  comes from a URL users can type, so “unknown” is a production case. The
  controller renders the template using the REGISTRY's spelling (`canonical_kind`),
  never the parameter. `panels/time_report.rb` checks its own permissions — the
  area table cannot distinguish “own” from “all” for times (§13-9), so
  every `report` kind carries its own check.
  Meeting analyses in the assistant: `analysis_context.rb` records each answer's explicit
  meeting references, work instructions and source provenance, including conversation
  history; `analysis_sources.rb` checks source permissions on save and whether an analysis
  may be published to the target meeting. Incomplete source provenance blocks
  saving. `analysis_eligibility.rb` shares save rules between interface and actor
  and batch-loads save states in the conversation. `analysis_revision.rb` checks the
  explicitly selected answer reference; word prefixes do not trigger revision.
  `coverage_notice.rb` supplies the reach notice for chat and private analyses.
  Ticket suggestions: `Actors::StartTicketSuggestionRun` binds the request, meeting, project
  and checksums of separately capped notes/transcript to a `MeetingTicketSuggestionRun`.
  Sources are rechecked before the AI call and publication; deleting a chat removes
  the personal run but retains shared suggestions. `retried_at` permits only one
  retry per old request. Advisory locks prevent parallel job execution.
  `MeetingTicketSuggestionRun#mark_failed!` keeps failure state and flag release
  together; only meeting-page runs also write their error to the meeting.
  No personal conversation history enters these suggestions, which are visible across the meeting.
  Start and replacement lock the meeting first, like `AcceptTicketSuggestion`;
  dismissal is a conditional UPDATE on `open`. Result snapshots retain the IDs
  of deleted open suggestions as superseded history. Assistant results are
  refreshed only through authorized HTTP, never as content broadcasts.
  New runs use `Meetings::TicketSuggestionRunJob`; arguments of old
  `TicketSuggestionJob` and `ChatResponseJob` jobs remain compatible.
* `actors/` — command objects for writes (Tier-1/Tier-2 contract, guard-enforced). Fully
  on the seam: documents (`save_document`, `save_document_version`, `destroy_document`,
  `destroy_document_version`); time tracking/billing (phase 4 T1–T3, plans
  `doc/actors_phase4_plan.md` §9 + `doc/actors_t3_save_time_session_plan.md`): T1 assigner pair
  with shared write PORO `time_session_group_assigner.rb`, T2 billing/descriptions,
  T3 `save_time_session` (create+update including group change in ONE transaction); chat (C1, plan
  `doc/actors_c1_chat_plan.md`): `save_chat`, `destroy_chat`, `create_chatpost`,
  `regenerate_chatpost`, `set_chat_style`; `save_assistant_analysis` copies a completed
  answer owned by the user, under a row lock, into a private meeting analysis without search visibility,
  with a source snapshot and unique answer key to prevent duplicate saves; no new
  AI generation. Price versions (`publish_price_list` here, `withdraw_price_list` in the
  `gboyke/lalabase-operator` engine since S3.2; `publish_price_list` remains because the core owns the rule and
  the console calls it) —
  **both WITHOUT `current_user`**, because the admin operator is a `Beuser` and `Current.user`
  expects a `User`; auditing uses an email snapshot on the row. In both,
  ORDER matters (clip the predecessor BEFORE creation, delete the announced version BEFORE
  reopening) — the reverse order makes the overlap rule reject its own write.
  AI access: `save_ai_configuration` **and** `remove_ai_configuration` (AI area S7,
  complete). Both connect to `Organisations::AiConfigurationsController` — the dedicated
  setup screen, no longer `AiSettingsController#update`, whose write route
  has been removed without replacement. ⚠️ Three non-obvious rules: columns distinguish
  **absent = retain / empty = delete**; only `ai_access_token`
  is retained even when empty (E2-A, the key is never sent back); changing the
  **provider or endpoint** requires reentering it, because a retained key plus
  a writable `ai_api_base` would otherwise expose it (reason:
  `doc/ki_bereich_navigation_plan.md` §E2a); and the endpoint gate belongs to `Lalabase::PublicAddress`: it resolves the name
  and evaluates the **destination addresses**, never their spelling. It broke three times over precisely this
  confusion (IPv4-mapped IPv6 literals, numeric notations such as `127.1`, then
  names: `localhost.`, `redis.`, public names resolving to internal addresses). On save,
  it is only a convenience; protection comes from `Lalabase::Llm::PublicEndpointAdapter`, which checks again on every
  connection and binds the socket to the checked address. Only the endpoint
  named by an `AiCredential` is trusted (`Factory#operator_endpoint?`).
  Glossary (K4a, 4 November 2026): `save_glossary_term` (create/update, manual entries always
  `confirmed`; losing a race on the unique index yields the same rejection; `lock_version`
  like `save_person`, since the lock alone reloads the row and did not protect it),
  `set_glossary_term_status` (confirm/dismiss only, never propose),
  `destroy_glossary_term`, `destroy_heard_form` (a heard form with ALL its
  corrections on the term), `merge_glossary_terms` (locks both rows in ONE query ordered by
  ID, heard forms move to the target, target retains spelling, category and
  status). The caller resolves the target through the policy scope. ⚠️ ONE lock order:
  every glossary write locks the term first (`glossary/term_lock.rb`, a term that has disappeared
  is `not_found`); the reverse order made delete and merge block each other.
  K4b (5 November 2026): `correct_meeting_term` corrects a word in the transcript and learns it
  for the glossary. Order: lock meeting (`lock_in_project!`), `MeetingPolicy#update?` under
  the lock, digest (different = `:stale_transcript`, nothing written), location only as an actual
  match, write through `SaveMeeting` (`keep_summary: true`, the SINGLE summary
  exception), THEN the term (`TermLock`; concurrently created = found, not
  rejected). Status follows `GlossaryPolicy.manage_allowed?`: confirmed with permission, otherwise proposed,
  including on a confirmed term. `confirm_heard_form`/`reject_heard_form`: confirm or delete the
  open rows of a form (confirmed rows remain). When confirming a PROPOSED term,
  `set_glossary_term_status` also confirms its open forms.
  K5a (8 November 2026): `import_glossary_terms` reads a pasted list (`term` or
  `term;category`, at most 500 nonempty lines; category as key or German/English display name).
  Duplicates by `GlossaryText.normalize`, existing terms of every status skipped (dismissed terms remain
  dismissed); confirmed with `manage_glossary`, otherwise proposed (`GlossaryPolicy.manage_allowed?`, as in K4b).
  The preview dry run uses the same code in a savepoint that is rolled back
  (`requires_new: true` enables this). First the categories of existing terms under
  row locks (ONE query ordered by ID, reread under the lock), THEN new terms ordered by
  their form: the import never waits for a term lock while holding index entries for new terms
  (the reverse deadlocks with a rename, review round 1 of #128). `Line#category_applied` says whether a
  row's category is applied; only then does the preview show it. The caller reads `#report` after `.new(...).call`.
  If a category is to be set and the normalized spelling has changed in the meantime,
  the whole import is rejected with `:stale_object` (HTTP 422); previously added categories roll back too.
  When the normalized spelling is unchanged, the report takes status and verdict from the locked
  row, even if it now has a category and therefore remains unchanged.
  Runs entirely under its organisation's tenant (`ActsAsTenant.with_tenant`, like `Glossary::Lookup`), regardless
  of the caller's tenant. Splits term and category at the first `;` or tab, before sanitizing;
  a line also ends at VT, FF, NEL, U+2028 and U+2029 (review round 2 of #128).
  K5b (8 November 2026, extraction): `start_glossary_extraction` (organisation row lock, a
  stuck run ends as `failed`/`stale`, ONE active run), `accept_glossary_proposal`,
  `merge_glossary_proposal_into_term`, `merge_glossary_proposals`, `dismiss_glossary_proposal`
  (also restore). Term before proposal, never the reverse; `manage_allowed?` under the lock; the
  claim is ONE `update_all` with a status condition (`status = 'open'`, on restore
  `'dismissed'`); merging locks two proposals in ONE query ordered by ID.
  K5b round 2: `merge_glossary_proposal_into_term` accepts only a confirmed term under the lock
  (`:term_not_confirmed`, after authorization); `merge_glossary_terms` attaches proposals accepted into the source
  to the target, under both locks; `merge_glossary_proposals` retains the target's hint and
  `hint_sources`, even if trimming to `MAX_SOURCES` removes its own example passages. Its display
  checks the full model-call provenance independently of these examples.
  Second review, 9 November 2026: when confirming a PROPOSED term, `accept_glossary_proposal` also confirms its open
  heard forms (`GlossaryTerm#confirm_open_forms!`, shared with `set_glossary_term_status`), so both paths
  to “confirmed” provide the device with the same forms; a dismissed term retains its open forms.
  The glossary page calls them from `Organisations::GlossaryController` (review list, `?view=proposals`).
  Registration (website separation W2, 15 September 2026): `create_signup` is the SINGLE
  self-registration flow for the form and later the provisioning endpoint. Tier 2: locale
  and tenant-free context surround the entire run (the confirmation email renders on
  commit); user and own organisation commit **together or not at all** (decision
  D2). Subsequent steps that must never undo registration (tutorial,
  acquisition source, founder application, audit) live in `signups/follow_ups.rb`, because their
  `rescue StandardError` is forbidden in the actor. Invitations do NOT go through this path.
  `signups/handoff.rb` owns the one-time sign-in link issued by the provisioning
  endpoint: purpose, expiry (2 min) and single use in ONE place, because a producer and
  consumer that disagree about these each look correct on their own. The gate
  is `User#claim_first_visit!` (`UPDATE ... WHERE last_seen_at IS NULL`); the app does
  not use Devise `trackable`. ⚠️ Host from `ActionMailer::Base.default_url_options`, not
  the config object: that is empty under RSpec.
  `signups/taken_address_brake.rb` (15 November 2026) counts “address taken” responses per
  client IP address: after 5 in one day, registration is closed for that address for one day
  (429 from Rack::Attack, rule `signup_taken/ip`, before both entry points). Counting happens in the actor,
  so `client_ip:` is required there; `nil` counts nothing (the website did not identify a
  visitor). ⚠️ At the provisioning entry point, never count or block the website's address.
  The response itself stays the same: a new account is signed in immediately; an existing one never is.
* `meetings/` (selection, K4b, 5 November 2026) — `term_replacement.rb` is the SINGLE rule for counting
  and replacing a heard form (whole words under Unicode, NOT `\b`; case as selected;
  multiple words only within a line; never in the speaker label, whose rule
  `speaker_markup.rb#label` shares with bold formatting; never in frontmatter). `#occurrences` feeds
  both dialog and replacement; invisible characters (`GlossaryText::INVISIBLE`) connect like a letter.
  `transcript_mark.rb` finds a browser selection in the STORED transcript: the page's text
  comes from the same rendering (`MeetingsHelper#meeting_transcript_html`), nth match there =
  nth match in storage. ⚠️ Equal counts are not proof (hidden link target, generated entity):
  the match is rerendered with a marker at its position and accepted only if the marker
  lands exactly at the selection (review round 1 of #121), otherwise rejected. A form changed in the dialog
  receives the same proof (`#place_of`), and “everywhere” is available only if the page remains
  unchanged with a separate marker for EVERY match (`#everywhere?`, round 2): a match
  in a link target permits only “only here”. `term_correction_dialog.rb`
  defines what the dialog displays (location, count, speaker, digest), shared by `new`, `count`, `create`.
* `glossary/` — `term_lock.rb` (lock order for every glossary write, see `actors/`) and
  `lookup.rb` (`Glossary::Lookup`, K4c, 6 November 2026), the SINGLE reader of an organisation's glossary
  for `GET /api/v1/organisations/:id/terms` and the MCP tool `get_glossary`: permission
  (`#allowed?`, checked again by `#read`: `Refused`), `.for_token` (an organisation within
  reach, its projects as the boundary for heard forms; nil for out of reach, missing, malformed;
  `Refused` for a deactivated member of an organisation named by the token), only
  effective entries (confirmed terms, `TermCorrection.effective`), `project_id` first (`NotFound`
  if outside the permitted scope), speakers only with people permission through `People::Directory#entry_for_participant`,
  pagination (`InvalidArgument`). Sets the tenant itself. A new rule for this response belongs
  here, not in either entry point.
  K5b (8 November 2026), proposal extraction: `word_lists.rb` (`common` = the two
  50k lists, PostgreSQL stop words read at runtime with fallback, and our
  `EXTRA_COMMON_WORDS`; `stop_words` alone is a subset), `candidate_scan.rb` (the filter without AI,
  streaming; at most `MAX_GROUPS` keys (20,000, about 30 MB): at the limit, first drop all keys seen in only one source; if that does not free a quarter of the space, also drop the weakest by rank; new keys are always admitted, otherwise a few large texts would stall the filter (review round 3 of #129); trimming sets `truncated`; per key, only counters, at most `MAX_FORMS` spellings and at most `MAX_SOURCES` excerpts; a
  name of two or three capitalized words never starts or ends with a stop word),
  `classifier.rb` (one chat call per batch of at most 60 on `:glossary_extraction`, the
  organisation's own tier; gate first; response checked against what was sent;
  records its own usage; `Failure` with a run error code), `extraction.rb`
  (initiator's reach at runtime per area plus each type's policy scope; comments
  only through `public_posts.readable_by`, even for admins; no meetings; the newest `MAX_SOURCES`
  across six types; incremental from the start of the last successful run; open proposals
  receive occurrences, spellings and passages instead of a model call; writes per batch;
  every write touches the run under `status = 'running'`). Open proposals take none of the
  `MAX_CANDIDATES` slots; a proposal receives only occurrences from new passages; each text is at most
  `MAX_SOURCE_CHARS` (cut between words), and the run is touched before every loading batch. Only a reader who can currently read every source
  of the entire model call sees the model's hint:
  `hint_sources` retains their types and IDs, including for rejected candidates, independently of the
  proposal's example passages. Old hints without this provenance remain hidden; on
  merging, the source's hint does not move, and the target hint's provenance remains.
  `run_heartbeat.rb` (9 November 2026) touches the run from a separate thread every `STALE_AFTER / 5` while the
  model call is running (a provider call may outlast `STALE_AFTER`; a run ended as `stale` during it
  would be paid for twice); only under `status = 'running'`, never in memory; a failure is logged.
  `Glossary::ExtractionJob`
  (`app/jobs/`): advisory lock, ONE claim, `interrupted`, `internal_error`, no retry.
  `Glossary::GoneSourceSnippetPurgeJob` (`app/jobs/`, daily at 04:50, `config/recurring.yml`): clears the
  excerpt of a passage whose source no longer exists (one UPDATE per type, NOT EXISTS against that type's
  table), and a proposal's hint once any source of its model call is missing or the provenance
  is empty or unreadable; rows remain.
  K5c (8 November 2026): kind `document` reads only the named version, in full, without a limit; start (`document_version:`) checks read permission, current version and text under the lock.
* `object_links/` (16 November 2026) — object links in rich text as chips, only on display
  (stored text remains a link). `address.rb` reads a URL through the router
  (page and lane parameters, own hosts and current organisation only), `targets.rb`
  loads targets per type through the policy scope or `People::Directory`, cached per request
  (`Current.object_link_targets`), `chips.rb` replaces links in the ActionText layout
  (`ObjectLinksHelper`) and preloads for lists (`.prefetch`, timeline). A broadcast
  during a request displays no chips (`config/initializers/object_link_render_guard.rb`).
  New type: entry in `Address::PAGES`/`LANE_PARAMS`, loading in `Targets`, permission spec.
* `people/` — `directory.rb`, the people list's read object (since 26 October 2026): members
  through `MembershipPolicy::Scope` (same reach as the members page), plus
  rows without an active member as contacts; search in Ruby through `PersonName.normalize`.
  Permissions only through `PersonPolicy`, no separate rule alongside it. A member's email
  (row below the name, search, card in `lookup.rb`) is always `User#shown_email`: a
  hidden login address is neither displayed nor searched (29 October 2026).
  `contacts.rb` (S2a, 26 October 2026): a person's meetings (`person_id` OR the member's
  `user_id`) and “Last contact” for an entire list in a fixed number of queries. Readable only through
  `MeetingPolicy::Scope`, `TicketPolicy::Scope`, `Post.readable_by` and `Activity.feed`; for
  active members, their own ticket work counts (`TICKET_ACTIONS`: created, updated,
  commented); for contacts, only meetings. `Directory#entries` attaches the last contact and
  sorts by `name` or `last`.
  S2b (27 October 2026): `Directory#person_entry`, `#entry_for_participant`, `#candidates`
  (search without last-contact data) and `#suggestions_for` (same name before same surname, E6)
  feed the “Link to person” dialog. Its rules live outside the helper,
  individually testable: `meetings/participant_link_options.rb` (dialog rows),
  `meetings/participant_link_choice.rb` (the `person:`/`member:`/`new` format, defined once),
  `meetings/account_participants.rb` (whom the dialog leaves alone). The line below a
  name is `Directory::Entry#detail` (list and dialog). Writes go through
  `Actors::LinkMeetingParticipant`, which resolves every ID through the locked meeting and the
  writer's directory.
  S3 (28.10.2026): the assistant's `find_people`/`get_person` read only through this
  directory (`#entries`, `#person_entry`, `#member_entry`); `#last_contacts_for` gives the
  card of one entry the last contact the list attaches to every row. Map:
  `lalabase/CLAUDE.md`.
  S3b (29.10.2026): `lookup.rb` (`People::Lookup`) is the ONE read of the directory outside
  the page, for three adapters: the assistant's two tools, their MCP twins and
  `Api::V1::PeopleController`. It owns the rights question (`#allowed?`, asked again by
  `#find` and `#entry` before anything is read: `Refused`), the search (the Directory's, with
  `kind` checked instead of read as `all`: `InvalidArgument`), the id format and the ONE field
  selection (`.row`, `.card(entry, notes:)`; `notes: true` only on the REST card, S3b E2), and
  `.for_token` (E1: only an organisation whose every project the token reaches,
  `Reach#project_ids_for(id).nil?`; else nil, so a project-limited token, an organisation
  outside the token and a missing one look alike). The caller sets the tenant (the MCP twins
  and the controller do, before `authorize Person, :index?`); paging is the REST
  controller's (50, at most 100, a value outside refused).
  S0 (2026-11-16): `Actors::TakeOverPerson` copies a contact (a row with `user_id` nil, no
  member, no deactivated member's row) into another organisation of the viewer: the source
  through `Lookup#entry`, the target from `active_organisations` (`.targets_for` is the
  dialog's list, same rule), values only from the source row filtered by `FIELDS`, notes only
  ticked, `Directory#duplicates_of(source_row)` in the target unless the request confirmed for
  that same target, under an advisory lock on target and name (two takeovers at once ask
  instead of both writing). One refusal (`:not_found`) for every case; the target records nothing of
  the source.
  The people above the organisations (16.11.2026, `GET /people`): `across_organisations.rb`
  (`People::AcrossOrganisations.call(viewer:, query:, org:, page:)`) is the ONE read of a list
  over several organisations. It walks `viewer.active_organisations` and reads each inside
  `ActsAsTenant.with_tenant(organisation)` through `People::Lookup#listing` (new: every
  entry, the matches of a search and the last contacts of a given list from ONE
  `People::Directory`), skipped unless `#allowed?`. ⚠️ No read with the tenant lifted, in no
  file of the feature: `spec/architecture/people_above_organisations_guard_spec.rb` names
  the files, merging rows and the card added their own. A reference is not a
  right: an organisation without the people right contributes nothing and is not named,
  and as `org` it answers like an unknown one (`UnknownOrganisation`, a 404 in the
  controller). Member entries with the same account are one row (computed, never stored); a
  contact is always a row of its own. A search match on one entry shows the whole person.
  The page is cut after the merge (50), last contacts are read for the rows shown only.
  Plain values leave (`Row`, `Source` with the hash of `Lookup.row`, never `.card`: of the
  card only its count leaves, `Source#value_count`), no `Person`: the view runs without a
  tenant and must have nothing to load from. The one
  record is `Row#avatar_user` (`User` is not tenanted). The loop per organisation is
  declared in `spec/support/prosopite.rb` (`in_people_organisation`); what that could hide,
  a read per row, is pinned by a statement count in the service spec.
  Merging (2026-11-17): the read joins the viewer's own merges (`PersonGroup`, card of
  `app/models`) on top of the account rule. ⚠️ A reference is not a right: a part the
  viewer cannot see just now is not shown and not counted, and nothing is written while
  reading. `Actors::MergePeople.call(entries: [{ org:, id: }], current_user:)` and
  `Actors::SplitPerson.call(group_id:, current_user:)` act on the PEOPLE THE LIST SHOWS,
  asked of the read itself (`AcrossOrganisations#part`, `#person_with`, `#names?`,
  `#merges_shown_with`), never on the stored lines alone: a line the list does not show
  must not refuse a merge, and undo takes apart every group that joins the row. One
  refusal for everything the caller cannot name (`:not_found`). ⚠️ `entries` are the ROWS:
  a row of several organisations is a list of sources, and fewer than two rows are refused
  however many sources they hold (the controller keeps the rows apart). `Actors::TakeOverPerson`
  writes the merge of source and copy in a savepoint (the copy stays either way:
  `:not_merged` when the source stands merged with a row of the target already,
  `:merge_failed` for any other reason, and only the first notice names a reason);
  `PersonTakeoversController` offers "merge instead" under the duplicate question.
  ⚠️ Those offers are submit buttons above the main button: the form opens with a default
  button that is drawn (`sr-only`), never `hidden`, or Enter merges in an older Safari. ⚠️ A
  controller shows an actor's text only for the codes in its `REFUSALS`; any other failure
  carries the message of an exception. The rules, the lock order and their reasons stand
  in the headers of `across_organisations.rb`, `merge_people.rb`, `split_person.rb` and
  `take_over_person.rb`, not here.
  The card (2026-11-17): `merged_card.rb` (`People::MergedCard.call(viewer:, address:,
  across: nil)`) reads ONE person for the lane of `/people`: every source the list shows as
  that person (`AcrossOrganisations#shown_at`, which runs the card's block once per source
  UNDER THE TENANT OF ITS ORGANISATION), each through `People::Lookup.card(entry, notes:
  true, kind_names: true)` (a detail without a label is named as the people page names it,
  and every detail carries its kind; REST, MCP and the assistant keep label and value with
  the stored kind as label). `address` is `"<organisation id>:<entry address>"` of any
  source (`MergedCard.address_of`, `.parse_address`, also for `Actors::SplitPerson`); what
  names nobody the viewer can see answers nil, whatever the reason. Per field the distinct
  values with their sources and the kind of the first (`Value#kind`): equal by the ONE rule
  of their field (`#rule_of`: an email's as soon as one source gives the label that kind,
  else a phone's, else the words; a phone without whitespace, an email also without case,
  anything else with its word breaks: "AB C" is not "A BC"). ⚠️ A rule per entry made the
  same words two values where one organisation typed a label as a phone number and another
  as text. The rule of a field holds for its text entries too, on purpose (`#rule_of`).
  The card in two modes (S4, 2026-11-19): the lead source (D11) is decided by ONE rule,
  `AcrossOrganisations.lead_of(sources)` (most values by `People::Lookup.value_count` over
  the hash of `Lookup.card`, counted under each source's tenant; then the newest last
  contact; then the list order), asked for a row (`Row#lead`) and for the card
  (`Card#lead`): list and card cannot name different leads. ⚠️ Never count from
  `Lookup.row`: it has no email, phone or details. The lead's values come first in a field,
  as the lead wrote them; `sources`, name, kind and address keep the list order. A value
  some sources lack is no entry of its own any more (`Field#differs` still says the field
  differs): what each source holds is `Card#holdings` ("Which source holds what", `Holding`: the
  sources with the same field keys and notes flag, the lead's group first, then more before
  fewer, then list order).
  The card shows a value by its kind as the people page does
  (`AllPeopleHelper#all_people_card_value`: links, dates in the reader's language, every
  mailto through `PersonDetail.mailto`, which encodes all but a list of safe characters). ⚠️ The right to write is asked inside the block
  (`PersonPolicy#update?` reads the tenant of the thread) and leaves as the entry the form
  edits (`edit`: `{ person_id: }`, or `{ member_id: }` for a member without a row, nil
  without the right); how the people page names that form in its address is
  `AllPeopleHelper#all_people_edit_path`'s, from the page's own constants. None at a
  member's name and email (`ACCOUNT_FIELDS`, drawn from `Actors::SavePerson`'s). Plain values
  leave, no `Person`. ⚠️ The notes go to this card and nowhere else: it is no tool, nothing
  of it reaches an AI provider or a list. `across:` hands in the list's read of the same
  request, so page and card share one directory per organisation.
  `Actors::SplitPerson` takes `source:` (the card's "take one source out"): only the lines
  of the merge that name that source go, read through the list like a merge's entries. A
  value that is no address is refused, never read as "the whole merge". ⚠️ The card and the
  actor ask ONE rule whether a source can leave: the list's grouping, done again without
  those lines (in memory for the card, `Source#detachable`; with the lines stored after the
  write for the actor, `AcrossOrganisations#stands_alone_now?`, no second read of the
  directories). The source stands alone and every OTHER person of the list stays as shown.
  Until the review of #197 the card asked whether the source stood alone in its account and
  offered steps the actor always refused, and the actor compared only that one person.
* `notifications/` — recipient fanout, broadcast, scoring (separate map in the directory); plus
  `inbox_query.rb` + `serializer.rb`, the SINGLE owner of the token inbox (reach,
  argument contract, row JSON), shared by `GET /api/v1/notifications` and the
  MCP tool `list_notifications`
* `pagination/page.rb` (18.11.2026): `Pagination::Page`, the paging of every list of the web
  interface and the admin area, the application's own since the pagination gem left. The
  numbers of one page (`count`, `page`, `limit`, `pages`, `offset`, `from`, `to`, `prev`,
  `next`, `series`) and `.of(scope, page:, limit:)` => `[page, rows]`. It reads the page
  number of a request itself: below 1, no number or a list is page 1, never a 500. A page
  behind the end is an EMPTY page (`past_end: :empty`, the default; the inbox appends pages and
  needs it) or the last one (`:last`: meetings, knowledge), and never an OFFSET query. A list
  of the application pages through `Pageable#paginate` (page size from `?items=`, then `?limit=`,
  the reader's setting, the default, never above `Pageable::MAX_PER_PAGE`), an admin list through
  `.of` with a size of its own (fixed; the mail log also takes `?limit=` up to 100) and the bar
  `admin/common/_pagination` (which alone decides whether it shows).
  `.size(value, default:, max:)` is the ONE reading of a page size, for a request (`?items=`,
  `?limit=`), the reader's saved setting (`User::PreferenceStore`, the one writer, stores it
  at most at `Pageable::MAX_PER_PAGE`) and every list with a rule of its own: no number, below
  1, a list or a hash names no size, never one row. A bar asks `#links?` (more than one page,
  or a page behind the end, which links back), never `pages > 1`. The saved views' results
  (`SmartFolderService`) page through `Page` as well; every result unpaged only with
  `unpaged: true`, which the lists that use a saved view as a filter ask for (tickets, times;
  ⚠️ a view of ONE type that stays in SQL, today meetings, is cut to a page even then). A bar
  names a frame only where a `<turbo-frame>` of that id surrounds it
  (`PaginationHelper::FRAME_IDS`), else `_top`: the page-size select sets `src` on what it
  finds. The token lists do NOT come through here, they keep
  `list_paging.rb`. Guards: `spec/services/pagination/page_spec.rb`,
  `spec/requests/list_page_parameter_spec.rb` (every list, every unshowable page),
  `spec/requests/list_pagination_bars_spec.rb`.
* `list_paging.rb` (05.11.2026): `page`/`per_page` of the lenient token lists (ticket list of
  REST and MCP via `Tickets::Filter`, the time session lists of `/api/v1`). A string that is no
  number stays the default, as before; refused (`InvalidArgument`, REST 400, MCP invalid input)
  are only a page above `MAX_PAGE` (its offset left bigint) and a list or a hash, which
  raised into a 500. Since 06.11.2026 also the strict reading, `.strict_number`: a whole number
  from 1 to max (text digits only; a JSON number also `2.0`), absent or empty the default,
  anything else refused with one wording in DE and EN (`services.list_paging.invalid_number`,
  the value quoted only in part). The glossary (`Glossary::Lookup`), the people directory over
  REST and knowledge and meetings over REST (`Knowledge::Lookup`, `strict: true`) read through
  it, each raising its own error class. The inbox, the posts of a ticket (`Tickets::Reading`)
  and `list_projects` keep their own rules (they clamp).
* `posts/` — `comment.rb` (REST R3a, 29.10.2026) is the ONE rule of a comment written through
  a token: the MCP tool `post_comment` and `POST /api/v1/tickets/:ticket_id/posts` call it.
  `parse` (format `html`/`plain`, valid UTF-8, no NUL in plain, `plain_text_body.rb`, empty
  after conversion), `build` (the unsaved post through `Actors::SavePost`, for the caller's
  `:create?`), `save` (a comment written before a failure after the commit counts as saved,
  else a retry with the same Idempotency-Key writes it twice); rights and wording stay with
  the callers. The refusals (`REFUSALS`), the tool's `REFUSAL_TEXT` and the
  `services.post_comment` keys in de and en are held together by
  `spec/locales/token_rule_refusal_texts_spec.rb`. ⚠️ An empty html body is
  answered differently on purpose: MCP refuses it before the ticket lookup (`body is
  required`, as always), REST leaves it to the model after the write check (its answer
  without `format` stays byte for byte). Not a second rule: do not align them in one hull.
  Encodings: JSON and forms always give UTF-8; a multipart part may name its own charset,
  which an html body keeps (ActionText reads it, as before) and a plain body transcodes.
* `app_sessions/` — `authentication.rb` (K6b, 16 November 2026) checks email and password for the clients' sign-in
  entry point (`POST /api/auth/v1/app_sessions`) and returns the user or the reason (`invalid_credentials`,
  `email_unconfirmed`, `account_deactivated`). This entry point does NOT go through Warden: the object asks Devise's
  questions in Devise's order and manually performs what hooks normally do (dummy bcrypt for an unknown
  address, reset counters after success). ⚠️ A locked account always reads as
  `invalid_credentials`, even with the correct password; so does any reason the object does not recognize.
  Never introduce a new reason that reveals more than web sign-in. The subsequent write belongs to
  `actors/create_app_session.rb` (Tier 1): make room under the user-row lock
  (`PersonalAccessToken.make_room_for_app_session!`), create the device token, record login
  (`login_method: app_session`); under the same lock, it checks whether the verified password is still valid
  (`stale_credentials`). `request_facts.rb` is what the activity log reads from the request, made
  safe: only a known account is logged, so no header may cause logging to fail.
  Sign-out (K6c, 16 November 2026) is `actors/revoke_app_session.rb` (Tier 1): revoke the request's token,
  record logout (`logout_type: app_session`), both only once, even if two calls read the token before
  writing; a foreign token there is a caller error and raises already on construction.
  Guards: `spec/requests/api/v1/app_session_spec.rb`, `spec/services/app_sessions/authentication_spec.rb`,
  `spec/services/actors/create_app_session_spec.rb`, `spec/requests/api/auth/v1/app_sessions_spec.rb`.
* `personal_access_tokens/` — `reach_listing.rb` (31.10.2026) is the ONE read of a token's
  organisations and projects as rows, for `GET /api/v1/organisations`, `GET /api/v1/projects` and
  the MCP tools `list_organisations` and `list_projects`. Reach (`PersonalAccessToken::Reach`) AND
  the policy scope decide; `openable_only` narrows to what the project gate opens
  (`ProjectAccessService.openable_project_ids`), for the MCP tool. It asks `Pundit.policy_scope!`
  per organisation, not the controller helper. The method `projects_in_organisation` keeps its
  name: `spec/support/prosopite.rb` allow-lists it by that name.
* `lalabase/` — AI/RAG domain (separate map in the directory)
* `access_check/` — project-access logic, 5 objects with overlapping predicates —
  **check here before building anything new**. `project_access_service.rb` is the SINGLE owner of the
  “active membership” rule (`.active_member?`, #603): all five entry points
  check it first, **before** the admin shortcut, in the same order as
  `ProjectPolicy#area_access?`. Four locations previously maintained it manually. Anyone building
  a new reach check goes through this and does NOT write the check again
  elsewhere. ⚠️ Two questions remain separate: `User#account_admin_in?` is the
  authorization question (requires active membership); `role_in_organisation` is the data question
  (does not; the members list still shows a deactivated member's role).
  Exception with its own justification in code: `ChatPolicy::Scope` checks for itself because
  org-wide conversation history has no project at all. Guard:
  `spec/policies/inactive_membership_scope_guard_spec.rb`. Likewise for the “archived
  project” rule: closed to non-admins at every entry point (since 27 September 2026); the only
  exception is their own hours (readable through `time_sessions/viewing_scope.rb`). Guard:
  `spec/requests/organisations/archived_project_access_spec.rb`
* `subscriptions/` — subscription/pricing domain at account level (ABOVE orgs, tenant-free):
  `seat_counter` (deduplicated billable users per account; raises loudly on counting errors instead of silently
  undercounting), `guest_ceiling` (detection only, never blocks a write),
  `price_lookup` (**THE seam for “which price version applies” and “which tier matches
  this seat count”** — date and seat comparisons belong exclusively here so the
  inclusive `ends_on` semantics exist exactly once), `public_price_list_payload` (stable
  v1 contract for `GET /api/public/v1/price_list`: always in the `data.price_list` envelope, containing
  plan, currency, interval lengths and raw tier values with `billing_interval`, but no IDs,
  notes, audit or date fields; without a valid price version, `data.price_list` is JSON `null`),
  `amount_preview` (seats × tier −
  discount, all amounts NET; explicitly **not** a billing forecast, because a
  seat reduction takes effect only at the end of the period), `ladder_validator`
  (the two tier invariants,
  no gaps/no overlaps — apply to the price version as a WHOLE, hence not a
  model validator), `price_list_gaps` (finds **future** pricing gaps; a “does a price apply
  today?” check cannot see them, and that is exactly how the public pricing API fails on the cutoff date;
  since S3.2, callers exist only in the engine: price-version page and `subscription_prices:check`),
  `public_ladder` has been **removed** since W6: the pricing page lives in
    gboyke/lalabase-website and supplies its own ladder.
  ⚠️ **Since S3.2, in the `gboyke/lalabase-operator` engine, no longer here:** `billing_period`
  (the only month arithmetic, MEASURED from the start date), `billing_list` (W4, five
  exhaustive sections), `price_list_seed` (initial population, only with
  `BUNDLE_GEMFILE=Gemfile.operator rake subscription_prices:seed`), `admin/acquisition_report`,
  `actors/withdraw_price_list`. Their rules are in their files over there.
  ⚠️ **Three amounts that can be wrong on a public page — all three are
  predicates on `Cell`, not tier indices** (§7.5, §7.5.1): `per_seat?` (seat component only →
  “€X per person”; the open-ended tier has NO total amount, “ab 11 | 110 €” (“from 11 | €110”)
  was wrong for every larger team), `total_from?` (base AND seat components across multiple seats → only the
  lower bound “from €X” is true), otherwise an exact total. And `rung_for` pairs
  intervals by coverage of the **entire row**, not its first seat: a tier ending
  midway through the row was otherwise extrapolated beyond its upper limit (observed:
  twice the per-person price). Partial coverage → “—” cell, never a pairing.
  ⚠️ The page builds two I18n keys per interval **dynamically** from
  `Constants::BILLING_INTERVAL_KEYS` — `i18n-tasks` cannot see this, hence the guard
  `spec/locales/billing_interval_keys_spec.rb`. “Third interval = data-only change” applies
  to Ruby and JS, NOT to locales.
  **The seat chain (M0 through M2, `doc/abrechnungsmodell_plan.md`)** — four services that
  build on each other. They do NOT answer the same question as `seat_counter`: that counts
  **now** from memberships; this chain reconstructs **then** from `seat_events`.
  1. `seat_opening_backfill` (M0b, `rake seat_events:backfill_openings`) — writes the
     opening state an event stream on an existing system never had. Without it,
     a quiet existing account reconstructs as ZERO seats. Idempotent, sets the marker
     `SystemSetting#seat_stream_opened_at`.
     ⚠️ Reconstructability depends on this **marker**, not the `opening` rows: a
     pair-specific row cannot answer the system-level question “from when at all?”, and on
     a day-one installation those rows are rightly absent.
  2. `seat_stream_drift` (M0b/M0c) — stream against `seat_counter`, per account, nightly at 06:20
     (`SeatStreamDriftCheckJob`, production only). Reports, NEVER repairs: a repair would
     have to invent a time, and invented timestamps in an append-only ledger become
     authoritative figures.
  3. `seat_snapshot_writer` (M1a/M1b) — one `seat_snapshots` row per account and month start.
     **Overwrites** on rerun, the OPPOSITE of `ai_usage_aggregator`; §9 depends
     on this (add a backdated event, then recalculate).
     ⚠️ **Two entry points, no switch:** `.call` recalculates (correction,
     `rake seat_snapshots:rebuild`); `.fill` writes only where there is NO answer yet. The
     monthly run uses `.fill` — if it overwrote answered rows, every §9 correction
     would silently disappear at the next monthly tick.
     Operations (M1b): `SeatSnapshotJob` on the 1st at 06:40 (production only, immediately after the
     drift check), gap guard through `.gaps`/`.unanswered_accounts` — guard and writer
     query through the SAME method; two interpretations of “still missing” would
     contradict one another. Also `rake seat_snapshots:backfill|gaps|rebuild`.
  4. `seat_peak` (M2/M3, `rake seat_peaks:month|show`, plus the block on the account admin page) —
     the peak of a measurement month, including when and with which organisations (§5). Read
     only: missing snapshot ⇒ `unavailable`, no recalculation, or a broken
     monthly job would hide itself.
     ⚠️ **The result has NO monthly peak, but `sections`** (M3/A3/A9). Two
     affiliation boundaries, with DIFFERENT effects: an org move
     (`moved_in`/`moved_out`, NOT `opening`) **splits** the month into several sections;
     `billing_starts_on` midway through the month **shortens** it (still ONE section, but covering
     only some days). Tying the span and proportion to the section count instead of
     `Result#detailed?` displays every customer's first month as a full month.
     ⚠️ **Two distinct cuts per section, deliberately different:**
     `measured_from/to` are the actual measurement moments; `first_day/last_day` are the billed
     calendar days, and the move day belongs entirely to the new section (A6). Measuring from
     midnight instead of the move moment would leave people on the former account until
     noon, and both accounts would pay for the move day. Demonstrated by the calculation in A3.
     ⚠️ Events EXACTLY at a cut are applied BEFORE the section is measured for the first
     time. In the reverse order, the opening value is the state ended by the cut,
     and the second section's peak can never fall below it (observed: [2, 2] instead of
     [2, 0]).
     A month before `billing_starts_on` is `not_billable`, not “unanswered” — whether an account
     may be billed at all remains the decision of `billing_list`, not this service.
  ⚠️ **Never a plus/minus counter** (§4). Because people are deduplicated across an account's
  organisations (D4.1), removal from organisation 1 frees no seat while
  the person remains in organisation 2. The snapshot therefore holds **pairs**, and
  replay holds a map, not a number.
  ⚠️ **Month boundary `Europe/Berlin` in ONE place:** `SeatSnapshot.boundary_moment` (A6, the
  app runs on UTC). Alongside it, `SeatSnapshot.normalise_period` (Date/Time → month start) and
  `.current_period` (which measurement month is current) — `SeatSnapshotWriter.current_boundary_month`
  now only delegates there. Writing a second conversion silently measures a UTC month,
  specifically during the two hours after midnight on the first of the month.
  Events EXACTLY on the boundary belong in the snapshot; replay starts strictly
  afterwards; the window's end boundary is therefore exclusive (`SeatEvent.strictly_between`).
  **The account overview (K-S1):** `visible_accounts` (which accounts concern a
  user) and `account_summaries` (one row per account for `/billing`; the cockpit block has
  been removed, the entry point is now “Billing accounts” in
  `common/_navigation_account`, the ONLY navigation without a tenant).
  ⚠️ `account_summaries` hides accounts WITHOUT an organisation. Deliberately there, not in
  `visible_accounts`: one answers “may view” (with pinned policy agreement),
  the other “is there anything to display?”. Such an account remains accessible by URL and
  is still listed in the admin area.
  ⚠️ `visible_accounts` is a SECOND version of `AccountPolicy#show_overview?`, deliberately
  asked **in reverse**: the policy iterates over the ACCOUNT's organisations and fans out per row;
  this object iterates over the USER's organisations and therefore does not grow when
  another account bundles more orgs. Two versions of an authorization rule drift —
  their agreement is therefore pinned itself (`spec/services/subscriptions/visible_accounts_spec.rb`,
  group “agreement with AccountPolicy”). Anyone changing the policy changes both.
  ⚠️ The row builds its state key **dynamically** from
  `AccountSummaries::LABELLED_ROW_STATES` — hence the guard
  `spec/locales/billing_account_row_states_spec.rb`, same structure as the interval guard above.
  **The move (K-S2):** `organisation_move`, entry point `rake billing:move_org`, deliberately without a UI.
  ⚠️ **NEVER reassign an organisation with `update!(account:)`.** This write touches no
  membership, so no callback fires and the seat stream sees nothing; both
  accounts then reconstruct plausible but incorrect numbers. The service writes the
  `moved_out`/`moved_in` pairs itself, with ONE timestamp for both halves. Refuses when
  `billing_starts_on` is set (`FORCE=1` overrides), shows accesses and amount for both accounts
  before/after, and `DRY_RUN=1` runs through the same transaction and rolls back at the end — so
  preview numbers are the actual ones, not a separate calculation. An account left empty
  remains (K7).
  ⚠️ **K6 applies only to rows already WRITTEN.** Rollups, seat events, discounts and
  applications retain their `account_id`. Usage not yet rolled up follows the
  organisation instead: `AiUsageAggregator#record_for` reads `organisation.account_id` only when
  rolling up, and `ai_usage_rollups` holds ONE row per organisation and month (unique index,
  insert with `ON CONFLICT DO NOTHING`). A partial close on moving would therefore not move
  the rest of the month, but LOSE it. The task measures and names this boundary
  instead; splitting a month requires a data-model change.
  ⚠️ **Bundling breaches the guest limit.** `guest_max_organisations` defaults to 1 and
  counts the organisations within ONE account in which someone is exclusively a guest
  (`guest_ceiling.rb`). K5 creates exactly this state, so moving creates violations
  that could not exist with two separate accounts. This is the only consequence of a move
  visible to the CUSTOMER: `Organisations::BaseController#warn_if_guest_ceiling_exceeded` sets
  `flash[:warning]` on the next membership write. This is why `#snapshot` measures the count for
  BOTH accounts, and the task reports it where it has INCREASED; the remedy is the limit on the
  receiving account.
  Plans: `doc/billing_preisliste_rabatt_plan.md`, `doc/konto_ebene_plan.md`.
* `documents/` — document versions (`doc/dokumentansicht_plan.md`, S1): `number_versions.rb`
  numbers existing versions chronologically from 1 per document (task `documents:number_versions`, after
  deploy, BEFORE the NOT-NULL migration). ⚠️ Takes the document's row lock, the same one as
  `Actors::SaveDocumentVersion`: a transaction alone does not block a concurrent upload.
* `indexing/` — `index_everything.rb`, the metered catch-up service, since notes are always indexed
  (`doc/notizen_immer_indexiert_plan.md`; task `indexing:everything[ORG]`).
* `embeddings/` — embedding v2 domain. **`nearest_neighbors.rb` is THE SINGLE vector-read seam**
  (PR 4b, `doc/embedding_v2_pr4b_read_switch_plan.md`): all retrieval call sites go through it;
  `nearest_neighbors` on inline columns no longer exists in application code. The seam owns
  the metric per record type, the required INNER JOIN (M1) and the 4a index predicates — NEVER build new
  vector searches alongside it. The rest: GC/reindex operations helpers.
  **Staged switch (PR 6a):** The pointer
  `organisations.active_embedding_space_id` → `embedding_spaces` (triplet + credential snapshot)
  determines which space the seam reads, NOT the org configuration. `ensure_space.rb` creates spaces;
  `Actors::FlipEmbeddingModel` switches them (completeness as an ANTI-JOIN through `OrganisationReindexer.missing_in_space` —
  orphans can fool a count); `space_index_flag.rb` removes spaces from the index
  (retirement) and puts them back (reactivation — **must run BEFORE flipping back**, or
  rollback silently returns zero matches). Reindexer modes: build (missing rows) /
  `delta:` (also `source_hash` drift) / `force:` (everything).
  **Only `content_types.rb` owns the type list (since 4 September 2026):** nine entries with
  table, model, opt-in SQL, required join, project join and project column, plus
  state predicates (`flag_pending`, `processed`, `failed`, `text_present`). No relation
  is built there (two tenant contexts). Three readers derive from it and build their own
  query shape: `pending_embeddings.rb` (lazy relations for the button and monthly catch-up),
  `index_health.rb` (ONE UNION) and `ai_sync_status_service.rb` (per project, `.call(organisation:)`).
  Guards: `content_types_spec.rb` (list ⟺ models with `as: :fragmentable`, derived) and
  `index_health_pending_parity_spec.rb` (stubs the list without one type; every reader must
  lose it, otherwise it has a private copy). A tenth type = one entry + builder in
  `spec/support/embeddable_content_types_helpers.rb` + row in `AiSyncStatusHelper::TYPE_PRESENTATION`
  + German/English label + enumeration in the in-app help `05-sync-status.md` (German **and** English).
  NOT the retrieval side: `ContentAreaRegistry` gates what COMES BACK.
  **Three readers of the same columns, not one (AI area S2):** `index_health.rb` answers
  “how much is pending, how much has failed” org-wide in ONE query (UNION over all
  registered types) — for the AI hub, whose budget is ≤ 9 queries of its own
  for the ENTIRE page (§3.3 states 5 at the top; the 5 August addendum explains 9). `AiSyncStatusService` remains the detail-page reader (all projects ×
  all registered types, overview = sum of project rows) and must NEVER be called on the hub. ⚠️ The cost of raw SQL:
  `acts_as_tenant` does not apply; every UNION branch binds `organisation_id` itself — a
  forgotten filter is a silent cross-tenant leak that request specs with only
  one organisation cannot see (observed). Coverage: `spec/services/embeddings/index_health_spec.rb`.
  **Status display ≠ diagnostics (AI packages P4c):** `switch_progress.rb` answers “is a
  switch running and how far along is it?” for the CUSTOMER page; `space_alignment.rb` is the operator's diagnostic.
  Do not confuse them — the full `SpaceAlignment.call` performs four aggregate scans with
  correlated subqueries; on a page the customer opens manually, this repeats
  the N+1 lesson from #368. Instead, `SwitchProgress` proceeds in stages: opt-in and pointer are
  column reads, `configured != active` does not touch `content_embeddings`, and
  anti-joins run only if a switch is actually pending.
  ⚠️ **Without a pointer, the switch question cannot be answered** — `embedding_space_for(:active)`
  falls back to the configured triplet, both sides of the predicate become identical, and
  an ongoing switch reports “none”. `SwitchProgress` returns a dedicated
  `:pointer_missing` state instead of `:none`; recreating the predicate elsewhere (the
  watcher does) inherits the blindness without the notice. Repair: `embeddings:backfill_spaces`.
  ⚠️ **`ensure_space.rb` refreshes ALL snapshot columns — except one.** `ai_credential_id`
  (the P0 pin) is written only if the row has no pin, and cleared when it switches to
  BYOK; an existing pin remains (log warning on mismatch). The reason is the
  column's purpose: refreshing it too would let `flip`/`build_target` silently reassign a held space to
  today's provider default — exactly the swap the pin was built to prevent, only
  through the write path instead of the read path. Anyone adding a pin column to a refresh hash
  needs this exception in code, not merely a model comment.
  **Retention (PR 6b):** `orphan_gc.rb` has a third, **org-bound** sweep: spaces
  beyond `organisations.embedding_retention_limit` are deleted (sidecar rows +
  `embedding_spaces` row). Two protection rules whose ORDER matters — the active space is
  never a candidate, and the space being built (= configured triplet, but not active) is excluded
  **before** the retention selection, so it occupies no slot. Retention order is
  `retired_at DESC NULLS LAST` (the flip stamps it under a lock), NOT `created_at`: after
  a rollback, the two point in different directions. Separate kill switch
  `EMBEDDINGS_RETENTION_ENFORCE`, distinct from `EMBEDDINGS_GC_ENFORCE` (different blast radius:
  orphans are worthless, a space is the rollback safety net).
  ⚠️ **NO sweep sees rows in a triplet WITHOUT an `embedding_spaces` row** — record alive
  (not an orphan), no space holds the triplet (not a retention candidate). GC counts and warns about
  them as `UNREGISTERED`, never deletes them (the same triplet can also be a newly configured
  target before `build_target`). This is legacy production data from switches before PR 6a — expecting
  GC to remove it misunderstands the sweep.
  **The inline lane is gone (PR 7).** The four inline vector columns and their eight
  provenance columns have been dropped; `content_embeddings` is the only vector source for
  BOTH reading and writing. This removes the dimension special case: the five write paths
  (`embedding_processing_service`, `project_indexer_job` ×2, `indexer/symbol_persistence`,
  `embeddings/organisation_reindexer`) write every dimension through the same path.
  `Indexer::EmbeddingColumns` now provides only the TRIPLET (`.from`) — `inline_pair`,
  `INLINE_DIMS` and `inline_writable?` no longer exist, nor do `SidecarBackfill`
  and `normalize_legacy_labels`. Anyone asking “has an embedding?” queries the sidecar
  (`Fragment.with_sidecar_embedding`). Guard: `spec/models/no_inline_embedding_columns_guard_spec.rb`
  keeps the columns out — otherwise the shared development database writes them back through `schema.rb`.
  **`space_alignment.rb` is the gate to this seam** (`rake "embeddings:check_alignment[ORG]"`,
  exit ≠ 0): the seam filters strictly by the triplet resolved by `Factory.embedding_space_for` —
  if it does not match the stamped triplet of the sidecar rows, EVERY search silently returns zero
  matches (as happened in production on 2026-07-30). A completeness anti-join cannot
  see this in principle — it asks only WHETHER a row exists, not in which space
  (`OrganisationReindexer.missing_in_space` is the remaining one and therefore carries the triplet
  itself). Run before/after every model change. Four buckets, only
  one is the finding (five since PR 6a, see `pending_flip`): `stranded` (record has NO
  **readable** row — triplet AND `indexed` —
  → unreachable) is the error case; `stale` (old row alongside a readable one) is the normal state
  after every reindex — since PR 6a, retirement removes such rows from the INDEX
  (`indexed → false`); retention GC (PR 6b) DELETES them ONLY if an
  `embedding_spaces` row still holds their triplet (otherwise `UNREGISTERED`, see the retention block
  above); `stale_count` therefore does not decrease at retirement; `aligned` is the healthy remainder; `orphan`
  `pending_flip` (unreadable in the active space, but readable in the CONFIGURED one — content
  created during an ongoing staged switch; the flip resolves it, a reindex does not,
  hence outside the verdict); `orphan`
  (record removed through `delete_all`) is **outside** the verdict — no reindex reaches these;
  the remedy is `embeddings:gc`. The exit code also considers `ai_enabled`: AI off → warning
  instead of red (the recommended reindex would raise `AiDisabledError`); AI on + space NOT
  resolvable → red (`NearestNeighbors` then raises on every query, while `PromptBuildingService`
  silently responds without context). **No resolvable space ≠ “org has AI off”**:
  `Factory.embedding_space_for` is gate-free and resolves with an active system credential for EVERY
  org — the state means “no credential at all” (or misconfiguration, then always red).
  **Second, independent half of the verdict (AI packages P0):** the buckets above compare only
  TRIPLETS, and `embedding_space_for(:active)` answers from the snapshot row without ever touching a
  credential. A space whose pin (`embedding_spaces.ai_credential_id`) points to a
  deleted, deactivated or wrong-provider credential would therefore be `aligned/ok` —
  while EVERY query raises `MissingCredentialError`. Thus, `SpaceAlignment` additionally asks
  `Factory.active_space_credential_error` (gate-free, nil for BYOK and without a pointer), and
  `severity` is the WORSE of `space_severity` and `credential_severity`. `status`
  deliberately remains triplet-only: “misaligned” for correctly placed rows would send the operator
  into a reindex that repairs nothing — the rake text instead says “reactivate credential
  OR reassign space”.
* `admin/` — read objects ONLY for the admin area. `acquisition_report` (where a customer came from,
  `doc/akquise_herkunft.md`) has lived in the engine since S3.2. `ai_routing_summary` answers “which AI
  does this org use?” by asking `Lalabase::Llm::Factory` for the precedence **package rung > BYOK > system credential**
  (`curated_chat_tier`) instead of recreating it — the old
  display read `has_own_ai_credentials?` (“brought no token”) and thereby labelled every
  package org “System credentials”, naming a credential it never touches.
  ⚠️ `Admin::Organisation` needs its `belongs_to :ai_package` for this: the factory asks
  `organisation.try(:ai_package)`, and without the association, **every** admin org answers
  “no package” — silently and plausibly.
* `codebase_import/`, `user_data_exports/`, `subscriptions/`, `overview/`, `dashboard/`
* **Beware, two similarly named domains:** `documentation/` = `.md` documentation synchronized
  from repositories (own `MarkdownRenderer`, own `Navigation`; `asset_collector.rb` copies
  images from the clone during sync and is the SINGLE place deciding which are
  served: inside the clone after resolving symlinks, type from bytes, one
  type list `RichTextEmbeds::IMAGE_CONTENT_TYPES`; ⚠️ after changing the renderer, run
  `bin/rails documentation:resync_all`; polling skips unchanged repositories),
  `product_knowledge/` =
  Lalabase's own text as a search table. The third, `docs/`, **no longer renders Markdown** since D5
  (21 September 2026) and is only the READ LAYER over an external file
  (`doc/docs_delivery_plan.md`).
* `docs/` — eight files, all answering the same question: what the help (`/hilfe`) and
  assistant know about the documentation living in `gboyke/lalabase-documentation`.
  `catalogue.rb` reads one JSON file per language, written by that program and placed
  here by its deployment (`DOCS_CATALOGUE_PATH`; contract: `docs/api/katalog_v1.md`).
  ⚠️ **No file is the NORMAL CASE** (self-hosting, development machines): every reader
  responds, none raises. `contract.rb` holds what both sides share (languages,
  sanitization allowlist, canonical `/docs/<language>/<slug>` form) — **one** constant per
  thing, and `page_links.rb` reads the form from it instead of keeping a second copy.
  `contextual_help.rb` is the page → question → anchor map; it belongs to the core, while
  `rake anchors:check` in the other repository checks whether the anchors still resolve. Also `help_link*.rb` (where a link
  points: org-bound help, otherwise public documentation), `public_docs.rb` (its URL)
  and `plain_text.rb` (snippet around a match).
  ⚠️ **Nothing here renders Markdown, and nothing reads `app/docs/`** — the directory
  no longer exists. To change a documentation page, edit it in the other repository. Redcarpet and
  Rouge remain in the Gemfile: `documentation/` and `Lalabase::SafeMarkdown` still use them.
* `product_knowledge/`: Lalabase's OWN text (in-app help)
  as a searchable table without an organisation (`doc/product_knowledge_plan.md`). Since D4, the source is
  the **catalogue** (`Docs::Catalogue`), no longer `app/docs/`; the table is a
  copy of it. `sources.rb` decides fail-closed what
  goes in (deliberately excluding self-hosting documentation, which is not in the catalogue at all), and is
  the ONLY place that calculates the content hash (`build_row`). `sync.rb` reconciles (`rewrite:` for
  repair). `ensure_fresh.rb` runs before every read, in this order: per-process
  marker (5 minutes or until the catalogue changes; otherwise every read costs about 100 ms),
  TABLE fingerprint against the catalogue, never backwards (`SystemSetting`
  `product_knowledge_generation`; otherwise an old-release process resets the table during
  deployment; the reference is the catalogue files' modification time, and a
  language WITHOUT a file contributes nothing instead of a zero that would pull the generation backwards),
  nonblocking lock. All without query caching (under the cache, the
  check after the lock saw the old state). `search.rb` is the SINGLE reader: PostgreSQL normalizes
  search terms ONCE (stop-word removal, stemming and prefix matching), then they enter as
  a ready-made `tsquery`, not through the dictionary again; first pages with all terms,
  then with some, then literal matches; one language per answer, help only by
  default. `contents` returns all pages of one language without text (the table of contents
  for `help_contents`). Readers are the assistant's three help tools (map in
  `lalabase/CLAUDE.md`). ⚠️ Never read the table around `Search`; reconciliation lives there.
  ⚠️ Specs that build rows through factories need `:product_knowledge_table_as_given`, or
  real reconciliation deletes them (`spec/support/product_knowledge.rb`). From `docs/`, it reads
  `sections.rb` (the single owner of section labels) and `plain_text.rb`
  (decodes entities, for search index, snippets and model); `page_links.rb` decides for
  the renderer and `get_help_page` which page a link within a page refers to.

Known split locations (legacy; Boy Scout rule: consolidate when touched):
* Ticket logic in 4 places: `ticket_*_service.rb` (flat), `tickets/`, `actors/*`,
  `codebase_import/ticket_*`. All nontrivial ticket writes go through the actor seam
  (`save_ticket`/`move_ticket` [Tier 2], `apply_ticket_changes`, `merge_ticket_attribute_option`,
  `sort_ticket_attribute_definitions`, `create_ai_post` [Tier 2]) — plan `doc/tickets_seam_umbau_plan.md`.
  Since 8 September 2026 (`doc/ticket_bulk_edit_plan.md`), `tickets/bulk_selection.rb` resolves a
  bulk edit's selection into IDs (mode `ids`/`all`, cap `MAX_TICKETS`, `expected_count`);
  also `tickets/bulk_fields.rb` (the single catalogue of editable fields, slice 4),
  `tickets/bulk_summary.rb` (current values per field over the selection, digest per field),
  `tickets/changes.rb` + `tickets/changes/*` (registry: one class per change kind with
  `apply`/`restore`/`still_applied?`/`describe`; errors through `Invalid.with(code)`, because the
  convention requires initializers without positional arguments), `tickets/change_applier.rb` (ONE ticket
  in its own savepoint, carries the per-ticket rescue so actors comply with the contract),
  `tickets/change.rb` (REST R3b, 30 October 2026, not to be confused with the
  `tickets/changes*` registry) is the SINGLE rule for a change through a token: the MCP tool
  `update_ticket` and `POST /api/v1/tickets/:id/changes` call it. `parse` (kind from
  key presence, keys, UTF-8, title rule, lists, `"me"`), `write` (status and
  people through the actor below, title through `SaveTicket` under a row lock in the project) and
  `Outcome` (written, ticket gone, `FAILURES`, unexpected). Permissions and wording remain in
  the wrappers; `spec/locales/token_rule_refusal_texts_spec.rb` keeps `REFUSALS`, `FAILURES`, the tool's tables and
  the `services.ticket_change*` keys in German and English aligned.
  `actors/apply_ticket_changes.rb` (ONE actor for one or many, D13; locks rows,
  compares current values, writes the `TicketBulkRun`) and `actors/undo_ticket_bulk_run.rb`.
  Since 6b, `apply_ticket_changes` also serves board dragging and comment status with a set
  of one ticket (`set_ticket_attribute` has been deleted); a ticket that fails to save is
  a failure of the call there, but a named partial result for multiple tickets. Slice 7:
  `tickets/mover.rb` owns the move of ONE ticket (number with retry in a savepoint, lost
  assignments/subscriptions, times, three activities; context on the ticket and both projects) and serves
  `actors/move_ticket.rb` (now Tier 1) as well as `actors/move_tickets.rb`; `tickets/move_applier.rb`
  and `tickets/destroy_applier.rb` are siblings of `change_applier.rb`;
  `actors/destroy_tickets.rb` reads watchers before deletion; `tickets/bulk_impact.rb`
  counts for the dialogs (comments, attachments, times, subtasks, lost assignments).
  Ticket relations (30 September 2026, `doc/ticket_relations_plan.md`): `tickets/waiting.rb` is the
  SINGLE owner of “waiting”/“blocking” (`waiting`, `blocking`, `counts_for` with a fixed
  query count, `for`); `tickets/cycle_check.rb` provides reachability over a fixed edge list
  (recursive CTE, returns only IDs, terminates even with legacy cycles), ONLY for
  waiting edges: the hierarchy needs none because parents are fixed after creation.
  `tickets/ancestry.rb` is the SINGLE reader of a ticket's ancestors (breadcrumbs): one
  query, terminates on cycles in the data, stays within project and organisation. Writes go through
  `actors/create_ticket_relation.rb` (advisory lock per organisation, then cycle check, then
  `save!`) and `actors/destroy_ticket_relation.rb`; neither checks permissions — the caller does
  (`Organisations::Tickets::RelationsController`). Since PR 2 (ticket page), `tickets/waiting.rb`
  also has `open_ids` (same completion rule for the grey display), `tickets/relation_section.rb`
  reads ONE ticket's section and header hint in a fixed query count (visible relations only,
  but the hint still counts all blockers), and `tickets/lookup.rb` is the picker's search (number
  or title through `Ticket.search_title`). The ticket list's `q` search (REST and MCP, `tickets/filter.rb`) uses
  `Ticket.search_title_and_description`: title and description, no comments. Until 5 November 2026,
  it matched every comment, including private ones; a pg_search join cannot ask `readable_by`.
  Since PR 4 (filter), `tickets/waiting_state_filter.rb` turns “waiting”/“blocking” into a
  yes/no condition (“is not” = the rest of the list, including completed tickets); toolbar
  (`AdHocFilterService`) and view (`SmartFolders::Filters::WaitingFilter`/`BlockingFilter`)
  both query it, never `Tickets::Waiting` with their own negation.
* Embeddings: `embedding_processing_service.rb`/`embedding_reprocessing_service.rb` (flat) + `embeddings/`
* SmartFolders: reads = 5 flat `smart_folder_*` files + `projects/default_smart_folder_service.rb`;
  writes under `actors/` (`clone_smart_folder`, `save_smart_folder_from_filters`, `share_smart_folder`);
  `ad_hoc_to_smart_folder_service` is a pure converter (no longer writes).
  A new special category for the toolbar goes ONLY into `AdHocFilterService::SPECIAL_FIELDS`: the
  converter and `SmartFoldersController#sanitized_filter_params` read the same list. What the
  converter writes, `smart_folder_dissolver.rb` reads back 1:1 (spec:
  `spec/services/smart_folder_round_trip_spec.rb`); without a return path, the view opens as an expert rule.
* Object kind ≠ directory: `kanban_board_presenter.rb` lives here instead of `app/presenters/`;
  some query-like objects live here instead of `app/queries/`

## Assistant scope (S3a T5, 2026-08-25)

Anyone changing org-wide reach changes THREE owners, no more:

* `lalabase/tools/scope.rb` — **`Scope.for(chat:, actor:)` is the only way** to build an
  org scope. Runner and retriever previously followed separate paths; a guard
  (`spec/services/lalabase/tools/scope_factory_guard_spec.rb`) now keeps them on the
  factory. ⚠️ The chip narrows by INTERSECTION with permissions, never by replacement.
  A choice that no longer resolves is no choice: the thread falls back to full
  reach, and `#selection` reports this so the chip does not claim a restriction
  that no longer exists. ⚠️ “No longer resolves” means archived, deleted
  **or no longer readable by THIS requester**: `#selection` goes through
  `Chats::AssistantScopeOptions`, the same owner as the write path. That path checks
  permissions exactly once, on save — without checking on read, a lost
  permission would leave the project name in the system prompt and coverage sentence while the chip
  shows “All projects”.
* `lalabase/tools/base.rb` — `PROJECT_FILTER_SCHEMA` and `resolve_project_filter` are shared
  by all three org-capable tools. ⚠️ On the single-project path (now only
  MCP), the filter is REJECTED, not ignored: silently swallowing it would make a model
  believe it had narrowed the scope. Likewise `coverage_for(..., only_project:)` — an answer narrowed to one
  project must not carry org-wide coverage. ⚠️ `only_project:`
  takes the **project**, not its ID, which is why `resolve_project_filter` also
  returns it that way: the coverage sentence names the project, and with the ID alone,
  every caller would have had to look it up again.
* `lalabase/tools/base.rb#referenced_record` (10 September 2026, `doc/assistent_wissen_kontext_plan.md`)
  — the E3 fallback “what the thread names may be read even if the chip
  searches elsewhere; only by UUID” is shared by the read tools `GetTicket`, `GetNote`,
  `GetDocument` and `GetMeeting`, as are `outside_coverage` and `cap_text`/`TRUNCATION_MARKER`.
  Meeting references load only ID, organisation, project, title and time; the
  title includes the date. On fallback, `GetMeeting` reloads current contents
  from the organisation's active projects and then checks record-level permission.
  No second authorization gate: the reference passed `Scope#resolve_reference` on save;
  per-record `authorize!` remains. `ExtractPlainTextProcessingService
  .text_status` owns the four text-status words (`available`,
  `unsupported`, `unavailable`, `empty`) alongside its allowlist; `Tickets::Serializer` and `GetDocument` call it.
  A new referenceable type = registry entry (`assistant/reference_registry.rb`),
  marker + button through `AssistantContextHelper`, and a `Get*` tool following this pattern.
  ⚠️ **`area:` is NOT the right candidate source for every tool.**
  `ProjectPermission.access_areas` knows `tickets, notes, chats, documents, members,
  documentation, meetings` — **no `time_sessions`**. The all/own/none rule
  for times lives in `TimeSessions::ViewingScope` (§2.4). `resolve_project_filter` therefore
  accepts either `area:` OR `candidates:`; `SummarizeTimeSessions` passes its
  ViewingScope list as `candidates:`. An `area: :time_sessions` here causes a
  `NoMethodError`, caught by the runner as “tool crashed”: silent, not loud.
* `lalabase/tools/scope.rb#code_project_ids` — the reach of the five CODE tools
  (`doc/assistent_code_werkzeuge_plan.md`). ⚠️ **No area.** Repositories are visible to anyone with
  `chats:read` OR `documentation:write` — a union of two areas for which
  `ProjectPermission` has no field. The rule belongs to
  `ProjectRepositoryPolicy::Scope`, and this method is its only caller; a
  handwritten `area: :chats` would silently drop the documentation branch. The same
  structure as `SummarizeTimeSessions` with `TimeSessions::ViewingScope`, for the same
  reason. Here too, the chip narrows by intersection, never by replacement.
* `lalabase/tools/base.rb#resolve_code_project` — the precedence that resolves ONE project
  from this reach: named project, otherwise the chip or the
  only reachable project, otherwise a candidate list. Five tools, ONE precedence rule. Vision
  and capabilities are 1:1 per project, so there is no “all projects” here, and
  guessing is worse than asking. ⚠️ The five now declare `requires_actor?` — the
  only place where the single-project path also changes: without a requester, the
  runner refuses them instead of passing `nil` to Pundit.
* `chats/assistant_scope_options.rb` — selectable projects, shared by chip and
  write path. If they drift apart, the result is either a dead option or a way
  to attach a conversation to a project the user must not see.
* `assistant/reference_registry.rb` — the object types known to assistant references
  (reference collection S1, `doc/assistent_bezug_sammlung_plan.md` §5), fail-closed like
  `PanelRegistry`. Per type: permission area, citation type, `reachable` lambda (the type's POLICY,
  not merely its project filter) and `title` lambda. ⚠️ It duplicates NONE of the three
  existing maps (`AREA_BY_TYPE`, `Citations::TYPES`, `CitationTargets::MODEL_NAMES`),
  but declares entries and is checked against them
  (`spec/architecture/assistant_reference_registry_guard_spec.rb`). It also owns the
  key vocabulary `Ticket:<uuid>` with `parse_key` — ⚠️ **never `constantize`**; the type
  is LOOKED UP exclusively in the registry.
* `chats/reference_normalizer.rb` — shared normalization run by both reference actors
  under the row lock (§7.2). Discards anything that does not resolve for the thread's owner:
  deleted, out of reach, deregistered type — three reasons, ONE word,
  viable only because an org thread has exactly one owner. The write path keeps the
  list clean; the model checks only its shape.

Since T5, the `chatposts.source_coverage` contract also carries `chosen` (name of the
selected project). ⚠️ **TWO paths set it**, not just the chip: the chip through
`Scope#selection`, the tool filter through `coverage_with(chosen:)`. Both are the
requester's choice and receive the same sentence; only a boundary arising from PERMISSIONS is
counted. ⚠️ Anyone producing this coverage NEVER builds it manually: `Scope#coverage`
and `#coverage_with` are the only builders, including in `ProjectRag::Retriever`.
`ChatResponseJob#narrowest_coverage` selects one hash in its entirety and, on a
tie, the FIRST (the retriever's) — a manually built hash there therefore silently overrides
the one carrying the chip. It distinguishes user-chosen narrowing from narrowing imposed by
permissions — each gets a different sentence below the answer, because an answer
travels and the chip does not travel with it.
