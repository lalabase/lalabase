# Map: app/models (as of 2026-11-25)

~80 models sit directly in this directory; namespaces exist only for `admin/`,
`knowledge/`, `overview/`, `smart_folders/`, `time_sessions/`, `user/`. Domain membership cannot be
inferred from the directory layout — this map groups them:

* **Core/Tenancy**: `organisation` (= tenant), `project`, `user` (+ `user/*` — split contract
  in the comments of `user.rb`, **include order is load-bearing!**;
  name rendering has ONE owner: `user/name_display.rb`; which email others see
  (login address, contact address or none, `email_visibility`) has ONE owner:
  `user/email_display.rb` (`#shown_email`, `.matching_shown_email`), with guard
  `spec/architecture/shown_email_guard_spec.rb` against a bare member `.email`; sign-in,
  emails and `/admin` retain `email`; the form `user/profile_display_form.rb` writes the profile
  picture and displayed email from the account tab, without a password), `membership`,
  `role`, `permission`, `project_permission`, `invitation`, `account` (billing layer ABOVE orgs),
  `current` (`Current.user` = audit actor of the Activity chain)
* **Tickets**: `ticket`, `ticket_assignment`, `ticket_attribute_definition`, `ticket_document`,
  `tag`, `tagging`, `ticket_relation` (typed relation between two tickets in one organisation,
  `doc/ticket_relations_plan.md`: ONE row per relation; “blocked by”/“follows” are
  the same row viewed from the target; `KINDS` maps seven labels to four kinds; enum numbers
  are fixed, two guards compare them with the index and CHECK; no Trackable, no history).
  ⚠️ ONLY `Tickets::Waiting` answers “waiting” and “blocking”; “completed” is evaluated in each end's own project
  (`closed_status_values_by_project`, not the combined set `closed_status_values_for`);
  `spec/architecture/ticket_waiting_owner_guard_spec.rb` rejects manual implementations. List, Kanban and
  mobile count per page through `Tickets::WaitingCountsCache`. As with subtasks and times, a list
  only registers its page (`TicketsHelper#register_ticket_count_page`); the first read loads it
  (`Tickets::LazyPagePreload`, via `prepend`). A new counter: prepend the module,
  provide `answered?`, have `preload` answer every supplied ticket, add a line in
  `register_ticket_count_page` and an entry in `builders` in the module spec; if it needs a
  reader, pass one at construction (`new(user:)`). No view preloads manually. The
  `waiting` column is deliberately NOT in `ViewConfiguration::CHILDREN_COLUMN_KEYS` (other rows
  become accurate only on reload). As a view rule: `smart_folders/filters/waiting_state_filter.rb`
  (IS/IS_NOT × true/false, the dissolver also reads `wants_state?`), fields `waiting`/`blocking`.
  Create/delete only through `Actors::CreateTicketRelation`/`DestroyTicketRelation`
  (cycle check under a per-org lock).
  ⚠️ Only `Project#assignable_users` decides who may be NEWLY ASSIGNED to a ticket
  (or follow it): ticket read permission in the project AND active membership. The form,
  header menu, board, bulk editing, MCP and watcher picker read it;
  `users_with_access` alone still includes deactivated members (it also determines
  notifications and what a move retains, so do not change the rule there). Anyone already assigned
  remains assigned (`Ticket#assignable_user_ids`): otherwise, every form save silently removes
  a deactivated person, and the board rejects every further assignment. “Remains” means
  retention only: another `add` of a person who is no longer assignable returns `value_not_allowed`.
  A change may remove any person in the organisation and anyone assigned to or subscribed to
  tickets affected by that change, even after their membership has been deleted
  (`BulkFields::Field#removable`, read only when needed: a status drag incurs no cost for it).
  An undo accepts the people from its run but does not restore those who are no longer
  assignable (`AddRemoveBase#restorable`); the rest of the ticket is reset.
  Title: at most `Ticket::TITLE_MAX_LENGTH` (255), validated only when the title changes.
  Subtasks (arbitrary depth since 31 October 2026): parents are in the same project and
  fixed after creation (`Ticket#parent_unchanged`), hence no cycles. Only
  `Tickets::Ancestry` reads ancestors. Progress and the “Subs” column count only direct children;
  `Tickets::Mover` still rejects a ticket in a tree.
  ⚠️ Only `TicketRelation.visible_to(user, org, token:)` decides who may SEE a relation:
  both ends must be readable (`TicketPolicy::Scope`), and with a token also within its reach. The title,
  number and project of a ticket without read permission must appear nowhere (plan §4).
* **People** (since 26 October 2026): `person` (one shared people list per organisation,
  table `people`), `person_name` (the SINGLE name normalizer, also for
  `MeetingParticipant.normalize_name`). A row is a contact without an account or the
  additional details of a member (`user_id`, only active members of the same org, unique
  per org); `name` is always populated. Separate permission (`Permission::CATEGORIES[:people]`,
  `view_people`/`manage_people`, suitable for guest roles), account admins need no row; the policy
  checks active membership itself. Read through `People::Directory`, write through
  `Actors::SavePerson`/`DestroyPerson`.
  Visibility (S1 review, 28 October 2026): The row of a member whom the reader cannot see on the
  members page stays hidden, even if the membership is merely deactivated
  (`PersonPolicy::Scope`). Only after removal does it become a contact for everyone with the permission.
  The name, email and link of an active member's row belong to the account: `SavePerson`
  accepts them from no request (`ACCOUNT_FIELDS`). For a deactivated member, only
  the link stays fixed (`LINK_FIELDS`, no member select in the form); the row's name and email
  remain its own. Both query `Person#stored_membership`. “Edit implies view” is defined once
  in `Permission::IMPLIED_BY` (read by `PersonPolicy` and `RolePolicy#change_permission?`).
  ⚠️ `concerns/person_trackable.rb`: activities carry NO personal data (empty parameters,
  only field names on changes), always `skip_notifications`; a deletion leaves exactly one
  anonymous `person.deleted` row. ⚠️ `concerns/person_link_release.rb` is included in `membership`
  AND `admin/membership`: removing a membership retains the row and removes only
  the link. This is why `erase_personal_data!` runs BEFORE `memberships.destroy_all` in both
  deletion paths; in the opposite order, `erase_person_links!` would find nothing.
  Since S2a (26 October 2026), `meeting_participant.person_id` (FK, nullified when the
  person is deleted) points to a row; `belongs_to :person` precedes `acts_as_tenant`, and a validation
  keeps the person in the same org. A member still uses `user_id`. Only `People::Contacts`
  reads a person's meetings and “Last contact” (`app/services/CLAUDE.md`).
  Since S2b (27 October 2026), only `Actors::LinkMeetingParticipant` sets `person_id` (dialog on
  participant chips, `MeetingParticipantLinksController`): ONE key per participant,
  a member via `user_id`, a contact (including a deactivated member's row)
  via `person_id`. The rule is enforced three ways: validation `one_key`, check constraint
  `meeting_participants_one_key` (also catches `update_all`), and every writer clears the
  other key itself. A participant whose membership has been removed
  becomes a name again: the dialog links them as a contact and clears `user_id`.
  ONE place decides who is linked through an account (`Meetings::AccountParticipants`):
  a member via `user_id` (active or not), or a contact whose row now belongs to an
  active member; the dialog leaves that participant alone. The actor locks the meeting
  (`lock_in_project!`) and resolves the person and member only through the writer's
  `People::Directory`. The meeting form does not know `person_id`; `SaveMeeting` retains the
  row and therefore the link. If the form turns a contact row into a member's row,
  `person_id` is cleared, and linking (scope `external`) skips contact rows.
  Chip-row order: scope `in_row_order` (page, panel and rerendering).
  Since 28 October 2026, a person may have up to 10 **additional details** (`people.additional_details`,
  JSONB list of `kind`/`label`/`value`). The rule has ONE owner: `person_detail`
  (not an AR model): kinds, limits, normalization, validation, link (`#href`, http(s) only) and
  search values (values only, never labels). Form (kinds, input type, `MAX`), lane, search and
  export query it; the Stimulus controller receives kinds and limit as values. The form
  always submits `person[additional_details][sent]` (`FORM_MARKER`): without it,
  removing the last detail would leave the list unchanged. If the key is entirely absent, the list
  remains untouched. Check constraint `people_additional_details_shape` enforces the list shape and limit.
  Merges above the organisations (2026-11-17, `GET /people`): `person_group` and
  `person_group_entry` are ONE person's private note that rows of different organisations
  are the same human. ⚠️ No tenant, no field of a person, no tracking, and an organisation
  must never learn of a merge: only the files listed in
  `spec/architecture/people_above_organisations_guard_spec.rb` (second group) name the two
  models or their tables; a new reader is red there until it is decided.
  ⚠️ `PersonGroupEntry` has NO `belongs_to :person` (Person is tenanted and raises outside a
  tenant): an entry is held by id against a directory (`.keys_for`, `#key`), with one
  address, and the row wins (`.address_of`). The table's constraints are the rule.
  Written by `Actors::MergePeople`, `Actors::SplitPerson` and the release of a membership
  (`concerns/person_link_release.rb`: `.prepare_release`, `.follow_to_row`), each under
  `PersonGroup.lock_for(owner)`. ⚠️ Account locks (`PersonalDataErasure.lock_accounts`)
  come before the owner lock, and never a row lock on users. ⚠️ The release runs inside
  the removal of a membership and an account erasure and never raises for a note
  (`.quietly`). The rules and their reasons stand in the headers of `person_group_entry.rb`,
  `person_link_release.rb` and `personal_data_erasure.rb`, not here.
* **Glossary** (K4a, 4 November 2026): `glossary_term` (one term per organisation, not per project;
  unique by `normalized_term`, status `proposed`/`confirmed`/`rejected`), `term_correction`
  (one heard form per correction: speaker as person OR member, check
  `term_corrections_one_speaker`; project as origin; position in the transcript), `glossary_text`
  (the SINGLE normalizer: remove invisible characters, NFC, whitespace, lowercase, deliberately WITHOUT
  `PersonName`'s umlaut transliteration). `glossary_term` has `lock_version` like `person`: a
  form submitted over someone else's intervening change is rejected (`:stale_object`). References to rows
  of an organisation precede `acts_as_tenant` and are additionally checked without tenant scoping
  (`same_organisation_references`). Separate permission
  (`Permission::CATEGORIES[:glossary]`, `view_glossary`/`manage_glossary`, suitable for guest roles),
  account admins need no row; `GlossaryPolicy` for both models (since K5b, also runs and proposals, `policy_class`). Write only through
  the glossary actors. ⚠️ A deleted meeting leaves its heard forms and their positions intact; only
  `meeting_id` is cleared (FK `on_delete: :nullify`, exception E4, comment on
  `Meeting#purge_fragment_content_embeddings`); never change this to `cascade`. Account deletion clears
  only the speaker (`erase_term_correction_speakers!`).
  K4b (5 November 2026): EVERY heard form has its own status (`term_corrections.status`,
  `proposed`/`confirmed`, check `term_corrections_status_known`, existing records `confirmed`). Without
  `manage_glossary`, it is created as a proposal, even for a confirmed term. Only
  `TermCorrection.effective` is effective (confirmed form of a confirmed term): K4c and the device read
  through it, never `term_corrections` directly. K4c (6 November 2026): this reader is `Glossary::Lookup`
  (REST `/terms` and MCP `get_glossary`, map in `app/services/CLAUDE.md`). K4d (8 November 2026):
  `term_application` records what a device replaced using the glossary when submitting a meeting
  (heard spelling, term as text, count; `source` `device`), written only by
  `Meetings::Intake` through `TermApplication.record!` (two statements, within the meeting's
  transaction; field `meeting[glossary_replacements]`, capability `meetings.glossary_replacements`).
  Not a correction: nothing is learned, `.effective` never sees these rows. Unlike
  `term_corrections`, they are deleted WITH the meeting (FK `cascade`, `dependent: :delete_all`);
  deleting a term leaves them with its text (`nullify`), and a merge carries them along.
  Display: meeting page above the transcript (`_glossary_applied`), glossary below the heard
  form (`_application`), spelling at the term's header. ⚠️ `Meeting#invalidate_stale_summary` has EXACTLY ONE
  exception: `keep_summary_for_next_save!` (one save, one instance), set only by
  `Actors::SaveMeeting` with `keep_summary: true`, which only `Actors::CorrectMeetingTerm` passes
  (guard: `spec/architecture/meeting_summary_exception_guard_spec.rb`). Do not solve this by
  “also writing `generated_summary`”: without a match it does not change and would still be lost.
  K5b (8 November 2026, extraction): `GlossaryText.compact` is the key grouping a term's
  spellings (without whitespace or hyphens), never a stored term.
  `glossary_extraction_run`: at most ONE active run per organisation (partial unique index
  `one_active_glossary_extraction_run`), `stale?` after `STALE_AFTER`, `mark_stale!` rechecks the
  stored timestamp in the same update; `mark_failed!` is ONE `update_all`
  with a status condition; the shapes of `scope` and `stats` are documented at the top of the
  file. `glossary_proposal`: one per `normalized_term` and organisation, `variants` as a
  JSONB list with a check constraint, status `open`/`accepted`/`dismissed`. Independently of the example passages, `hint_sources` stores
  the source types and IDs of all excerpts sent to the model call,
  including rejected candidates. Without this provenance, the hint remains
  hidden; `hint_source_references` also rejects partially malformed provenance in its entirety.
  `glossary_proposal_source`: polymorphic WITHOUT a foreign key; a deleted source leaves the row
  intact, and the page checks at render time whether it still exists and is readable by the reader
  (`GlossaryHelper#glossary_source_access`); `Glossary::GoneSourceSnippetPurgeJob` clears
  its excerpt and the proposal's hint daily (map in `app/services/CLAUDE.md`); on write, the source must
  belong to the organisation. Database deletion behavior: organisation and proposal cascade; run, term, project and
  account only nullify the reference. `GlossaryPolicy` for all four models (term, heard form,
  run, proposal). `term_corrections.origin` (`meeting`/`extraction`/`import`, check constraint,
  existing records `meeting`); `.effective` does not read it.
  K5c (8 November 2026): a run over ONE document (`scope` kind `document`, `document_version_id` in the same org); only `organisation` runs set the incremental cutoff.
  Only `DocumentVersion#text_status` determines whether a version has text (button, start, run, `GetDocument`).
* **Activity/Notifications**: `activity`, `user_activity`, `outbox_event`, `notification`,
  `notification_preference`, `notification_subscription`, `email_log` — related services under
  `app/services/notifications/` (separate map there)
* **Views/SmartFolders**: `smart_folder{,_rule,_rule_group,_share}`, `view_configuration`,
  `view_state`, `dashboard_configuration`, `overview_configuration` (+ `smart_folders/`, `overview/`)
* **Time tracking**: `time_session`, `time_session_group`, `time_session_permission`
  (+ `time_sessions/`: `list_period`, the SINGLE owner of the eight period keys:
  order, labels and windows for BOTH the filter row and the status table. The four windows
  shared with `overview/time_period` are delegated there, as `KEYS &
  Overview::TimePeriod::KEYS`, so a widget drilldown reproduces its count.
  ⚠️ The list and table have different defaults, `this_month` versus `all`,
  and `custom` exists only in the list.) Alongside it, `list_filters`, the SINGLE declaration of
  the time list's filters (service attributes, removal, count, reset, hidden
  form fields). A new filter is an entry there; `list_filters_spec.rb` fails
  if `TimeSessionFilterService` knows an attribute missing from that declaration.
  * ⚠️ `time_session_permission` is a second permission ON TOP OF project membership: it
    ends with that membership (`ProjectPermission` callbacks, `Actors::RevokeProjectMember` on blocking,
    `Membership#destroy`) and counts only with a live `ProjectPermission` behind it
    (`backed_by_project_access`). `spec/architecture/time_session_permission_guard_spec.rb`
    rejects a bare read (as of 27 September 2026).
* **Knowledge/Communication**: `note`, `note_version`, `post`, `post_document`, `chat`, `chatpost`,
  `prompt_persona`, `chat_style_preference` (+ `knowledge/`)
  * ⚠️ `post` (= comment): ONE rule decides who may read a private comment,
    `Post.readable_by(user, organisation)` or `#readable_by?` (recipient, author, account admins;
    `PostPolicy` queries it). Anything ALL ticket readers see (activity excerpt,
    summary, AI answer) uses `public_posts`. `spec/architecture/post_visibility_guard_spec.rb`
    rejects a bare `ticket.posts` on read (as of 27 September 2026). The older
    `visible_to` (recipient only) has been deleted.
  * Since 30 August 2026, `chat_style_preference` stores a person's standing persona choice per org
    ALONGSIDE the style levels. ONE place decides which persona may be attached at all:
    `concerns/prompt_persona_selectable.rb`, included by BOTH `chat`
    and `chat_style_preference`. The prompt's resolution order (thread pin, then
    this choice, then `PromptPersona.default_for`) is defined in `ChatResponseJob`.
  * ⚠️ Two pools, not one, answering different questions. `available_for`
    is the authorization boundary (may this org hold the row at all) and carries
    VALIDATION; it must remain the broader one, or a row with an overridden persona
    becomes unsavable. `pickable_for` collapses by key,
    with the org row winning, and answers “which one currently applies” — the
    picker, write path AND `#resolved_persona` depend on it. Resolving a stored persona against
    `available_for` shows one thing in the interface and sends another to the model,
    without any indication of the discrepancy.
  * ⚠️ `chatpost#broadcast_completed` (S3a T4): answer completion branches by
    thread kind. Project threads still receive a `broadcast_refresh_to`,
    a PAGE refresh that is harmless on the chat page thanks to morph metadata.
    **Org threads must not do this**: their subscriber is the companion panel, which rides along
    on arbitrary pages without morph metadata, where the refresh would become a full replace visit.
    There, the PREVIOUS answer is replaced specifically instead (regenerate pill).
    Anyone touching this branch must check both sides.
  ⚠️ **Images in rich text**: every `has_rich_text :content` (Ticket, Post, Note, ConversationPost) includes
  `concerns/rich_text_embed_guard.rb` (enforced by a guard spec). The validator checks only the
  **delta** of a save (new blobs, new dead `sgid`s), identifies the type itself,
  strips `url`/`href` from attachment nodes (previously a non-expiring link), and enqueues
  `RichTextEmbedVariantJob` for each new blob. Only `rich_text_embeds.rb` owns the limits and type list.
  Plan: `doc/inline_bilder_spike_plan.md` (E1, D2 through D10).
  ⚠️ Its trigger `rich_text_content_changing?` answers from MEMORY
  (`association_cached?`), never through a query: `content.present?` loaded the text on every save
  of every owner (N+1 on bulk updates), and `association(...)` instantiates the
  association, which Rails' autosave validation then loads itself. Pin:
  `spec/models/action_text/rich_text_embed_guard_query_spec.rb`.
  ⚠️ Since Rails 8.1, RichText reassigns its `embeds` in memory on EVERY validation.
  The delta therefore reads the **persisted** attachments from the database
  (`persisted_embed_blob_ids`), never `content.embeds`: otherwise, a blob rejected by the first
  `valid?` passes the second (PDF, foreign organisation). The check uses
  `prepend: true` to run before autosave validation, because a blob without a file already raises
  `FileNotFoundError` there, and then stops validation with `throw :abort`.
  ⚠️ **Every image and mention identifier in the text is signed with `secret_key_base`** (the
  `sgid` in `<action-text-attachment>`, without expiry). If an instance gets a new key
  (move to a new server or clone with its own key), none resolve anymore: Rails displays `☒`, and on save builds `embeds` only from identifiers
  that resolve, thus detaching every image and deleting the file through a purge job.
  `concerns/rich_text_embed_retention.rb` (on `ActionText::RichText`, included through an
  initializer) therefore retains the persisted attachments while the text contains a dead identifier.
  **After every key change**, run `rich_text_embeds:resign_sgids` once (first
  `DRY_RUN=1`, no old key needed): it re-signs when the data alongside the text
  identifies the same target (image: this text's `embeds`; mention: the note's
  `outgoing_references`), reads the identifier only as JSON, never Marshal, and lists the remainder. A
  self-mention has no reference and is left untouched. Specs:
  `spec/models/action_text/rich_text_embed_key_rotation_spec.rb`,
  `spec/services/rich_text_sgid_resign_spec.rb`.
* **Conversations** (as of 25 November 2026: tables, models and the read rule; no route,
  page or writer yet): `conversation`, `conversation_participant`, `conversation_post`.
  Messages between members of ONE organisation, for example an agency and its client.
  * ⚠️ **ONE rule decides who reads a conversation: `Conversation.visible_to(user)`.**
    Both a participant row AND active membership in the conversation's organisation
    (plus the account itself: an erased account reads nothing, whatever it left behind).
    `#visible_to?` asks the scope and has no rule of its own. `#visible_participants` is
    the same rule from the other end (which participants can read now, as a relation of
    `User`). `ConversationPost.visible_to` merges the scope; `ConversationPolicy` asks only
    that scope. `spec/models/conversation_spec.rb` keeps the ends aligned.
  * ⚠️ **No project condition, no admin condition.** `project_id` is a label and appears in no
    authorization check: somebody with full project access who does not participate reads nothing.
    An account admin without participation reads nothing, not a title or a number: a conversation
    is correspondence between its participants. The shortcut “an admin sees everything” that
    other policies start with breaks the most important rule here. Guard:
    `spec/architecture/conversation_visibility_guard_spec.rb` (checks the rule and policy for both
    words and rejects every reader bypassing the rule; see the section in the root `CLAUDE.md`).
  * **Participation**: a row identifies an account (`user_id` is never empty) and ends by being
    deleted. There is no “ended” field that a reader could forget: a missing row cannot
    cause a leak. When the row is written, the participant is an active member of the
    organisation (`user_must_be_active_member`, only when `user_id` changes, the rule from
    `person`). If the member is later deactivated or removed, the row remains and can still
    be saved, and the read rule shows them nothing until their membership becomes active again.
    Nothing ends a participation yet, including account erasure.
  * **References stay within the row's organisation**: `conversation.project`,
    `conversation_post.invitation` and `conversation` on participants and posts are declared BEFORE
    `acts_as_tenant` and additionally enforced by `same_organisation_references`, even without
    a tenant or under another tenant (the tenant stamps `organisation_id`, not the
    conversation). The glossary's pattern, deliberately copied into each model. This is the only
    place in these three models that removes tenant scoping; the read rule never does.
  * **Post**: a message (`kind` `message`, text as `has_rich_text :content`, no
    `system_event`) or a system entry (`kind` `system`, a `system_event` key,
    no text). A system entry stores keys and IDs (`subject_user`, `second_user`,
    `invitation`), never a name or a sentence: names are read when displaying it, so
    no personal information remains in it after an account is erased. It writes no
    rich-text record or mirror (`skip_callback` on the model; asking for `content`
    would build an empty record). `KINDS` and `ORIGINS` are lists with `inclusion` and
    check constraints, not Postgres enums; `origin` says which channel a post came through,
    and only `web` is written so far.
  * **Deliberately absent**: no `Trackable` (no Activity, no feed), no `has_many :fragments`
    (no embeddings, search or assistant), no file attachments, no `archived_at` on
    the conversation (archiving belongs to a person, on their participation) and no
    association named `posts`: they are named `conversation_posts` and `conversation_participants`;
    a `.posts` belongs to ticket comments and their guard.
  * ⚠️ **Deletion goes through the model** (`dependent: :destroy`). The database cascade
    removes post rows, never their text in `action_text_rich_texts`. This also applies
    one level up: conversations are attached to the organisation only through the database
    cascade. No path deletes an organisation today; the first one that does must first destroy
    its conversations through the model.
  * **Plain-text mirrors**: `plain_text_version` and `plain_text_word_count` are written in ONE place,
    `concerns/rich_text_body.rb`, included by `post`, `note` and `conversation_post`. The position
    of the `include` determines its position in the `before_save` callback chain (`note` derives
    its Markdown immediately afterwards). Each host declares `has_rich_text` and
    `include RichTextEmbedGuard` itself, because the embed guard reads each file separately.
    All three hosts are pinned by `spec/models/concerns/rich_text_body_spec.rb`.
  * **Export and switch**: the personal export lists only data about the person's own messages and
    participations, by `user_id`, not through the read rule (`user_data_exports/registry.rb`,
    the guard's single allowlist entry): somebody who left a conversation or was deactivated
    still receives that data; somebody removed from the organisation receives nothing from it,
    as elsewhere in the export. `Conversations.enabled?`
    (`app/services/conversations.rb`, `LALABASE_CONVERSATIONS=1`) has no caller yet;
    models, policy and export never consult it.
* **Documents/Documentation/Codebase**: `document`, `document_version`, `documentation_*`
  (`documentation_asset` = an image from synchronized documentation, copied from the repository;
  the cached page references it by ID, served only through `FileDownloadsController`),
  `codebase_*`,
  `code_symbol`, `project_index{,_run}`, `project_repository`, `project_capability`,
  `project_layer4_vision`, `reference`, `fragment`, `imported_object`, `product_knowledge_entry`
  (Lalabase's own help text as a search table, tenant-free; see pitfall 3)
* **Meetings**: `meeting`, `meeting_participant`, `meeting_participant_claim_rejection`,
  `meeting_analysis` (Post visibility pattern: `is_private`+`visible_to_user`), `analysis_prompt` (org-wide prompt library)
  ⚠️ A meeting can move to another project (`Actors::MoveMeeting`). Every write path authorized against
  a project locks through `Meeting#lock_in_project!` and gives up on `false`;
  `spec/architecture/meeting_lock_guard_spec.rb` rejects a bare lock on a meeting
  (as of 24 October 2026, section in the root `CLAUDE.md`).
* **Not an AR model, but located here**: `acquisition_source` — value object over
  `accounts.acquisition` (a new customer's acquisition source). Owns channel priority
  ref > utm_source > referrer_host > direct in exactly ONE place (`doc/akquise_herkunft.md`).
  Likewise `assistant_panel_state` (S3a T4) — value object over the assistant's
  panel cookie. Owns the format, width limits and sidebar width in ONE place; the
  Stimulus controller receives MIN/MAX from it instead of maintaining its own numbers. ⚠️ The
  sidebar width is the twin of `w-64`/`lg:ms-64` in the application layout.
  Likewise `legal_identity` — the instance's operator and legal pages through four
  `SystemSetting` rows (`legal_*`). Sole reader and writer of these rows, validates
  URLs on save; `LegalIdentity.current` caches the state per request in `Current`.
  Likewise `provisioning/request_context` — request-shaped value object for `UserActivity.track!`
  when the separate website creates an account: it carries the VISITOR (address, program), not
  the website server. Not a service, hence here rather than under `app/services`.
* **AI/Billing**: `ai_credential`, `ai_usage`, `system_setting`, `personal_access_token{,_organisation,_project}`
  (`personal_access_token/reach.rb` = token contract as a value object, pinned against `#accessible_project?`;
  ONLY `#organisation_scopes` answers which organisations a token reaches, including for
  `all_organisations`, never the linking rows themselves; `#deactivated_member_of?` (K4c) grants no access,
  it only tells an entry point that a named organisation is absent because of deactivated membership, so
  the glossary rejects it as a missing permission, 403 instead of 404; since K6a (16 November 2026), a token has a
  `kind`: `personal` from the token page, `app_session` for a device. A device token always covers
  the whole account and permits writes (the model validates this shape); its `expires_at` advances with usage
  (`#record_use!`: 90 days from now, at most `#ends_at` = one year after `created_at`), while a personal
  token's expiry never advances. `.make_room_for_app_session!` revokes the least recently used device under a user-row lock
  (`FOR NO KEY UPDATE`, in one statement without validation) when an
  eleventh would be added, never a personal token. `kind` is read-only after creation (`attr_readonly`), and
  `#record_use!` does not touch a token that is no longer valid. No one may update a device token:
  `PersonalAccessTokenPolicy#update?`. Since K6b (16 November 2026), the sign-in entry point
  `/api/auth/v1` issues these tokens; `UserTrackable#track_login` accepts `login_method:` and
  `device_name:` for this, while the web form keeps `standard`. Since K6c (16 November 2026),
  `DELETE /api/v1/app_session` revokes the request's token; `#revoke!` now writes without validation because a
  token that no longer passes its own validation still authenticates; `track_logout` accepts `logout_type:`),
  `content_embedding` (sidecar vector per record per space), `embedding_space` (a vector space
  HELD by the org: triplet + encrypted credential snapshot; `organisations.active_embedding_space_id`
  determines which one serves search),
  `price_list` + `price_tier` (ONE published price version + its seat tiers: the time window
  belongs to the list, tiering to the tiers), `account_discount` (percentage discount per account,
  granted exclusively in the admin area; exactly ONE active, and an active one can only be
  ENDED, not edited). `price_list` and `account_discount` share `EffectiveDating`
  (time window + overlap rule) — **`price_tier` does NOT**; a tier inherits
  its list's window. `founder_signup` is the **application** for the new-founder discount, not
  its approval: it is created during registration, blocks nothing and is decided manually after a
  phone call — the discount itself remains an `account_discount`. Of its
  fields, only `phone` has a retention deadline (deleted after the decision, after 3
  months at the latest); company name and location are on the account anyway.
  See `doc/billing_preisliste_rabatt_plan.md`,
  `ai_usage_rollup` (one month of quota-relevant AI usage per org, booked to the ACCOUNT —
  the only copy that survives deletion of the org; `ai_usages` uses
  `dependent: :destroy`. Rows are **write-once**, `organisation_id` deliberately has
  NO FK, and the name is stored alongside it as a snapshot. Written by
  `Subscriptions::AiUsageAggregator` from two entry points: monthly job and
  `before_destroy` flush. See `doc/billing_agentur_konto_plan.md` §17.3b),
  `seat_event` + `seat_snapshot` (basis of seat billing,
  `doc/abrechnungsmodell_plan.md`; the four services above them are in `app/services/CLAUDE.md`
  under “The seat chain”). `seat_event` is **append-only** and enforces this (`readonly?` +
  `before_destroy { throw :abort }`); organisation, user and role are provenance without
  FKs, and the organisation name is frozen alongside them because the org disappearing is the
  normal case. Conversely, `seat_snapshot` is **derived and overwritable** — never align the two
  rules: a rollup's source is deleted, `seat_events` never are.
  ⚠️ Both deliberately do **NOT** use `acts_as_tenant` (pitfall 3 below): batch runs read them
  without a tenant; a default scope would silently filter out every row instead of raising.
* **Other**: `org_color`, `personal_task`, `user_data_export`, `user_deletion`,
  `mcp_idempotency_key`, `beuser` (admin login, NOT tenant-bound)

Pitfalls:
1. **Ticket `status` is NOT a column** — it lives in `custom_attributes` JSONB
   (`CustomAttributable` + `TicketAttributeDefinition` + `SystemFunctions`). The write path is
   `Actors::SaveTicket`, not `ticket.update!(status: …)`.
2. **Updates to Trackable models implicitly trigger the notification chain** — before changing
   Ticket/Project/Document/Note writes, read `docs/architektur/seiteneffekt_ketten.md`.
3. **`acts_as_tenant` on almost all models** — in tests, set the tenant BEFORE creating the model.
   Plain `.find` in jobs is not a tenant bug (the tenant is serialized into jobs).
   Deliberately tenant-FREE: `account` + `account_discount` + `price_list`/`price_tier` (billing sits
   above orgs, and `/pricing` reads without a tenant), `ai_usage_rollup` (survives the org whose
   usage it counts — a tenant scope would filter out precisely the rows it exists for),
   `seat_event` + `seat_snapshot` (same reason, read by batch runs without a tenant),
   `beuser`, `system_setting`, `ai_package*`, `product_knowledge_entry` (Lalabase's own
   text, identical for every org and read by the assistant from every tenant; a derived
   copy of the help files, `doc/product_knowledge_plan.md`).
   Adding `acts_as_tenant` there silently filters everything out without raising an error.
   ⚠️ Conversely: **an organisation can be destroyed only WITH a tenant set** —
   otherwise, its tenant-scoped cascades raise `NoTenantSet` (observed while building T17;
   the app still has no org-deletion path).
4. Boy Scout rule: when making substantial changes to a flat model belonging to a namespaced domain →
   move it into the namespace (keep `self.table_name`, no migration needed).
5. **`admin/*` are twins on the same tables without a shared save cycle** — a
   callback or concern only on the tenant side silently has no effect in the admin area
   (`spec/models/admin_twin_concern_parity_guard_spec.rb` checks the includes). Account
   deletion therefore has TWO implementations (`user/deletion_lifecycle.rb`,
   `admin/user.rb`, deliberately separate); only `concerns/personal_data_erasure.rb` deletes
   the records an account OWNS (export archives, private analyses and ticket posts,
   personal tasks, own chats, token revocation) for both.
   New data category → add it there, never in either method.
   `spec/models/user_erasure_path_parity_spec.rb` pins both paths and the resulting row.


## Bulk editing (8 September 2026, `doc/ticket_bulk_edit_plan.md`)

* `ticket_bulk_run.rb`: one run (changes in `change_list`, not `changes`: that belongs to
  ActiveRecord; results per ticket with prior values; `undone_at`, `undo_of`;
  `UNDO_WINDOW` 24 h; `undoable_by?` = executor or account admin).
* `Trackable#activity_context`: the SINGLE generic hook for bulk editing; see
  the bottom of `docs/architektur/seiteneffekt_ketten.md`. nil = current behavior.
* `Activity.feed`: feed without a run's ticket activities; ticket history reads
  without this scope.
* Slice 7: `ticket_bulk_run.kind` (`change`/`move`/`delete`, only `change` is undoable);
  `Activity.feed` filters `bulk_run_member` on EVERY Trackable (moving writes
  project activities); `ProjectTrackable#track_tickets_bulk_moved/_moved_in/_deleted`, and the
  deletion row carries `follower_ids` because subscriptions are deleted with the tickets.
