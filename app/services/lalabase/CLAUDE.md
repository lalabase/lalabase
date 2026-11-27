# Map: app/services/lalabase (as of 2026-11-08)

AI/RAG domain (product name “Lalabase”): everything related to LLM calls, embeddings and
codebase understanding.

* `llm/` — **Provider factory & gated seams**: `OpenAI::Client`/`Anthropic::Client` may be instantiated ONLY
  in the allowlisted seams (guard:
  `spec/services/lalabase/llm/direct_client_guard_spec.rb`). Reason: the GDPR opt-in gate
  (`organisation.ai_enabled`) + BYOK routing through `AiCredential` must not be bypassed.
* `tools/` — tool classes for Chat/MCP; convention `Klass.execute(args:, context:)`,
  sets (`:assistant`, `:assistant_with_code`, `:mcp`; `Registry::SETS` is the single list of all
  sets) in `tools/registry.rb`, guard `spec/services/lalabase/tools/registry_spec.rb`.
  Three read Lalabase's OWN help (`search_help`, `help_contents`, `get_help_page`,
  parent class `HelpTool`, only `:assistant`): no project, no coverage, language from
  `language_preference`, citation type `help_page` without an area (the answer remains unredacted),
  link `/hilfe/<slug>` through `CitationLink`. Links in the page text become “(help page <slug>)”,
  never `/hilfe` links: a link copied by the model opened inside the chat frame. Empty
  table = “unavailable” error, never “no page”. `help_contents` takes no arguments:
  `GoogleVertexProvider` sends such a tool without `parameters` because Gemini rejects an OBJECT with
  empty `properties` (the spec checks every chat tool). Plan: `doc/product_knowledge_plan.md`.
  Two read the people directory (`find_people`, `get_person`, parent class `PeopleTool`,
  `:assistant` and `:assistant_with_code`, People S3): no project and no coverage like
  the help, but a right of their own. `PersonPolicy.view_allowed?` is asked inside the tool
  BEFORE anything is read, else `refused` (a deactivated member too). They read through
  `People::Lookup` only (over `People::Directory`), never `Person.where`/`find`. The id is the
  format of `Meetings::ParticipantLinkChoice` (`person:<uuid>` for a contact, `member:<uuid>`
  for a member); unknown, foreign and invisible ids give the same `not_found`. Which fields
  reach the provider is decided only in `People::Lookup.row`/`.card` (never `notes`, E2; the
  last contact as date and kind, E3). Both cite type `person` (area `people`, no project, a content
  type): a contact by its row, a member by the account (`member_id`, the page sends it on to
  the row). `find_people` cites its first five rows, or an answer drawn on the list alone
  would carry no area and stay unredacted for others.
  `get_meeting` on `:mcp` is a twin as well (`McpGetMeeting`, R9, MCP 0.17.0), for a program
  behind a token such as Claude Code beside a meeting in the terminal client. Its gate is
  `Meetings::Readable`, the one `GET /api/v1/meetings/:id` asks (moved there from the REST
  controller when this second door came): missing, malformed, beyond the token, foreign or
  unreadable all answer `kind: empty` with one text, word for word. Unlike the assistant's
  capped read it carries the generated summary and gives summary, notes and transcript whole,
  in pages (`Meetings::TextPage`, 40,000 characters, cut at a line break near the end):
  Claude Code cuts a tool answer above about 25,000 tokens without saying so. Without `part`
  each part's first page is a third of a page, so the three stay within one; `part` and
  `offset` read on, `next_offset` is null at the end. Offsets count code points, as Ruby's
  String does; a page may end inside a grapheme cluster, which the next one continues.
  `get_glossary` (K4c, MCP 0.18.0, `:mcp` only, the last tool, no assistant twin) reads an
  organisation's glossary through `Glossary::Lookup`, the reader of
  `GET /api/v1/organisations/:id/terms`. `scope_mode :token`; `Glossary::Lookup.for_token` is its
  gate: an organisation outside the token, a foreign, a missing and a malformed id are all
  `not_found`, as REST's one 404 (not `invalid_input` like the people twins: one reader, one
  reading of the id); a member deactivated in an organisation the token names is `refused`
  (`glossary_forbidden`), REST's 403. Then the tenant, the glossary right (`refused`, the same reason,
  REST's text) and `authorize!`. `project_id` is its own argument (it reorders, it does not narrow),
  so `project_filter?` stays false; an unknown argument is `invalid_input`. The bounds of `page` and
  `per_page` are the reader's, not the schema's (no `minimum`/`maximum`): the SDK would refuse a value
  ahead of the right and in its own English, where REST answers after the right in the owner's language.
  The types stay the schema's: a value of another type (`null` included) the SDK refuses before the
  tool, as it does for every tool; `2.0` passes as an integer, and the reader takes it as 2.
  On `:mcp` the same two names are twins (`McpFindPeople`, `McpGetPerson`, People S3b, MCP
  0.13.0), own classes because their schema requires `organisation_id` (E3). `scope_mode
  :token`; `PeopleTool.with_token_lookup` is their gate: only an organisation whose every
  project the token reaches (`People::Lookup.for_token`, `Reach#project_ids_for(id).nil?`, E1),
  else `not_found` with `list_notifications`' wording, for a project-limited token, an
  organisation outside the token and a deactivated member alike (the token no longer reaches
  it); then the call runs under that organisation's tenant, asks the people right (`refused`)
  and marks `authorize!(context, Person, :index?)`, which reads the tenant: a twin run without
  it is refused, not served. Same JSON as the assistant (`FindPeople.list`, `GetPerson.read`),
  no citations, never the notes (E2: only the REST card carries them). A person that is not
  there is `kind: empty` (the MCP rule for one record, like `get_ticket`); the assistant keeps
  its `not_found`. The SDK refuses an unknown `kind` before the tool runs (schema enum).
  Scope per tool (`Base.scope_mode`): `:project` (default, dispatcher injects
  `project_id` as required, ToolCall gates the project) or `:token` (inbox workflow:
  no project gate, `Context#reach` = `PersonalAccessToken::Reach`, runs WITHOUT a tenant, only
  in the `:mcp` set, record mode; `list_notifications`, `mark_notification_read`,
  `list_organisations`, `list_projects`, the people twins, `get_meeting` and `get_glossary`,
  which set their organisation's tenant themselves). Inbox
  rows come from `Notifications::InboxQuery` + `Serializer`, shared with the HTTP API.
  Write tools exist only in the `:mcp` set: `create_ticket`, `post_comment`,
  `create_time_session`, `mark_notification_read`, `update_ticket`, `create_meeting`
  (token-scoped, sets the tenant itself; rule in `Meetings::Intake`, the same as
  `POST /api/v1/organisations/:id/meetings`). `create_time_session`
  books through `TimeSessions::Booking`, the same rule as the HTTP API (since 29 October 2026,
  REST R6); only arguments, permissions and texts remain in the tool. `post_comment` writes
  through `Actors::SavePost` like the web form (activity `post_added`, notifications,
  embedding); until 10 October 2026, a bare `Post#save` triggered none of these, likewise in
  `Api::V1::PostsController`. `update_ticket`
  (terminal client S2) changes exactly ONE kind per call (title, status or assignment,
  determined by the key present) and does not build its own write path: status and
  assignment through `Actors::ApplyTicketChanges` like the board and header menu, title through
  `Actors::SaveTicket` without `assignee_ids` (which replaces the list), under a row lock within the
  project (`SaveTicket` searches organisation-wide and builds a NEW
  ticket for a missing ID). Unknown arguments are `invalid_input`. Since REST R3b, the rule, write paths and
  result classification live in `Tickets::Change`, shared with
  `POST /api/v1/tickets/:id/changes`; the tool retains arguments, permissions, texts
  (`REFUSAL_TEXT`, `FAILURE_TEXT`) and response order: keys and
  encoding (`unreadable?`) first, then its own `ticket_id`, then the change
  (`update_ticket_order_spec.rb`). Deliberately flat schema, without `oneOf`:
  the Go client recognizes functions only through the top-level `properties`. `create_ticket`
  and `Tickets::Change` share title validation (`tools/ticket_title.rb`): one line, at most
  255 characters, invisible and control characters rejected, not sanitized.
  `post_comment` (MCP 0.11.0, terminal client S2b) takes optional `format`: `html`
  (default, unchanged ActionText input) or `plain`. `Posts::PlainTextBody` escapes
  literal text, normalizes CR and CRLF, drops blank lines at the edges, turns blank
  lines into paragraphs and single line breaks into `<br>`. Repeated spaces and
  indentation are stored but collapse in the web view; no Markdown. The rule is
  `Posts::Comment`'s since REST R3a, shared with `POST /api/v1/tickets/:ticket_id/posts`:
  invalid UTF-8 in either format and NUL in plain bodies are `invalid_input`, emptiness
  is decided on the converted text (a body of Unicode whitespace only is `body is
  required`). The tool keeps its own texts (`REFUSAL_TEXT`) and checks before the ticket
  lookup; model save failures stay `refused`, an unexpected one (`internal_error`) is
  `comment failed: unexpected error`, never the exception's text, unless it came after
  the commit: then the comment is written and the tool returns it.
  Two forms: `record` tools return
  rows and cite each one (ticket tools); `report` tools return only numbers and
  cite the report (`summarize_time_sessions`, citation type `time_report`). A
  report checks its permissions ITSELF where the area is too coarse: times go through
  `TimeSessions::ViewingScope` (own/all), and the `time_sessions` area remains set only for
  redaction (plan `doc/persoenlicher_assistent_plan.md` §6.4, §13-9).
  Since MCP 0.12.0 (terminal client S6), `summarize_time_sessions` is also in the `:mcp` set,
  as the last tool: project mode (`project_id` required, the seam checks the project and
  token reach), permissions through `ViewingScope` inside the tool, read tool (also for
  read-only tokens), no citations in the MCP response. The org-wide `project` field is also
  in the schema there but is ignored on the project path. Spec:
  `spec/requests/api/mcp_time_report_spec.rb`. Org-wide
  scope (S3a T3): `Context#scope` (`tools/scope.rb`, per area through
  `accessible_project_ids`) is ADDITIVE to `project` (R-M5, MCP unchanged); `Result#coverage`
  is the L7 coverage contract field. Ambiguous ticket numbers respond with the shared
  candidate list (`tools/ticket_candidates.rb`, §9.2).
  `get_ticket` reads pagination options and builds comment, attachment and individual pages through
  `Tickets::Reading` (`app/services/tickets/reading.rb`, REST R1), the same service as the
  REST ticket display. The tool retains only MCP-specific behavior: caps
  (`MAX_BODY_CHARS`, `MAX_FULL_TEXT_CHARS`, `MAX_ATTACHMENT_TEXT_CHARS`, assistant limit),
  `full_text`, `post_id`, citations. MCP clamps `posts_per_page` above 50 to 50
  (`over_max: :clamp`); REST rejects it with 422. A new pagination rule belongs in the service,
  not in either wrapper.
  `search_knowledge` reads through `Knowledge::Lookup` (`app/services/knowledge/lookup.rb`,
  REST R2), the same service as `GET /api/v1/projects/:project_id/knowledge`. The tool
  retains required `q`, lenient pagination options and citations.
  `list_organisations` and `list_projects` (MCP 0.15.0, `:mcp` only, the last two tools) name
  the ids the other tools take. `scope_mode :token`, reads for a read-only token as well. Both
  read through `PersonalAccessTokens::ReachListing`, the reader of `GET /api/v1/organisations`
  and `/projects`, so a new rule of the reach belongs there. `list_projects` keeps what is the
  tool's: archived projects only with `include_archived`, `not_found` for an organisation out
  of reach (REST answers 200 with `[]`), `per_page` of at most 100 clamped, a description cut
  after 500 characters. Not `ProjectPolicy#index?`: it refuses an active member without a
  project, who gets an empty list, so `Base.scoped_by_policy!` marks the decision of the policy
  scope. Every listed id passes the gate of `Mcp::ToolCall`: `openable_only`, which reads
  `ProjectAccessService.openable_project_ids`, because the policy scope alone is wider (a role
  holding nothing but time tracking sees projects there and opens none). Held over every role
  key in `spec/services/personal_access_tokens/reach_listing_spec.rb`, walked through the real
  gate in `spec/requests/api/mcp_list_projects_spec.rb`.
  Tool errors carry a classification: `Result.invalid_input(msg)` or
  `Result.refused(msg, reason:)`; without a code, `refused` applies, including a rejected save
  (model validation, actor error): that does not prove invalid input. Spec for each error location:
  `spec/requests/api/mcp_result_codes_spec.rb`. `Mcp::ToolCall` places them as
  machine-readable fields in `_meta` (`lalabase/kind` or `lalabase/code` + `lalabase/reason`), identical for
  “missing” and “foreign” (`not_found`). `kind: empty` means “the call found nothing”:
  for single-record tools, “not found”; for code searches, “no matches”;
  lists (`list_tickets`, `search_knowledge`, `list_notifications`) return empty results with `ok`
  and `data: []`. Anyone changing the `:mcp` set must regenerate the contract
  `spec/fixtures/mcp_contract.json` with `RAILS_ENV=test bin/rails mcp:contract` and bump
  `Mcp::Dispatcher::SERVER_VERSION` (minor); the contract spec only compares.
  The seam answers some errors itself, before any tool runs, in this order: `project_id`
  missing (`invalid_input`), a project out of reach (`not_found`), a write over a read-only
  token (`read_only`), then (MCP 0.13.1) an `idempotency_key` the store cannot hold: more
  than 255 bytes, no valid UTF-8 or a NUL (`invalid_input`). The key is remembered only
  after the write, so such a key used to write, fail with -32603 and write again on the
  retry. The rule is `Mcp::IdempotencyStore`'s, shared with the REST header; a read tool is
  not offered the key and ignores it. Guard: `spec/requests/api/mcp_idempotency_key_bound_spec.rb`.
* `indexer/` — codebase indexing (populates `project_index`, `code_symbol`, `fragment`)
* `project_rag/` — retrieval for project-scoped chats; org threads (S3a T3) use only the
  content layer through `Fragment.for_context_map` (project set narrowed per area)
* `github/` — repository integration (import only, no ongoing sync)
* `fence_guard.rb` — neutralizes Markdown fence breakouts (prompt-injection protection;
  spec: `spec/services/lalabase/fence_guard_spec.rb`)
* `llm/vertex_availability_probe.rb` — admin diagnostics: Vertex model availability
  (region×model) via free `:countTokens`; shares auth/endpoint class methods with
  `GoogleVertexProvider`. Deliberately NO quota seam (no inference, no org, no
  tenant content) and NO actor (read only); `Rails.cache` instead of a migration.
* `query_embedding.rb`, `repo_scope.rb`, `language_detector.rb`, `languages.rb`, `citations.rb`

Important:
1. **New AI callers must go through the quota seam** (metering/quota) — contract in
   `doc/ki_sourcing_kontingent_plan.md`. Without metering, usage bypasses billing.
2. Never hardcode an embedding model — resolve the provider through the factory (guard:
   `spec/services/embedding_provider_hardcode_guard_spec.rb`).
3. **Never pin a chat provider** — resolution follows the organisation's provider choice,
   and new code queries it through `Factory.for_feature(:key, org)` (since R6, the path for EVERY
   registered seam; raw `for_chat` belongs only to the connection test, see below);
   `Factory.build(provider_name: …)` overrides that choice. The choice is a
   GDPR decision (which jurisdiction sees the data?), not a preference. Guard:
   `spec/services/lalabase/llm/provider_pin_guard_spec.rb` with a shrink-only allowlist —
   **EMPTY since R3 (2026-08-02)**. It recognizes three
   entry points: `Factory.build`, `PROVIDER_CLASSES` and `<X>Provider.new` (allowlists for
   entry points 1 and 3 are empty; entry point 2 allows only the factory itself + two credential concerns).
   The one remaining pin (P5, `gpt-5-nano` is a reasoning model with its own
   wire dialect) is no longer in the service, but as `pin:`/`pin_reason:` in the
   `:customer_description` registry row; the seam builds it through its own
   bare `build(...)`, which entry point 1 does not match. Anyone who truly needs a pin must put
   it there — **the pin is then automatically paired with a refusal**, because the
   gate reads the same row. Previously, this depended on discipline and failed three times in one week.
   Plan: `doc/ki_provider_reichweite_plan.md`.
   **Gate and routing read the same registry row** (`llm/feature_registry.rb`,
   13 entries — one routing decision each, plan `doc/ai_feature_registry_plan.md`; since K5b,
   `:glossary_extraction` is the last row).
   Since R3, this is no longer merely theoretical (first production caller:
   `CustomerDescriptionGenerator`), and since **AI packages P3 (2026-08-02),
   six additional seams route through `Factory.for_feature`**: `TicketSummaryService`,
   `SummaryProcessingService`, `Meetings::ParticipantDetectionService`,
   `ProjectIndexerJob` (chat half, `lane: :chat`) and — through ONE line in
   `Meetings::BaseLlmService` — the three Meetings subclasses, each declaring
   a `#feature_key` for this. **Since R6, EVERY registered seam routes through its
   key** — including `ChatResponseJob` (`:chat`), `Actors::CreateAiPost` (`:ask_ai_post`),
   `EmbeddingProcessingService` (`:content_indexing`), `Lalabase::QueryEmbedding`
   (`:semantic_search`) and the embedding half in `Indexer::JobSupport`
   (`:repository_indexing, lane: :embedding`). The raw lanes remain with exactly two
   callers: the connection test (`for_chat`, no feature) and
   `OrganisationReindexer` (`for_embeddings`, must run when feature gates say
   no). A new pin belongs in the registry, never in a service.
   * **`utility: true` on a registry row** (P3, `doc/ki_pakete_plan.md` §2.1):
     utility paths use the LOWEST package tier instead of the org's chosen one —
     a code property of the path, not a customer setting, and **not a
     provider decision** (E7): the package and thus the jurisdiction stay the same; only the
     model within it becomes cheaper. Five rows carry it (`ticket_summary`,
     `document_summary`, `meeting_participant_detection`,
     `meeting_ticket_suggestions`, `repository_indexing`). With `kind: custom` /
     `ai_package_id IS NULL`, there are no tiers — the flag changes nothing there.
     The tier travels as the `utility:` kwarg through `chat_provider_name` /
     `curated_chat_credential` / `resolve_credentials` **and through
     `has_valid_ai_configuration?`**: two tiers can use different providers,
     so a gate without the kwarg evaluates a different row from the one the
     request uses. `pin:` + `utility:` on the same row raises on LOAD
     (contradictory, no defined precedence rule).
     `:glossary_extraction` (K5b, 8 November 2026, seam `Glossary::Classifier`) is a chat row and
     deliberately NOT utility: distinguishing an organisation's specialist terms and names from ordinary words
     is the product itself here, so it runs on the organisation's own tier.
     The utility list remains at five.
   * **`organisation.ai_available_for?(:feature_key)` is THE path for a gate** and the
     only one that can also name the reason (`Availability`: `available?`, `reason`,
     `required_provider`, `lane`). Routing counterpart:
     `Factory.for_feature(:feature_key, org)`. A typo in the key raises `KeyError` —
     a gate must never answer “unavailable” because the key was wrong.
   * **The refusal TEXT has exactly one source**: `FeatureRegistry.unavailable_hint(availability, org)`
     (R3). Maps `reason` → `shared.ai.unavailable.<reason>`, interpolates display names
     instead of routing keys, and answers `:ai_disabled` with the canonical
     `shared.ai.disabled_member_hint` (E4: reuse, do not fork). Callers
     decide only WHICH reasons they explain — the `:customer_description` view,
     for example, explains only `:pinned_elsewhere`, because the pin text would send an admin who merely lacks a
     credential to the wrong page. No manual `t('shared.ai.unavailable.…')`.
   * `ai_configured_for_chat?` (configuration only) **no longer exists** (P3): the
     predicate derived the ORG's tier, but its four callers
     (`TicketSummaryService` + the three summary entry points in
     `tickets/_ticket_content_for_frame`) route on the UTILITY tier — with
     two tiers on two credentials, it therefore answered about a credential the
     request never touches (wrong in either direction). All four now ask
     `ai_available_for?(:ticket_summary)`. Anyone who, like this service, needs to **distinguish two
     states** maps them from `availability.reason` (there:
     `TicketSummaryService#unavailable_status` — `:ai_disabled` keeps its own
     interface, every other reason shares the setup modal). The underlying rule:
     only the interface itself knows how many states it can display.
   * `ai_available_pinned?`/`ai_pinned_elsewhere?` (S4 pair) **no longer exist** (R3):
     both questions are the reasons `:pinned_elsewhere` or `:no_credential` in ONE
     answer. The registry checks the pin BEFORE the credential — exactly the distinction
     for which the pair needed two predicates.
   * `ai_available?(provider)` has had **no production caller** since R3 (the last
     was the S4 pair). Retained as a low-level API and the comparison side of the equivalence matrix
     (`spec/models/organisation_ai_availability_spec.rb`) — E3. No gate builds on it anymore.
   * **R5 guards (2026-08-03, `feature_registry_guard_spec.rb`)**: Guard A —
     `Factory.for_chat`/`for_embeddings` only in the file allowlist (the factory itself
     calls without the qualifier and needs no entry); Guard B — every `seam:` row exists and actually
     routes; routing outside its own seam file counts ONLY through the justified
     ancestor list (`BaseLlmService`, `JobSupport`) — blanket inheritance would be a
     free pass for base classes such as `application_job`; every routing file is a seam
     or has a justified entry in `FeatureRegistry::EXCLUDED_CALLERS`
     (`embedding_space_for` in `UNGATED_RESOLUTIONS`, plan §7.5); Guard C — nothing
     outside its two owners (`organisation.rb` defines, `feature_registry.rb`
     consumes) calls the low-level predicates; the interface allowlist also remains
     empty under plan E3 (this is why the two local controller methods are named
     `ai_feature_available?`). All three + `provider_pin_guard` + `action_registry_guard`
     have run in CI (`guards.yml`) since R5.
     **Four things a presence guard does NOT see**, hence their own
     checks (review follow-up 2026-08-03): Guards A and B scan **templates
     too** — an `.rb`-only glob left `Factory.for_chat` in a view green;
     the patterns recognize **`Factory::for_chat`** (valid Ruby, currently zero call sites —
     thus a silent gap); Guard B checks not only THAT a seam routes, but
     **through WHICH row**: the literal key at the call site, or the `#feature_key`
     read by the inherited call site in `BaseLlmService`, must identify its own registry row
     (without this, a Meetings subclass could route through another row
     while its gate queried the right one); and **all four exception lists carry
     `calls:`** (the two lane allowlists, `EXCLUDED_CALLERS`, `seam_routing_ancestors`) —
     an exception excuses a FILE; without a count, that file can accumulate any number of
     further calls under the same justification. All counts are currently 1; a
     change is a diff someone reads.
   * `ai_available_for_chat?` **no longer exists** (R2, 2026-08-02): its 11 callers
     now ask their own feature key. Currently, all unpinned chat features answer
     identically — the key therefore documents semantics until packages/R3 make them
     diverge. **A wrong key is thus invisible in production**, which is why each
     of the 11 locations has its own mutation guard: a spec that refuses exactly ONE
     registry row and leaves a second untouched. Fully verified —
     changing each of the 11 locations to a foreign key breaks at least one example:
     `meetings_spec` (“feature keys (R2)”), `meeting_analyses_spec` /
     `meeting_ticket_suggestions_spec` (key-scoped `stub_ai_availability` —
     **never without `with`**; a blanket stub answers for every key and blinds the
     file), `meeting_detect_participants_spec` (“feature key (R2)”),
     `ai_surface_gating_spec`, `user_preferences_spec`.
4. The organisation's `ai_enabled` gate applies to EVERY LLM call — no call without opt-in.
   **One deliberate exception, not an oversight:** `Llm::Factory.embedding_space_for(org)`
   (embedding v2 PR 4b) resolves ONLY the vector-space triplet for a LOCAL database read
   (`Embeddings::NearestNeighbors`) — no data egress, no API costs. Therefore, no
   `ai_enabled` or quota gate: an exhausted quota must not disable search.
   Pinned in `spec/services/lalabase/llm/factory_spec.rb`; `for_embeddings` (write path)
   remains gated as before.
4. **`space:` is a required kwarg** on `for_embeddings` and `embedding_space_for` (v2 PR 6a):
   `:configured` = where NEW embeddings go, `:active` = which space serves search.
   Deliberately no default — either possible default would have a SILENT failure mode;
   `ArgumentError` does not. Reads (`QueryEmbedding`, `NearestNeighbors`,
   `PowerSearchService`, `SpaceAlignment`) use `:active`; write/build paths use
   `:configured`.
5. **`model:` on the embed call is essential, not decorative** (v2 PR 6a): `OpenAiProvider` and
   `GoogleVertexProvider` answer `#default_embedding_model` from a CONSTANT and
   ignore the configured model (intentional for Vertex — `default_model` there is the
   CHAT model). Anyone serving a space whose model differs from the constant MUST pass the model
   explicitly; otherwise, the vectors silently come from the wrong model.
   Affects `QueryEmbedding.embed` and `OrganisationReindexer#reembed_batch`.
6. **The metered embed path is the only one** (AI packages P4a+): `#embed` delegates to
   `#embed_with_usage`, `#embed_batch` to `#embed_batch_with_usage` — ONE call site per
   form, so an unmetered caller cannot route around the counter. `OpenAiProvider`
   implements a true batch variant (reads `response['usage']`); the base class falls back
   to `texts.map { embed_with_usage }` — the Vertex path (one `:predict` per text).
   ONE `AiUsage` row is recorded per run, not per batch (`UsageTracking`).
   ⚠️ `Indexer::SymbolPersistence` still uses `embed_batch` and records NOTHING — known
   legacy debt, untouched by P4a.
7. **`max_tokens` is the ANSWER budget** (since 2026-10-26). A model that reasons first
   gets a reserve added by the provider: `GoogleVertexProvider::THINKING_BUDGET`
   for Gemini 2.5 Flash and Pro (`thinkingConfig` + `maxOutputTokens`),
   `OpenAiProvider::REASONING_RESERVE` for gpt-5 and the o series (`max_completion_tokens`).
   Without a reserve, reasoning tokens counted towards the limit, leaving
   almost nothing of a short answer. A caller never adds a reserve itself; provider fields
   (such as `reasoning_effort`) are sent only by a seam with a registry pin (`:customer_description`).
   If an answer ends at the limit (`stop_reason 'length'`), it is truncated:
   `Meetings::BaseLlmService` then reports the `truncated` error instead of saving
   the partial text. If no text arrived before the limit, OpenAI, Vertex and Anthropic raise
   `Provider::TruncatedError` (a subclass of `Provider::Error`, with the result including
   usage); `BaseLlmService` records the usage and likewise reports `truncated`. If the
   provider rejects the request (400, for example a model with an output limit below the
   analysis's 8,000 tokens or a context window that is too small), OpenAI, Vertex and
   Anthropic raise `Provider::RequestRefusedError`; `BaseLlmService` reports `request_refused`
   or, for own access, `request_refused_own_access`, never “try again later”. ⚠️ The assistant
   (`Tools::Runner`) and participant detection do not yet evaluate `'length'`.
