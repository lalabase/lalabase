# Map: app/controllers/concerns (as of 2026-11-20)

> For the ticket **domain** (attribute system, Kanban, actors, pitfalls), also consult
> `docs/architektur/tickets_lesepfad.md`. This map describes only the **stack**.

This directory contains the **ObjectListController stack**, which drives list features (especially tickets).
Reading order for understanding a list page:

1. `object_list_controller.rb` (~470 LOC) — defines its own default `index`/`show`, transitively includes
   `Sortable`, `Pageable`, `Searchable`, `AdHocFilterable` via
   `included do`, and registers 5 before_actions (`set_project`, `set_objects`, `set_object`,
   `authorize_project_access`, `set_smart_folders`) that are NOT visible in the including
   controller. Since 8 September 2026, `filtered_objects` (folder, then ad hoc, search,
   sorting) is the SINGLE owner of the filtered list: `index` paginates it, and
   bulk editing (`doc/ticket_bulk_edit_plan.md`, S0) resolves “all matches” from it. Kanban,
   `show` and page calculation still reproduce the pipeline manually (finding in the
   reading guide, separate workstream).
2. **The including controller may override `index`/`show` — TicketsController does.**
   Always read BOTH versions (concern default + controller override) to get an accurate picture.
3. Frame IDs and partial paths are built through string interpolation (`results_partial_path`,
   `object_show_partial`, `results_frame_id` — including the hardcoded ticket special case
   `tickets_list_frame`). Do NOT search for frames/partials by literal grep — evaluate these methods.
4. `sortable.rb` (~390 LOC) — whitelist sorting DSL (`setup_sortable`, `add_sortable_columns`),
   ORDER BY via `Arel.sql`, hardcoded DISTINCT-JOIN special cases per table.
5. `ad_hoc_filterable.rb` — reads `filter[]`, `filter_op[]`, `filter_drop[]`. Since the
   filter-bar redesign (S3a, `doc/filterleiste_s1_s4_plan.md`), the rule is: if the URL contains a
   resolvable saved view AND changes to it (`edited_saved_view?`), the
   list applies the EFFECTIVE set (`list_filter_params`) instead of folder query ∩ URL. The same
   rule lives on the client in `lib/filter_bar/change_set.js`; anyone changing one side must change
   both. Folder-query callers check `edited_saved_view?` (`apply_smart_folder_filter`,
   `TicketsController#find_objects`, `KnowledgeController#index` via `apply_folder_query`).
6. `ticket_list_columns.rb` (7 September 2026, `doc/spaltenwahl_plan.md` S1): ONE method,
   `ticket_list_columns(project)`, for every stream that rerenders a ticket row or the list outside
   `index` (Tickets + Posts). Calls `Tickets::ResolveColumns` (URL `cols[]` takes precedence over
   folder, then base view). Previously, the two controllers calculated this manually in six places.
   Since 8 September 2026, also `ticket_list_selectable?` (helper_method, memoized per request): whether the
   row has a selection checkbox (`doc/ticket_bulk_edit_plan.md`, slice 1).
   Since 29 September 2026, also the row stream itself: `ticket_list_row_streams(ticket, selected_ticket:)`
   (desktop and mobile row, each with its own partial). Anyone streaming a ticket row uses this
   method. Since 30 September 2026, also `Tickets::RelationsController` (“Waiting” column, card and
   mobile row of the OPEN ticket after adding/removing a relation). No one streams the row of
   ANOTHER ticket there, including a waiting ticket's row when its
   blocker is completed (`doc/ticket_relations_plan.md` §4, `ticket_waiting_visibility_spec.rb`).
   It appends `ticket_list_parent_streams` (only on quick-add and deletion): for each
   column in `ViewConfiguration::CHILDREN_COLUMN_KEYS` (currently `subtask_count`), ONLY the cell and
   entry below the parent ticket's title (also the old parent's on a move), never its entire row.
   A full row needs information only `index` knows (the active folder's columns, which no form
   submits; unread notifications), and lost both. This is why “no value” for the
   entry below the title is called `:empty` (CSS); `hidden` means only “not pinned”.
7. The rest: `pageable.rb` (without a gem since 18 November 2026: `#paginate` passes page and page size to
   `Pagination::Page.of`; map in `app/services/CLAUDE.md`; a new application list
   paginates through this, never through its own calculation), `searchable.rb`,
   `viewport_switchable.rb` (mobile/desktop switching), `project_controller.rb`
   (project-scoping base, used by MeetingsController, for example), `ai_feature_gate.rb`
   (`ensure_ai_enabled`, org level; extracted from `project_controller.rb` in S3a T2
   so the projectless Assistant controllers can use the same gate),
   `meeting_in_project.rb` (24 October 2026: `with_meeting_in_project { ... }`, the controller-level lock
   for a meeting write path; section on `Meeting#lock_in_project!` in the
   root `CLAUDE.md`; the guard checks every write action of the meeting controllers),
   `organisations/management_return.rb` (11 November 2026, in `Organisations::BaseController`):
   on entering management, remembers the app page the person came from for “‹ Back”
   in the management sidebar. ⚠️ A `before_action` must never call `helpers` here: the proxy
   is memoized and would retain the instance variables from that moment (before the subclass's `@project`
   and others); `NavigationHelper.section_key_for` answers the section question.
   `account_return.rb` (15 November 2026, in `ApplicationController`): the same for the account area,
   “Back” on an account page (`NavigationHelper#account_return_path`). It remembers the first account page's Referer;
   another account page retains it, entry from elsewhere replaces it, and
   without a valid Referer it falls back to `user_home_path`. `NavigationHelper::ACCOUNT_PAGES` identifies
   account pages (module function `account_page?`, no `helpers`).
   Both share `return_path.rb` (`ReturnPath`): same host, a path only, never a path starting
   with `//`, the single size limit `MAX_RETURN_PATH_BYTES` for the session cookie.
   A third return-path implementation must include `ReturnPath` instead of copying the checks.

Alongside these are **patches to Rails' own controllers**, attached through a `to_prepare`
initializer rather than an `include` in an application controller: `direct_uploads_guard.rb` →
`ActiveStorage::DirectUploadsController` (initializer `config/initializers/direct_uploads_guard.rb`,
pattern: `active_storage_tenant_patch.rb`). These controllers inherit from `ActionController::Base`,
not `ApplicationController`; none of the application's `before_action` callbacks apply there, so every rule must
be added explicitly.

Current state (deliberately documented): The five master-detail features use five different
foundations — Tickets = this stack, Knowledge = `Pageable`+`AdHocFilterable`+
`ViewportSwitchable`+`ProjectController` with `KnowledgeSearchQuery` (UNION over
`Knowledge::TypeRegistry`, no `ObjectListController`), TimeSessions = `Sortable`+`Pageable`
directly, Notifications = bespoke + `MasterListPresenter`, Meetings =
`ProjectController`+`ViewportSwitchable`+`meeting_list.rb`.
`meeting_list.rb` (17 October 2026) is the SINGLE owner of the meeting list: project page
(`meeting_list_project` = `@project`) and “All meetings” (`nil`). Since PR 3, the
overview also opens the meeting in the lane; details and write paths remain nested under the project
(`MeetingsController`), and the lane carries `list_context=organisation`
(`Meetings::ListState`, one allowed value, only compared). It is carried in two ways: the
server writes it into links and forms rendered for a request WITH context
(`meeting_lane_state`), and `layout-toggle` appends it to every lane request on click and submit
(`laneContext`, from `meeting_list_page_data`). The second catches anything rendered without context:
broadcasts, section updates, controller replacements. `meeting_organisation_list?`
is the SINGLE question “which list?” for streams, redirects and return paths (the former
`context=overview_modal` has been incorporated into it). Since PR 4, the overview's “+” also opens in
the lane: `?new=meeting` at its own URL returns a project picker
(`meetings_overview/_new_meeting_lane`); below it, a separate frame loads the chosen project's
form from `MeetingsController#new`. There is no meeting route without a project. The context selects only the
list; permissions remain those of the project (`set_meeting`, area gate). A
meeting view belongs to its project's list, or to the overview without a project. The filter bar, saving views and column selection
accept `project: nil` as “organisation-wide”; Tickets and Knowledge still pass a project.
`ViewConfiguration.for_list` selects the base column view (without a project, only `meetings`,
route `meetings_view_configuration`, the same controller as the project route).
The people list (`Organisations::PeopleController`, 26 October 2026) is the sixth lane:
`ViewportSwitchable` + `People::Directory`, without a filter bar or column selection, the same
Stimulus controllers (`layout-toggle`, `index-page`, `list-row`, `lane-link`); save and
delete leave the lane (`_top`) and return to the list with `?person_id=`. Two
selection parameters are mutually exclusive: `person_id` (a row) and `member_id` (a member without
their own row, `PeopleController#member`); `user_id` belongs to the form group.
Since 17 November 2026, the page has a fourth lane state: `?edit=<person id>` opens a
row's form on a full-page request (the entry from outside: the pencil on a card
above the organisations; `#edit` without a frame redirects there). Only for a row in the
policy scope that the reader may edit; everything else (read-only user, foreign, hidden or missing
row, malformed ID) shows the list, and the parameter is listed among the unresolved ones
(`people_unresolved_lane_params`), just like an unreadable `person_id`. `person_id` and
`member_id` take precedence over `edit`, and `edit` over `new`. ⚠️ The lane scripts recognize `edit`
only where the URL contains it (`PeopleHelper#people_form_params`): nothing on the page
writes it; it arrives with a request. The exit from a form opened this way
is a page request with the person open (`@form_cancel_url`), so the URL no longer
says “edit”. Guard: `spec/requests/organisations/people_edit_state_spec.rb`.
Since 17 November 2026, people above the organisations (`AllPeopleController`, `GET /people`)
are the eighth lane, with the same Stimulus controllers: `?card=<organisation id>:<entry address>`
(never `organisation_id`) opens a person's card; the lane requests the
page's own URL with its frame's header (`all_people_card`) and receives only the card.
An address identifying no one gets ONE response (404). The row is a table row
(`list-row` on the `<tr>`, checkbox and menu carry `no-click`). ⚠️ In the list column,
the ticket table's rules affect every table (`layout.css`, `.list table`: one row height,
clipped cells); `.all-people-table` overrides them for itself.
The glossary (`Organisations::GlossaryController`, K4a, 4 November 2026) is the seventh lane, built
like the people list (the same Stimulus controllers and `people-*` classes), with `term_id` as
the only selection and the filters `project_id`, `category`, `status` (`LIST_PARAMS`, unknown
values are discarded). Meeting titles only through `policy_scope(Meeting)`, never preloaded. A speaker
has a name only if the reader may see it on the members or people page
(`MembershipPolicy::Scope`, `PersonPolicy::Scope`); otherwise a neutral word appears. Links require
`view_people` and point only to active members (the people page lists only those).
The decision on ONE canonical list architecture is still pending; until then, new
list features must follow the most similar existing feature and explain the choice in the PR.
Since 10 September 2026, Tickets and Knowledge at least share the list-with-lane INTERFACE
(`doc/wissen_als_bahn_plan.md`): `NeoTwoColumnGridComponent` with `lane: true`, the single
opener `list_row` (URL rules in `lib/list_row/address.js`), the `.selected-row` highlight
and the lane header. The underlying list foundation still differs by area.

## Mobile ticket display (PR #807)

`ViewportSwitchable` accepts the explicit `viewport` parameter. Only
`TicketsController#set_viewport_mode` evaluates the `X-Viewport` header.
This must not switch other lists to the wider ticket breakpoint.
The mobile list uses `tickets_list_frame`, and the detail uses `ticket_display_frame`,
as on desktop. `ticket_display_frame_mobile` no longer exists.
Mobile full-list requests retain their page number; the existing
desktop page-1 redirect remains. Ticket and Post streams must handle mobile
list rows as well as table rows.

## What counts as a page: `full_page_request?` (since 14 November 2026)

`ApplicationController#full_page_request?` is the SINGLE answer to “is a page being
opened”: GET or HEAD, requests HTML, no Turbo Stream (`text/vnd.turbo-stream.html` counts
as HTML to Rails, hence the explicit exclusion), no script (`xhr?`), no `Turbo-Frame` header, and
the controller serves pages (`serves_pages?`, true by default). Three consumers:

* `load_tenant_from_session` still sets the tenant from the URL on EVERY request, but writes
  `session[:current_organisation_id]` only for an organisation page with active
  membership. A frame, write, stream, JSON response or file under `/org/B/`
  operates in B while leaving “Back to organisation” and
  help where the person is (the combined inbox's lane, `doc/cross_org_inbox_s3_plan.md` §5.1).
  `OrganisationsController#redirect_to_organisation` and `Users::SessionsController` still write
  the session themselves.
* `Organisations::ManagementReturn#remember_management_return` remembers the return path only for
  a page in the management area.
* `page_above_organisations?` (combined inbox): A page declares its own context. A fragment
  (comment, ticket edit, frame from the `/inbox` lane, answered by an
  organisation controller) retains the context of the page into which it is rendered, identified by the
  referrer: same host, same port, exactly the path `/inbox`. Otherwise, the fragment renders
  the assistant button into a page without an assistant. Every near match (different port,
  an organisation's inbox, malformed URL) leaves the fragment in its ticket's context.
  Guard: `spec/requests/all_inboxes_lane_spec.rb` (“assistant context after lane writes”).
  Since 16 November 2026, a second page declares this context: people above the organisations
  (`AllPeopleController`, `GET /people`). Since 17 November 2026, its card embeds an organisation
  fragment (the “Copy to another organisation” dialog,
  `Organisations::PersonTakeoversController`), and the referrer rule recognizes both paths,
  `/inbox` and `/people`. Guard: `spec/requests/organisations/person_takeovers_spec.rb`
  (“the dialog on the people page above the organisations”). When opened from there
  (`from=all_people`, `PersonTakeoversController::FROM_ALL_PEOPLE`, a word, not a URL),
  every dialog response returns to a card there, never to an organisation's
  people page. ⚠️ Any additional page above the
  organisations that displays fragments from an organisation controller must be added to this list;
  otherwise, the fragment renders the assistant button into a page without an
  assistant. A new page above the organisations also needs an entry in
  `NavigationHelper::LEVEL_PAGES` (guard: `spec/architecture/sidebar_mode_guard_spec.rb`)
  and must never call an organisation parameter in its URL `organisation_id` (here: `org`).

`InboxLane` (`inbox_lane.rb`, both inbox controllers): since S4a
(14 November 2026), the lane loader asks `Inbox::LaneKind` what the row opens instead of “is it a ticket”. States:
`:ticket` (inline), `:kind` (subject with its own display in the inner frame, after
`authorize target, :show?`), `:card` (event card), `:unauthorized`, `:non_ticket` (no
entry), `:missing`. ONE partial (`organisations/notifications/_pane`) renders the first three.
The including controller provides `filter_params` (the lane request's list state, for the
redrawn row's bundle size). A note's inner frame is rendered by its own
controller and checks the switch above through the referrer, like any fragment.

A controller that does not serve pages declares this itself (`serves_pages?` → `false`), currently
`Organisations::FileDownloadsController`: an image makes a request like a page. No comparison of
controller names in `ApplicationController`. A single file action in a page-serving controller
makes this declaration for itself: `DocumentsController#download_plain_text` (since S4b, 14 November 2026: the document
is in the `/inbox` lane, on a page outside its organisation, and the
“Text version” link requests it without Turbo like a page). Known and accepted: the time-group CSV export
counts as a page; it appears only on pages of the same organisation. A form outside
all frames that responds with a redirect counts only from the next click (Turbo follows with
Stream-Accept); accepting an invitation (`AcceptInvitationsController#update`) therefore also lands
in the new organisation without changing the session until the first page there. The rule determines only where a return path leads,
never a permission. Guard: `spec/requests/session_organisation_follows_pages_spec.rb`.

`Api::TokenAuthenticatable` (`api/token_authenticatable.rb`, `/api/v1` and `/api/mcp`): authentication
through an access token. A token works only while its owner is allowed to sign in; otherwise,
it returns the same 401 as an unknown token. `PersonalAccessToken#record_use!` records usage at most once per minute
(since K6a, 16 November 2026): `last_used_at`, and for a device token
(`kind` `app_session`), in the same statement, the expiry that advances with usage. Changing the
throttle also changes how often a device extends its expiry. Guard:
`spec/requests/api/v1/me_spec.rb` (“with a device token”).

The clients' sign-in entry point (`Api::Auth::BaseController`, K6b, 16 November 2026) uses NONE of these
concerns: no `Api::TokenAuthenticatable`, no `Api::V1::Idempotent`, no Pundit. It shares only the
error shape (`Api::V1::ErrorBody`). Guard: `spec/architecture/auth_api_contract_guard_spec.rb`.
Sign-out (`Api::V1::AppSessionsController`, K6c, 16 November 2026), by contrast, goes through all `/api/v1` concerns:
token, read-only gate, Pundit, `idempotent :destroy`. ⚠️ Plus the one `/api/v1` step BEFORE token authentication
(`replay_stored_sign_out`): signing out revokes the token a retry would use, so
this action looks for its stored response first, only for a revoked token, its own key and
the same request. Do not extend this to other actions (`spec/requests/api/v1/app_session_spec.rb`).
