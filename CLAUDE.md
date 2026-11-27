# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Project Structure & Architecture

### Core Domain Models
- **Account**: Billing entity ABOVE organisations (bundles orgs for billing; tenant-independent, owner ≠ org data access — see `doc/billing_agentur_konto_plan.md`)
- **Organisation**: Multi-tenant root entity
- **User**: Authentication + tenant membership via roles
- **Project**: Container for work items within organization
- **Ticket**: Work items with status, assignments, comments
- **Document**: File management with versions
- **TimeSession**: Time tracking with project/ticket association
- **Notification**: Real-time notification system with channels
- **Activity**: Audit trail for all model changes

### Key Architectural Patterns
- **Multi-tenancy**: Every model scoped to Organisation via acts_as_tenant
- **Component-based UI**: ViewComponent + Stimulus hybrid architecture
- **Activity Tracking**: Automatic audit trail via callbacks and observers
- **Notification System**: Event-driven notifications with fanout service
- **Service Objects**: Complex business logic encapsulation
- **Background Processing**: Solid Queue (the only job backend; Sidekiq has been removed)

---

## Build & Test Commands

* **Runtime**: Ruby 4.0.10 (`.ruby-version`), Rails 8.1.4.1, `config.load_defaults 7.2`.
  CI reads Ruby from `.ruby-version`.

* **Development server**: **two processes required** — `bin/dev` (Tailwind watch + Solid Queue via
  `Procfile.dev`) AND `bin/rails server -b 0.0.0.0`. `Procfile.dev` contains **no** `web:` entry
  (removed in `9e4673fc`), so `bin/dev` alone does not start the application.
* **Background jobs**: Jobs run automatically with Solid Queue in development
* **Run tests**:
  * All tests: `rspec`
  * Single file: `rspec spec/path/to/file_spec.rb`
  * Single test: `rspec spec/path/to/file_spec.rb:LINE_NUMBER`
  * With debug output: `RAILS_LOG_LEVEL=debug rspec ...`
* **JS tests** (pure Stimulus libraries/parsers via Node `node:test`, no Chrome required): `npm test`
* **Python tests** (`bin/lala`, in-process fake MCP endpoint, standard library only):
  `python3 -m unittest discover -s spec/python -p '*_test.py'`
* **Product screenshots** for the project website: `MARKETING_SCREENSHOTS=1 bundle exec rspec spec/marketing/screenshots_spec.rb`,
  output in `tmp/screenshots/marketing/<locale>/`, excluded from every normal run. The README's
  four pictures are copied from there by hand to `.github/readme/`; then
  `bundle exec ruby script/readme_gallery` redraws the framed tiles of its gallery.
* **System/JS tests on an ARM machine** (Parallels VM): `selenium-webdriver` ships only
  an x86-64 `selenium-manager` binary for Linux, but a universal binary for macOS.
  On aarch64, the kernel rejects it and `/bin/sh` instead reports
  `1: Syntax error: "(" unexpected`, without mentioning the architecture. Remedy: install chromedriver
  from the distribution (`sudo apt install chromium-driver`) and, if it is not in
  a standard path, set `CHROMEDRIVER_BIN` (and `CHROME_BIN` if needed).
  Resolution is owned by `LocalChrome` in `spec/support/capybara.rb`, guard:
  `spec/architecture/chrome_driver_binary_guard_spec.rb`. None of this applies on Mac;
  Selenium Manager remains responsible there.
* **CI**: `.github/workflows/guards.yml` runs six jobs on every PR, with no path filter
  (not on a push to main, and a new push cancels the superseded run; by hand via
  `workflow_dispatch`, reasons in the workflow header):
  `guards` (curated specs plus `browser_database_cleanup_spec.rb`,
  `mobile_ticket_navigation_spec.rb`, `mobile_assistant_layout_spec.rb`,
  `mobile_shell_regressions_spec.rb` and `phone_page_head_spec.rb`),
  `javascript` (Node unit tests), `lala` (Python tests of `bin/lala`, `spec/python/`),
  `rubocop`, `brakeman` and `dependencies`.
  The Rails/browser job needs no `RAILS_MASTER_KEY` (Rails generates a local test secret); npm lifecycle scripts are disabled
  with `npm ci --ignore-scripts`, and fonts are copied explicitly. Browser fixtures
  are nontransactional so Puma can read them; failure artifacts include
  `tmp/screenshots/`, `tmp/capybara/` and explicit mobile captures.
  A red RuboCop run means a new offense against the frozen baseline. A red guards
  job needs inspection of the failing step, including browser/infrastructure failures.
  ⚠️ **The curated list is maintained manually.** Anyone deleting a spec must also delete its line
  there: rspec cannot LOAD the file and reports “0 examples, 1 error occurred outside of
  examples”, which looks like an infrastructure failure but is not. A local run of the list does not catch
  this if paths are first filtered to existing files. Guard:
  `spec/architecture/ci_guard_list_spec.rb` (also checks that no `.js` is passed to rspec;
  the `javascript` job runs those with Node).
  ⚠️ **A security spec carries `:ci_guard`** on its `describe`
  (`RSpec.describe Foo, :ci_guard, type: :request do`, tag before keyword arguments).
  The same guard requires every tagged file to be listed, individually or through
  a parent directory. A removed line therefore fails instead of silently disappearing. Until
  27 September 2026, the regression specs from #895 and #896 ran nowhere. New specs for permissions,
  tenant boundaries or fixed vulnerabilities: add the tag **and** the path.
  The full suite and full `erblint` still run locally (known drift, separate cleanup).
* **Docker** (`Dockerfile`, `compose.yml`, `compose.build.yml`, `.env.docker.example`): for
  self-hosters only, our servers deploy with Capistrano and never run the image. Each published
  release builds `ghcr.io/lalabase/lalabase:<version>` for amd64 and arm64
  (`.github/workflows/docker-release.yml`), checks it with `script/docker_check` and only then
  pushes it. `compose.yml` pulls the release in its `image:` line, which `script/release
  prepare` writes and `publish` holds against the version (guard: `changelog_guard_spec.rb`);
  never edit that line by hand. `.github/workflows/docker.yml` builds from the checkout
  (`compose.build.yml`) and boots the stack, only for PRs touching the image, `config/` or `app/assets/`.
  Every production setting that
  names a host goes through `Lalabase::InstanceSettings`; without `LALABASE_HOST` it returns our
  servers' values unchanged (pinned by `spec/config/instance_settings_spec.rb`).
  ⚠️ **The compiled CSS carries the asset host.** The image precompiles with `ASSET_HOST=` set
  and empty; without it every instance would load its fonts from lalabase.com.
* **Leaks** (`.github/workflows/leaks.yml`): a workflow of its own on **every** PR and on
  every push to main. One job, `leaks`, over everything the PR makes public, not
  only its end state: every commit (merges by their diff against main, so a conflict resolution
  counts), every commit message, who wrote and committed it, every name a commit adds
  (binaries, links, renames), the PR's branch name, title and body (GitHub writes them into the
  commit on main), and the files as they end up. **gitleaks** with `.gitleaks.toml` (default rules without any upstream
  exception by path, `--redact`, `--text` so a `-diff` attribute hides nothing), and **leak
  guard** (`script/leak_guard`, `Lalabase::LeakGuard`): forbidden file types, runtime data,
  symbolic links, and keyed digests (`config/leak_guard.digests`, HMAC with the secret
  `LEAK_GUARD_KEY`) of what only the maintainers may know. The plain list and the generator live
  in the private repository; never write one of those words here, not even in a comment.
  Locally: `LEAK_GUARD_KEY` in `.env`, then `script/leak_guard` and
  `script/leak_guard history origin/main..HEAD`.
  ⚠️ **Commits to this repository carry the maintainer's GitHub noreply address** (repository
  `user.email`). A private address as author is public with every commit, and the guard turns
  it red: set it in every new clone and on every machine or agent environment that commits.
  ⚠️ **The net comes from the base, not from the PR** (`script/leak_guard net`): a PR that
  weakens it, say by allowing a real key "to make the CI green", is still checked by the old
  one, and the job summary names the change. The label `leak-net-change` makes a run use the
  PR's own net; set it only after reading that part of the diff (a new dummy key in the
  allowlist needs it). The `.gitleaks.toml` check in `gitleaks_config_problems` is a tripwire,
  not a proof; do not extend it, the base net is the protection.
  ⚠️ **Green only means checked.** Ways it once said green after checking nothing: a wrong key
  (the digests carry a key check), a base commit missing from the clone (the `Range` step stops
  first), a NUL byte or a marker line that cut the log short, a range without commits. A new
  way of skipping is a red test first.
  Not covered, on purpose (accidental leaks are the threat model): a secret in a UTF-16 file
  (gitleaks does not read it; the guard reads its words), what is pushed without a PR (the
  pre-push hook on switch day), tags and notes.
* **CodeQL** (`.github/workflows/codeql.yml`): Ruby, JavaScript and the workflows, on every
  PR, every push to main and weekly. Findings go to the code scanning view, not into a red
  check. **Dependabot** (`.github/dependabot.yml`): weekly grouped PRs for bundler, npm and
  the actions. Every workflow pins its actions by commit hash with the version as a comment
  and sets `permissions:` at the top (read-only unless a job needs more); a new workflow
  does the same. All four raise the OpenSSF Scorecard (SAST, Dependency-Update-Tool,
  Pinned-Dependencies, Token-Permissions).
* **Two security jobs, deliberately separate.** A job has exactly one status, and
  `dependencies` is currently red (see below). Combined, Brakeman's red would be
  indistinguishable from that red, and Brakeman's entire value is “red = NEW finding”:
  * `brakeman`, against the frozen `config/brakeman.ignore` baseline (36 entries as of
    27 November 2026; the `constantize` entry in the file proxy was fixed with #915 instead of
    being frozen again; the title-search entry disappeared with the ticket-search redesign;
    the two entries of the notification group lock went with its interpolated SQL).
    Red = NEW finding. **Every entry has been reviewed** and its `note` field states
    why it is safe; the file may only shrink, and a new entry
    needs the same justification. Exception since 20 October 2026: the demo reset's TRUNCATE
    (`lib/lalabase/demo/reset.rb`), with no input; Brakeman cannot see quoting through
    `map` and `join`. During the 26 September 2026 review, one was a real
    SQL injection (ticket search, #889); five others were hardened instead of frozen.
    ⚠️ A frozen entry is publicly visible: “unreviewed” entries form a list of
    attack targets.
    An earlier high-confidence entry, `_filter_pills.html.erb:97` (XSS), was **fixed
    instead of frozen again** on 31 August 2026: a line shift changed its fingerprint, and because the
    file may only shrink, the five handmade `"#{request.path}?#{...}"` expressions are now one
    builder using a named route (`TimeSessionsHelper#time_list_filter_url`). Likewise on
    8 September 2026, `ad_hoc_filter_service.rb:248` (SQLi in the date filter): the line moved,
    the fingerprint changed, and the condition is now Arel instead of an SQL string
  * `dependencies` (`bundler-audit`), **without** an ignore list. A vulnerable gem is not drift,
    but a version number; the answer is an update, not a note. Since the fifth
    step of the dependency series (#640, #641, #649, #657, Rails 8.0.5.1 on main), the
    job is green: red = NEW alert, and the answer is again a version number
* **Code quality**:
  * Lint Ruby: `rubocop`
  * Lint ERB: `erblint --lint-all`
  * Security scanner: `bundle exec brakeman` — **not** `bin/brakeman`: the shim forces `--ensure-latest` and exits with code 5 as soon as a newer upstream version exists, without scanning at all
  * Check dependencies: `gem install bundler-audit && bundle-audit check --update` (deliberately not in the Gemfile: the tool checks `Gemfile.lock` and must not be pinned by it)
* **Assets**:
  * `tailwindcss-rails` builds Tailwind CSS (dev: `bin/rails tailwindcss:watch` via Procfile.dev, one-off: `bin/rails tailwindcss:build`); Sprockets bundles the other stylesheets through the `*= require` directives in `application.css`
  * Copy Bootstrap Icons fonts to `public/fonts` (once after `npm install`): `npm run copy:fonts`
* **Database**:
  * Migrations: `bin/rails db:migrate`
  * Load schema: `bin/rails db:schema:load`
  * Seeds: `bin/rails db:seed` (also runs automatically when `db:prepare` creates a new database).
    Always loads persona reference data, plus a small demo in development
    (`db/seeds/demo.rb`). Seeds **never** delete anything and contain no real addresses,
    only `@example.com` (guard: `spec/architecture/seeds_guard_spec.rb`)
  * First instance admin for a fresh installation: `bin/rails lalabase:setup`
    (`LALABASE_ADMIN_EMAIL`/`LALABASE_ADMIN_PASSWORD` or terminal prompt; refuses
    once a Beuser exists). The first user then registers at `/users/sign_up`

---

## Multi-Tenancy & Security

### acts_as_tenant Essentials
**Critical checks:**
* `acts_as_tenant` set?
* Default scope correct?
* Seeds/factories tenant-aware?
* Queries correctly filtered by tenant?
* **An optional `belongs_to` to a tenant-aware model must precede `acts_as_tenant`** (or
  have its own validation). acts_as_tenant 1.0.1 checks foreign IDs only for associations declared
  before the call. Rails itself protects required associations because reads go through
  the tenant scope. `SmartFolder.project` was declared afterwards and accepted a foreign
  organisation's project until 16 September 2026 (guard: `smart_folders_tenant_boundary_spec.rb`).
* A raw `*_id` from params is resolved through a tenant- or policy-scoped query,
  never assigned directly. A project change checks permissions in the **target** project
  (reference: `TimeSessionsController#move_to_requested_project`).

### Private comments: one rule, no bare `ticket.posts`

**Binding** (guard spec: `spec/architecture/post_visibility_guard_spec.rb`; runs through the
`spec/architecture/` directory entry in the CI guard list):

A private comment may be read by its recipient, its author and account admins. **Only**
`Post.readable_by(user, organisation)` decides this (or `#readable_by?`, which `PostPolicy` queries).

| Who reads the result? | Then use |
|---|---|
| one person (timeline, search, email to them, API, MCP) | `ticket.posts.readable_by(user, organisation)` |
| all ticket readers (activity excerpt, summary, AI answer) | `ticket.posts.public_posts` |

* In controllers, services, queries, mailers, components, views, presenters,
  jobs and helpers, the guard rejects every `.posts` without one of these continuations (`find`,
  `build`, `create!` are also allowed), plus `association(:posts)` and a `JOIN posts` without `posts.id IN (`.
  The exception list may only shrink, and every entry states its reason.
* ⚠️ **Do not preload `posts` for display.** A preloaded association contains all
  posts. This is exactly how the timeline exposed every private comment until 27 September 2026.
* Until the audit on 26 September 2026, the rule existed only in `PostPolicy`. Five readers had
  forgotten it; two more were found while fixing them.

### A conversation is read through `Conversation.visible_to`

**Binding** (guard spec: `spec/architecture/conversation_visibility_guard_spec.rb`; runs through the
directory entry `spec/architecture/` in the CI guard list):

A conversation (messages between members of one organisation, for instance an agency and its
client) is read by somebody who has a participant row **and** is an active member of the
conversation's organisation. That is decided **only** by the scope `Conversation.visible_to(user)`.
(Its third term is the account itself: an erased account reads nothing, whatever rows it left.)
A conversation holds correspondence with a client, and the section above tells how a rule that
had to be remembered at every read was forgotten at seven. So this rule has one place, and its
guard stood before the first reader did.

| Who asks? | Then |
|---|---|
| a list or a lookup for one person | `policy_scope(Conversation)`, which is `Conversation.visible_to(user)`, then `.find` |
| a question about one conversation | `ConversationPolicy`: every question first asks `conversation.visible_to?(user)`, which asks the scope |
| who is told about a post | `conversation.visible_participants`, the same rule from the other end, as users |
| something that starts from posts | `ConversationPost.visible_to(user)`, which merges the scope |

* **No project term and no admin term.** The project on a conversation is a label: a member with
  every right on it who does not take part reads nothing. An account admin who does not take
  part reads nothing either, not a title and not a number. The line other policies open with
  ("an admin of the account sees everything") must not be copied into the rule or the policy.
* **A participation ends by deleting its row**, never by a flag: a forgotten "and not ended"
  would be a leak, a missing row cannot be. A member who is deactivated or removed keeps the row
  and reads nothing until the membership is active again.
* A row stands in one organisation, and so does what it names: the project of a conversation,
  the invitation of a post and the conversation of a participant or a post are held to the row's
  organisation by the model, also where no tenant is set (the tenant stamps a new row as its own,
  whatever the row names).
* **The guard refuses five things:**
  1. Everywhere under `app/` outside `app/models` and `app/policies` (controllers, channels,
     services, queries, mailers, components, views, presenters, jobs, helpers, and a directory
     that is added later):
     a use of `Conversation`, `ConversationPost` or `ConversationParticipant` on the class that is
     not on its list of what may stand (`visible_to`, `new`, `create`, a constant behind `::`, the
     class as an argument as in `policy_scope(Conversation)`), and SQL text that names one of
     the three tables behind `JOIN` or `FROM`.
  2. In the same places: `association(...)` of the posts or the participants, and a preload or a
     join of them. A preloaded association holds every row, whatever the rule says.
  3. The words `project` and `account_admin` in the rule (`visible_to`, `visible_to?`,
     `visible_participants`, `ConversationPost.visible_to`) and anywhere in
     `app/policies/conversation_policy.rb`, comments left out.
  4. A Turbo broadcast in any file under `app/` that names one of the three models: a stream
     carries content to whoever listens. The one owner of a live signal comes with a later change.
     ⚠️ It goes by the name of the method, so the application's own
     `Notifications::BroadcastService#broadcast_update` counts in such a file as well.
  5. One of the three models under `app/services/{assistant,embeddings,chats,lalabase/tools}`,
     `app/controllers/admin` and `app/views/admin`: a conversation is not searched, not read by
     the assistant and not shown in the admin area.
* The guard knows the models by their constants, not by the word: the module `Conversations`
  (the switch) and `ConversationPolicy` are not models.
* The allow list `OWNERS` (a file and its reason) only shrinks; an entry without a finding or
  for a missing file is red. It has one entry, `app/services/user_data_exports/registry.rb`: the
  personal data export lists a person's own rows by `user_id`, dates only, and on purpose not
  through the rule, so what somebody wrote stays theirs to ask for after they left a
  conversation or were deactivated. (Like the whole export it covers only organisations the
  person still has a membership row in.)
* ⚠️ **A tripwire against accidental readers, not a proof.** Not seen: a read built at run time
  (a class in a variable, `constantize`, `send`); a read through an association on a record
  (`conversation.conversation_posts`), which is fine when the record came through the rule and
  wrong when it did not; a reader that only shows the fields of a notification about a
  conversation; SQL built from parts; `app/models`, `app/policies` and `lib/`. A comment that
  quotes a forbidden form trips nothing, a string does not count as a call.
* ⚠️ **A conversation is deleted through the model** (`dependent: :destroy`). The cascade of the
  database removes the rows of the posts and leaves their rich text behind. That holds for the
  organisation above it as well: its conversations hang on it by the database cascade alone.
  No path deletes an organisation today; the first one that does destroys its conversations
  through the model first.
* **The switch** is `Conversations.enabled?` (`app/services/conversations.rb`): the environment
  variable `LALABASE_CONVERSATIONS`, read at every call, on for the value `1` only, for the whole
  instance. Nothing asks it yet. The models, the policy and the export never ask it: who reads
  is a rule of the data and does not hang on the environment.
* **Nothing reads or writes the three tables yet**: no route, no controller, no notification, no
  mail. The first writer and the first reader each start as a line in the table above.

### A meeting write locks through `Meeting#lock_in_project!`

**Binding** (guard spec: `spec/architecture/meeting_lock_guard_spec.rb`; runs through the
directory entry `spec/architecture/` in the CI guard list):

A meeting can move into another project (`Actors::MoveMeeting`, under the meeting's row lock).
A write that was authorized against a project takes the same lock through
`meeting.lock_in_project!(authorized_project_id)` and treats `false` as "the meeting is gone
from this project": refuse, or answer as if it were not found.

* The guard refuses a bare lock on a meeting (`@meeting.lock!`, `Meeting.lock`,
  `project.meetings.lock`) anywhere outside `app/models/meeting.rb`. Its allow list names two
  actors that lock and then authorize again, under the lock, in the project the meeting is in
  now (`AcceptTicketSuggestion`, `StartTicketSuggestionRun`). It only shrinks, and every entry
  gives its reason.
* In a controller the lock is `with_meeting_in_project { ... }` (`MeetingInProject`): the
  block runs under the lock, a moved meeting answers 404. The guard asks **every write
  action** (each route but GET) of `MeetingsController`, `MeetingTicketLinksController`,
  `MeetingParticipantLinksController` and `MeetingTermCorrectionsController` (K4b) for that call
  or for an actor that locks itself (`LOCKING_ACTORS`). A check per file had
  passed `create_summary`, unlocked next to a delete that locked, until a fourth review round.
  The exception list (`NO_MEETING_YET`, a write before any meeting exists) only shrinks.
* `WRITERS` pins the services that lock: the move, the edit, the analysis publication, the
  booking, the participant link, the term correction (K4b), and the controller helper. Four review rounds of the move found each of these
  writes landing in the old project after a move.
* ⚠️ **Not seen: a write in a service or controller the guard does not name.** Writing a
  meeting's data (its project, links, analyses, bookings) elsewhere means calling the helper
  and adding the file to `WRITERS` or `CONTROLLERS`.
* Lock order: the meeting before a booking, an analysis or a glossary term, never the other way
  round.

### The host never grants access

**Binding** (guard spec: `spec/requests/organisation_hosts_spec.rb`, `:ci_guard`, own entry in
the CI guard list):

An organisation can be shown on a subdomain of its own (`kunde.lalabase.com`), switched on by
`LALABASE_TENANT_DOMAIN` (the instance's own host; organisations sit one label below it).
Which host a request came in on decides only **where** a page is shown, never **whether** the
person may see it. Rights stay the membership and policy checks of every request.

* Never resolve the tenant, a record or a right from `request.host`. The address is typed by
  the visitor (and Rails reads it from `X-Forwarded-Host` when that header is present).
* One owner for "which host shows which organisation": `Organisations::Hosts` (`.call(host:)`,
  `.host_for(organisation)`). The names live in `organisation_subdomains`: a row without
  `held_until` is the current name, a row with it an old name held for the organisation.
  The legacy columns `organisations.subdomain` and `organisations.domain` name no host.
* A full page of organisation X moves to X's host only after `load_tenant_from_session` found
  an active membership in X (`OrganisationHost`). Someone who is not a member gets what they
  got before, on whatever host they asked, and learns no subdomain from a redirect.
* `Lalabase::OrganisationHostGate` answers in front of the controllers: an unknown subdomain
  is 404, an old one redirects GET and HEAD to the current host, and API, MCP, admin,
  webhooks and `/up` exist on the main host only.
* Only the instance admin sets a subdomain (`Actors::AssignOrganisationSubdomain`).
* **A person signs in on the main host only.** Each host keeps a session of its own
  (host-only cookie, `__Host-` under TLS, one name per environment: `Lalabase::SessionCookie`).
  The session reaches an organisation host through the login hand-off
  (`Sessions::HostHandoff`, guard `spec/requests/session_handoff_spec.rb`, `:ci_guard`): a
  single-use token, valid 60 seconds, bound to the host and to the state cookie of the
  browser that began it, so a claim address opened in another browser signs nobody in.
  Devise's failure app starts it on an organisation host (`Lalabase::HandoffFailureApp`);
  `/users` there goes to the main host, signing out stays.
* **Signing out ends every host's session**: `users.session_version` goes into a session at
  sign-in, every request compares it (`config/initializers/session_version.rb`), and
  `Users::SessionsController#destroy` raises it. A new way to sign out has to raise it too.
* ⚠️ A `host:` key in a route helper is the URL's host, not a query parameter: the target
  host of the hand-off travels as `target`.

---

## ViewComponent & Design System

### Component Development Patterns
* **Naming**: `Neo[Name]Component` for components, buttons in the `Neo::Buttons::` namespace (e.g. `Neo::Buttons::ButtonComponent`)
* **Stimulus controller**: `neo_[name]_controller.js` (e.g. `neo_button_controller.js`)
* **Hybrid approach**: structure/styling in ViewComponent, interactivity in Stimulus

### Neo Brutalist Design Language
* **Style**: Border-2 black, a hard offset shadow only where you press (see "Shadows" below), bold typography
* **Available components**: Button, Card, Tag, Flash, Modal, Forms
* **Style guide**: development at `/style-guide`, documentation in `docs/design/grundlegendes.md`

### Icons: one set, Bootstrap Icons

**Binding** (guard spec: `spec/architecture/one_icon_set_guard_spec.rb`; runs through the
directory entry `spec/architecture/` in the CI guard list, no allowlist):

| What | How |
|---|---|
| an icon | `<i class="bi bi-..." aria-hidden="true"></i>` |
| a drawing of our own (the plus of the main action, the deadline flag, the view switch, a chevron) | an inline SVG of straight strokes and basic shapes |

* No template, component, helper, script or stylesheet carries an icon pasted from another
  set. Until 2026-09-30 six files carried nine of them (Heroicons, Lucide, the spinner from
  the Tailwind documentation). Each is somebody's work under its own license, and a pasted
  path is not a file the license guard can see.
* The guard is a tripwire, not a proof. It takes a path with arcs or Béziers for a pasted
  icon, because what we draw ourselves has none, and it knows the classes of other icon
  fonts. ⚠️ It does NOT see a pasted icon of straight strokes only (a cross, a check mark, a
  menu), a path held in a constant, an SVG file or a sprite. Those are for the person who
  reads the diff.
* A drawing of our own that really needs a curve (a chart, a gauge) computes its path from
  numbers in code. A curve written out as a literal is what a pasted icon looks like.
* A state with two signs (pinned or not) puts both icons in the markup and lets the
  attribute pick one in CSS (`column_picker.css`, `aria-pressed`). The script flips the
  attribute and repaints nothing.
* The spinner of a button is a ring drawn with a border, in the button's own colour
  (`Neo::Buttons::Base#render_spinner`).
* ⚠️ **An icon that is told to turn names its own box**: `bi bi-arrow-repeat inline-block
  animate-spin`. An `<i>` is an inline box, and a transform does not apply to one. It turns
  only while its parent happens to be a flex or grid container. Two waiting signs stood
  still that way until 2026-09-30 (ticket header, admin mail log); four others turned by
  the luck of their parent. The guard reads class lists in templates and scripts; a list
  put together in Ruby (`NeoInfoTagComponent`) is held by its component spec.
* The cross of a removable tag says what it removes (`components.neo_tag.remove`,
  "Remove %{name}"): a row of chips is a row of buttons.

### Shadows: a hard shadow means "press me"

**Binding** (guard spec: `spec/architecture/shadow_levels_guard_spec.rb`; runs through the
directory entry `spec/architecture/` in the CI guard list):

A hard offset shadow (blur 0) says one thing: you can press this. The rest of a page is flat and
stands apart by tone and edge (rule 5 in `doc/belegungstabelle_oberflaeche.md`, slices in
`doc/schatten_stufen_plan.md`).

| Token | Value | Only for |
|---|---|---|
| `shadow-press` | `2px 2px 0 0 rgb(var(--ink))` | the main action at rest (`Neo::Buttons::Base` PRIMARY) |
| `shadow-press-hover` | `3px 3px 0 0 rgb(var(--ink))` | the main action hovered; pressed, it sinks and loses it |
| `shadow-lift` | `4px 4px 0 0 rgb(var(--ink))` | a card that is wholly a link or a button, while hovered |

* Hard shadows stand in three places only: the main action (also in CSS, as `.mobile-primary`;
  the members page's `.members-invite` became the square "+" on 2026-11-11), a clickable card
  while hovered (flat at rest), and the logo tile
  (`shared/_brand_mark`, its own value, as on the website). Every other button is flat.
* **Written values**: every arbitrary value `shadow-[...]` whose shadow is hard (an offset, no
  blur; any prefix) in `app/views`, `app/components`, `app/javascript`, `app/helpers`,
  `app/services`, comments included. It is read with the classifier of the stylesheets:
  `shadow-[0_-4px_0_0_#14110c]` counts, a ring or `inset` does not. A legacy list holds a count
  per file (68 values in 39 files on 2026-11-20) and only shrinks: a count too high or too low is
  red, so is a file with hits and no entry, or an entry without hits. Not read: `app/views/admin/`
  (its own style guide, decided 2026-06-01) and `app/views/style_guide/` (it shows samples).
* **Inline values**: a hard `box-shadow` literal in the same files (a `style` attribute, a CSS
  string in Ruby, a `boxShadow` string in a script) stands in a second list that only shrinks,
  `INLINE_LEGACY` (4 in 4 files on 2026-11-08: `NeoToggleComponent`, three Stimulus controllers).
  They keep their shadow in the dark theme until a later slice: no attribute rule reaches them.
* **Tokens in their place**: `shadow-press` and `shadow-press-hover` only in
  `app/components/neo/buttons/base.rb`, `shadow-lift` only in the files of `LIFT_USERS` (today
  `NeoCardComponent`), each with its reason. Read in admin and the style guide too: a token's name
  promises its role everywhere. Each token in `config/tailwind.config.js` is drawn from `--ink`.
* **Stylesheets**: a `box-shadow` under `app/assets/stylesheets/` with a hard layer (not `inset`,
  an offset other than 0, blur 0 or none) belongs to a selector of `CSS_HARD`, with its reason
  (10 selectors in 5 files on 2026-11-08). A written hard value in `@apply` counts as a
  declaration of that selector (entry and dark rule); a token in `@apply` is red. A ring
  (`0 0 0 2px ...`) and `inset` do not count. Not read: `landing_tokens.css`, `lp_base.css`,
  `auth.css` (mirrors of the website, held by `auth_styles_guard_spec.rb`), `bootstrap-icons/`.
* ⚠️ **No hard shadow from a class or a stylesheet reaches the dark theme**; the inline list is
  the known rest. Each token has `.dark [class*="shadow-<token>"]` with
  `box-shadow: none !important` in `application.tailwind.css`. Only this form counts
  (`.dark .shadow-lift` never matches `hover:shadow-lift`), and `!important` because at equal
  specificity the hover utility comes later in the build and wins. Each `CSS_HARD` selector has a
  `.dark <selector>` rule in its own file (`!important` where the original has it). The line
  `.dark [class*="shadow-["] { box-shadow: none !important; }` stays: it removes every written
  value, but it does not match a named class.
* ⚠️ The guard does NOT see a shadow built at run time (a class or a style put together from
  parts, a value from a variable or a template expression), soft shadows (`shadow-sm`, another
  plan), or the role of an element: a panel that gets `shadow-lift` is for the reader of the diff.
* Menus, modals and drawers get a soft shadow in a later slice. `shadow-layer` and `shadow-modal`
  do not exist yet: `--ink` is light in the dark theme, and a soft shadow from it would glow.

### CSS Convention: NO `<style>` Blocks in Views
**Binding** (otherwise guard spec `spec/views/no_style_blocks_guard_spec.rb` fails):
* CSS belongs in `app/assets/stylesheets/*`, never in a `<style>` block inside a view:
  * `layout.css` → global column/layout system, list/card interactions
  * `views.css` → page-specific rules (scoped to page anchors, grouped by topic)
  * `components/rich_text_embeds.css` → rich-text display (zoom link, lightbox, placeholders); Lexxy's own stylesheet styles editor and content (`lexxy-content`)
  * `components/*.css` → encapsulated components (reference: `components/custom_select.css`)
  * `style_guide.css` → loaded only in the style-guide layout
* **Only exception**: mailer layouts (`layouts/mailer.html.erb`, `layouts/notification_mailer.html.erb`) — email clients do not load external stylesheets (allowlist in the guard spec).
* **`@apply` works ONLY in `application.tailwind.css`** (build time). In runtime CSS or `<style>` blocks, `@apply` has no effect and is therefore dead code.
* When centralizing generic class names (e.g. SortableJS `.sortable-ghost`), scope them to a page anchor to prevent collisions between page variants.

### Frontend: the application loads nothing from a foreign host

**Binding** (guard spec: `spec/architecture/no_runtime_cdn_guard_spec.rb`; runs through the
directory entry `spec/architecture/` in the CI guard list):

The scripts, stylesheets and fonts of the application, and the markup of its own templates,
are served by the instance. A new frontend dependency is vendored (`vendor/javascript`,
`vendor/assets`, with a notice in `THIRD_PARTY_NOTICES.txt`) or comes from a gem.

The guard asks three questions:

| Question | Where |
|---|---|
| Does a tag, a stylesheet, an import or a request in a script name a foreign address as a literal? | our own files and the vendored ones |
| Does a file carry the address of a public CDN at all? | the same files |
| Both again | the scripts and stylesheets that gems put into the page (Turbo, Stimulus, Action Text, Lexxy), found through the importmap and the stylesheet bundle |

* ⚠️ **A vendored file is not a local file.** Until 2026-09-30 the Markdown editor of the old
  note form sat in `vendor/assets` and fetched a spelling dictionary from jsDelivr and an icon
  font from BootstrapCDN on every full load of that page: both addresses were strings inside
  its minified file, both features on by default. Read a new library for addresses before it
  goes in. The guard reads it again, and reads the gems' files after every update.
* ⚠️ **The content security policy stops none of this.** It runs in report-only mode
  (`config/initializers/content_security_policy.rb`): it logs a violation and lets the request
  through. Do not count on it until that line says `false`.
* **Synced documentation pages load nothing from elsewhere either**, since 2026-11-01.
  The sync copies the images a page shows out of the clone (`Documentation::AssetCollector`) and the file proxy serves them behind the right of
  the documentation; an image that is not served shows as its alt text, one with a foreign
  address becomes a link. Until then every reader of such a page contacted
  raw.githubusercontent.com. Held by `documentation_sync_job_spec` ("names no repository
  host and no address outside the instance").
* ⚠️ Other content is not covered by this guard, and `img-src` still allows any https.
* Not seen either: an address built at run time (a host in a constant, an interpolated string).
* One named exception, `SAMPLES`: the code samples of the style guide are printed as text, and
  one of them shows the forbidden thing on purpose. A comment that quotes a foreign tag or
  address trips the guard like the real thing: describe it in words.
* The list of public CDNs is incomplete by nature. It is there for the case the first question
  cannot see.

### View Convention: NO rails-ujs Options
**Binding** (guard spec: `spec/views/no_rails_ujs_options_guard_spec.rb`, in the CI guard list):

`rails-ujs` is **not loaded** in this app (`config/importmap.rb`: “Not used with Turbo”).
Two common Rails idioms are therefore **silent dead code** — they raise no error;
they simply do nothing:

| ❌ rails-ujs (no effect) | ✅ Turbo | Symptom without the fix |
|---|---|---|
| `link_to path, method: :delete` | `link_to path, data: { turbo_method: :delete }` | Link sends a **GET** → RoutingError for POST/PATCH-only routes, or silent navigation if the route also handles GET |
| `data: { confirm: "..." }` | `data: { turbo_confirm: "..." }` | The confirmation dialog **never appears**; destructive actions execute on the first click |

* For `Neo::Buttons::*` components, use the top-level `confirm:` kwarg instead — the
  component maps it correctly to `turbo_confirm` itself.
* `button_to` may use `method:`: there, it is the documented Rails API and renders an
  actual form. `method:` is a pitfall only with `link_to`.
* The guard has **no allowlist** — it starts at zero. A new exception requires adding an entry
  **and** explaining why UJS semantics are needed in an app without UJS.

### View convention: no form inside a form

**Binding** (guard spec: `spec/architecture/nested_form_guard_spec.rb`; runs through the
directory entry `spec/architecture/` in the CI guard list, no allowlist):

A `button_to`, or a Neo button with `form: { ... }`, is a form of its own. Inside a `form_with`
block it is a form within a form, and what the browser makes of it depends on how the markup
arrives. From a Turbo Stream the inner form survives, Chrome stops its submit event at the
outer form, and Turbo never sees it: no `data-turbo-confirm` question, the browser posts the
form itself. Until 2026-11-13 the delete buttons of the meeting and the note edit forms stood
like that, and one click deleted the record.

| ❌ inside `form_with` | ✅ |
|---|---|
| `Neo::Buttons::ButtonComponent.new(confirm: ..., form: { action: path, method: :delete })` | `Neo::Buttons::ButtonComponent.new(confirm: ..., url: path, data: { turbo_method: :delete })` |
| `button_to path, method: :delete` | the same link, or the button behind the end of the form |

* ⚠️ The guard reads one template at a time. It does NOT see a partial or a component
  rendered inside a form that brings a form of its own. Browser guards:
  `spec/system/note_edit_delete_spec.rb` and "deletes from the lane" in
  `spec/system/meetings_overview_spec.rb` (a "no" must keep the record).

### View Convention: Page Width Only Through the Class
**Binding** (guard spec: `spec/architecture/page_width_guard_spec.rb`; automatically runs through the
`spec/architecture/` directory entry in the CI guard list):

One question determines a page's width: **are users comparing columns vertically, or
reading rows horizontally?** (“Widths” section in `doc/belegungstabelle_oberflaeche.md`)

| Class | When | In code |
|---|---|---|
| Full | Table, Kanban, matrix: comparing columns | no cap |
| Split | List and lane side by side | no cap; an open lane removes every cap |
| Capped | One subject with one value per row | `.width-capped` (620 px), with a symbol or time column `.width-capped--wide` (820 px) |

* Prose in every class: `.width-text` (70ch).
* Values are defined **once** in `layout.css` (`--width-capped`, `--width-capped-wide`,
  `--width-text`). A view names the class, never its own `max-w-*`; new CSS reads the
  variable and does not give the same number a second name.
* The cap sits on the content block, never the shell, and is **never centered**: capped means
  “ends earlier”, not “starts elsewhere”. The page header (title, tabs, title action) remains
  full width.
* Legacy cases are in a guard list that **may only shrink**: a migrated
  page lowers its entry; an entry that is too high also fails.

### View convention: on a phone the page head never repeats the fixed head

**Binding** (guard spec: `spec/system/phone_page_head_spec.rb`, in the mobile step of the
`guards` job; the rule itself: `spec/helpers/mobile_navigation_helper_spec.rb` and
`spec/components/neo_title_box_component_spec.rb`):

Below 1024 px the phone shell's fixed head (`layouts/_mobile_header`) names the page: outside a
project the page's title and the organisation, inside a project the project (it opens the
switcher) and the area tabs. The page head (`NeoTitleBoxComponent`) hides every line the fixed
head already shows and keeps its tools; with nothing left it takes no room.

* **The words are the page's.** The first page head of a request leaves its title and second
  line for the fixed head (`MobileNavigationHelper#mobile_head_echo`, read by
  `#mobile_page_title` and `#mobile_page_line`); `PAGE_TITLE_KEYS` only names a page without a
  page head. A management page therefore says its section up there, as on the desk; the open
  tab or the crumb line names the page.
* **A page head is `NeoTitleBoxComponent`**: directly, through `organisations/shared/_subnav`
  (and `_settings_subnav`, `_times_subnav`) or through `NeoProjectLayoutHeaderComponent`. A page
  below a section outside a project (a management form, the inbox's settings, the form of a
  saved view) keeps the section's head and names itself in the crumb line
  (`organisations/shared/_section_crumb`). A page with a hand-written `<h1>` as its head is not
  covered and shows its title twice on a phone.
* One condition for the shell: `mobile_shell?` puts the body class `mobile-app`, the fixed head
  and the bottom bar on a page together. The CSS rule (`components/mobile_app.css`) hangs on
  `.mobile-app`, so it never hides a line where no fixed head stands.
* ⚠️ Not a page head: the title of a record in a lane or on its own page on a phone (a ticket,
  a note). It names the record, not the page, and stays.
* Until 2026-11-24 the page head stood under the fixed head on nearly every page, often in other
  words (German labels: "Start" over "Übersicht" — "Home" over "Overview";
  "Verwaltung" over "Allgemein" — "Management" over "General"), and five pages had each
  dropped it in a way of their own.

### View Convention: Pages Before Sign-in Share ONE Skeleton

**Binding** (guard spec: `spec/requests/auth_pages_skeleton_spec.rb`; has its own
entry in the CI guard list, where `spec/requests/` is not a directory entry):

Visitors see seven pages before signing in: sign-in, registration,
registration disabled, forgot password, new password, resend confirmation, unlock.
They share one skeleton, and **the skeleton belongs to the `application_auth` layout**, not the view.
A view supplies four things:

| Slot | Content |
|---|---|
| `yield` | Form column: eyebrow text, heading, form |
| `content_for :auth_cross` | The top-right link |
| `content_for :auth_panel` | The dark panel's content |
| `content_for :auth_panel_decorative` | Set when the panel is a diagram (then hidden from screen readers and on phones) |

* The guard has **no exception list**: no view under `app/views/devise/` contains
  `lp-auth-form-col`, `lp-auth-legal` or an `<aside>`. Until 20 September 2026, the skeleton
  had been copied manually three times, and the four missing pages would have made seven copies.
* **`application_sessionless` is NOT the same layout.** It retains admin sign-in
  (own style guide) and an instance's legal pages, and does not load `auth.css`.
* Password fields are **always** rendered by `devise/shared/_password_field` (eye toggle,
  optional strength indicator). Labels live under
  `views.devise.shared.password_field`, not separately per page.
* A new page needs a controller entry in `devise_for` **and** `layout
  'application_auth'`. Without the `devise_for` entry, Devise's own controller runs with the
  default layout and renders the application shell for someone without a session. This is exactly
  how `/users/unlock/new` had appeared since `:lockable` was enabled.

⚠️ **A time limit in the panel comes from configuration, never from text.** “The link is valid for
6 hours” reads `Devise.reset_password_within`; “after 5 failed attempts” reads
`Devise.maximum_attempts`. A typed value survives a changed setting and misleads the
reader; the guard changes the setting and fetches the page again. A sentence that applies only to
certain settings (self-unlocking only with `unlock_strategy` `:time`/`:both`)
belongs behind the matching condition.

⚠️ **No dead ends.** Every page available before sign-in is reachable by clicking from the sign-in page.
Until 20 September 2026, only `devise/shared/_links` linked to confirmation and unlocking,
and **nothing** rendered this partial: both pages were reachable only through the address bar,
while help promised a link “on the sign-in page”. The guard follows
the link and checks the target page.

⚠️ **`aria-hidden` only on a diagram.** The sign-in panel shows fictional
inbox rows and stays hidden. A panel containing the only copy of a fact must be
readable. **The same attribute controls phone display** (since 22 November 2026): there, `auth.css`
hides a decorative panel entirely (`.lp-auth-panel[aria-hidden="true"]`); anyone signing in or
registering sees only the form. A readable panel remains below the form.
If a diagram becomes factual content, remove `auth_panel_decorative`, or nobody on a phone
will read it. On phones, `auth.css` also hides the final step of a step list
(`.lp-auth-step:last-child`) — no fact may appear exclusively there, and a heading
must not count the steps.

### Implementation Example
```erb
<%= render Neo::Buttons::ButtonComponent.new(
  variant: :primary,
  size: :medium,
  icon: "plus-lg",
  interactive: true,
  form: { action: path, method: :post }
) do %>
  Button Text
<% end %>
```

```javascript
// app/javascript/controllers/neo_button_controller.js
export default class extends Controller {
  static values = { confirm: String }
  
  handleClick(event) {
    if (this.confirmValue && !confirm(this.confirmValue)) {
      event.preventDefault()
    }
  }
}
```

---

## Notification System Architecture

### Event-Driven Pattern
1. **OutboxEvent**: Captures model changes via callbacks
2. **FanoutService**: Determines notification recipients  
3. **ScoreCalculator**: Calculates notification priority
4. **Notification**: Final notification with channels (in_app, email, webhook)

### Central Constants System
```ruby
# app/models/concerns/notifications/constants.rb
module Notifications::Constants
  EVENT_TYPE_TICKET_ASSIGNED = 'ticket_assigned'.freeze
  EVENT_TYPE_MAPPING = {
    'ticket.assigned' => EVENT_TYPE_TICKET_ASSIGNED
  }.freeze
end
```

**Thread safety**: Use fully qualified namespaces in background jobs
```ruby
# ✅ Correct in jobs/services
event_type = Notifications::Constants::EVENT_TYPE_MAPPING[key]
```

---

## Critical Bug Fixes (DO NOT OVERWRITE!)

### Turbo URL Object Bug (12 August 2025)
**Problem**: Pagination did not work from detail views and generated `/tickets/undefined` URLs.

**Fix**: Line ~211 in application.js:
```javascript
// ✅ CORRECT - Turbo expects a URL object
event.detail.url = currentUrl;

// ❌ WRONG - would cause the bug!
// event.detail.url = currentUrl.toString();
```

**Important**: NEVER change this line to `.toString()`! Turbo's internal processing expects a URL object.

### Stimulus Controller Index Bug (20 August 2025)
**Problem**: JavaScript Stimulus controller 404 errors in production/staging caused by relative imports.

**CRITICAL RULE**: `app/javascript/controllers/index.js` uses a **custom implementation** with `eagerLoadControllersFrom`.

**NEVER:**
- Overwrite the file with explicit controller imports
- Run `rails stimulus:manifest:update` directly (destroys the custom version)
- Revert to relative imports (`from "./controller"`)

**ALWAYS:**
- Retain the custom `eagerLoadControllersFrom` solution
- Use `rails stimulus:manifest:update_safe` for updates
- Follow the documentation in `docs/STIMULUS_CONTROLLER_MANAGEMENT.md`

**Why**: Relative imports bypass importmap resolution → unhashed URLs → 404 errors in production.

### Signed Active Storage URLs in Lists (8 September 2026)
**Problem**: The ticket list sometimes returned 429 “Too many requests” in production.
Every avatar tile loaded its image through `rails_storage_proxy_path`, and the route stamps
expiry (`config.active_storage.urls_expire_in`, 15 minutes) into the signature with millisecond precision.
The same image therefore had a different URL in every row: no browser caching, 53 to 59
Rails requests per list load, and Rack::Attack (`requests/ip`, 300 per 5 minutes,
`/rails/active_storage` included) throttled the list itself.

**Fix**: `Neo::Users::AvatarComponent#picture_url_expires_at` rounds expiry to slots of the
configured length and passes it as `expires_at:`; the link is valid until the end of the
slot after the next one. Guards: `spec/components/neo/users/avatar_component_spec.rb` (slot rule)
and `spec/requests/organisations/tickets_name_display_spec.rb` (four rows, one URL).
History: `docs/letzte_arbeiten/2026_09_08_1_letzte_arbeiten_avatar_adresse_slot.md`.

**Important**:
- Anyone rendering an image **per row** through a signed URL (`rails_storage_proxy_path`,
  `rails_blob_path`, `url_for(variant)`) gets the same bug without rounded `expires_at:`.
  Stabilize the URL; **do not** loosen the throttle.
- `freeze_time` makes this bug invisible in a spec: all rows then render in the
  same millisecond, and even the old code returns one URL. Such guards run in
  real time.

---

## Database Schema & Migrations

### UUID Primary Keys
All tables use UUID primary keys with a `gen_random_uuid()` default.

### PostgreSQL Enums
```sql
-- Example event types
CREATE TYPE notification_event_type AS ENUM (
  'ticket_commented', 'ticket_assigned', 'ticket_unassigned', 
  'ticket_status_changed', 'ticket_blocker', 'project_announcement',
  'document_added', 'mention', 'system_message'
);
```

### Migration Best Practices
* Create migrations with `ActiveRecord::Migration[8.1]`
* Enum extensions: `ALTER TYPE ... ADD VALUE IF NOT EXISTS`
* Write reversible migrations
* Avoid long locks (add_column without a default, then UPDATE separately)
* Data migrations as tasks/services, **NOT** in schema migrations

---

## Background Jobs & Performance

### Solid Queue (Rails 8 Native)
Main job system for notifications, emails and cleanup tasks.
```ruby
# Job definition
class ProcessNotificationJob < ApplicationJob
  queue_as :notifications
  
  def perform(notification)
    # Job logic
  end
end
```

### Performance-Critical Scopes
```ruby
# app/models/notification.rb
scope :for_notification_center, -> {
  includes(:actor, :notifiable, :project)
}

scope :with_email_log_counts, -> {
  left_joins(:email_logs)
  .group('notifications.id')
  .select('notifications.*, COUNT(email_logs.id) as email_logs_count')
}
```

### Caching Strategy
* Fragment caching for components: `cache [@notification, 'card_v2']`
* Russian doll caching for nested structures
* Database-level indexing for frequent queries

---

## Testing Strategy

### Test Pyramid
* **System tests** (Capybara): Main user flows
* **Request tests**: Authentication, authorization, API endpoints
* **Model tests**: Validations, scopes, callbacks, business logic
* **Component tests**: Test ViewComponents in isolation
* **JS tests**: Stimulus controllers (when logic is complex)

### Bug-Fix Rule
**ALWAYS**: First write a failing test that reproduces the bug → then fix it → keep the test as a regression guard.

```ruby
# spec/models/notification_spec.rb
it 'prevents duplicate notifications for ticket creation with assignees' do
  ticket = create(:ticket, assignees: [user])
  activity = create(:activity, trackable: ticket, key: 'ticket.created')
  
  expect {
    Notifications::FanoutService.new(activity).call
  }.not_to change(Notification, :count)
end
```

### Test Convention: Status Symbols Go Directly to Rack

**Binding** (guard spec: `spec/architecture/rack_status_symbol_guard_spec.rb`; automatically runs through the
`spec/architecture/` directory entry in the CI guard list, without its own entry):

Rack 3.1 renamed two status symbols; Rack 3.2 warns on every use of the old spelling
and announces their removal. The numeric value remains the same in both cases.

| ❌ Deprecated | ✅ Current | Code |
|---|---|---|
| `:unprocessable_entity` | `:unprocessable_content` | 422 |
| `:payload_too_large` | `:content_too_large` | 413 |

* **In controllers, the old spelling is harmless, but only from actionpack 8.0.5.1 onwards**:
  `ActionDispatch::Response.rack_status_code` translates in both directions before asking
  Rack. Under 8.0.2, this layer does not yet exist, so `render status:` warns too. Rails and
  Rack must therefore move together.
* **In specs, this layer never exists.** rspec-rails passes the symbol unchanged to
  `Rack::Utils.status_code` (`have_http_status.rb:219`). That is exactly why the guard covers `spec/`,
  not `app/`.
* The guard checks against `Rack::Utils::SYMBOL_TO_STATUS_CODE` instead of a word list: anything
  absent there is deprecated. It catches the next rename without maintenance too.

### Browser specs: the window goes back after every example

One Chrome per driver lives for the whole run, so a resized window outlives its example.
`BrowserWindow` (`spec/support/capybara.rb`) names each driver's size once and puts the window
back after every system example (guard: `spec/system/browser_window_reset_spec.rb`). Until
2026-11-13 an example saw the size the file before it had left: green alone, red in the full
run. A spec that needs another size still resizes for itself; it no longer has to undo it.

* ⚠️ A width or a position read once is a frame of whatever is still moving. A lane slides
  open in 0.25 s, a ranked column eases to zero in 0.25 s: wait for the cause
  (`wait_until_still` in `spec/support/motion_helpers.rb`, `ranked_columns_at_rest` in
  `column_picker_spec.rb`), not for a number of milliseconds.
* ⚠️ After a Turbo visit the assistant panel may load its frame again and restore the draft
  into a NEW composer: `turbo_visit_awaiting_panel_frame` (`spec/support/assistant_panel_helpers.rb`).

### Factory Patterns
```ruby
# spec/factories/notifications.rb
FactoryBot.define do
  factory :notification do
    association :recipient, factory: :user
    association :organisation
    event_type { Notifications::Constants::EVENT_TYPE_TICKET_ASSIGNED }
    channel { 'in_app' }
    # tenant-aware factory
  end
end
```

---

## Directory Maps (nested CLAUDE.md)

The most costly areas have directory-local maps, which Claude Code loads automatically
when work begins there: `app/models/`, `app/services/` (+ `notifications/`,
`lalabase/`), `app/controllers/concerns/`, `app/javascript/controllers/`. Maps are ≤ ~40 lines,
carry an as-of date and **reference rather than duplicate**.

### Boy Scout Rules (when already touching the code, no big bang)

* Substantial changes to a flat model belonging to a namespaced domain → move it into the namespace (keep `self.table_name`).
* Touching a nontrivial controller write → extract an actor (seam rule above).
* Substantial changes to a service without the `.call(**kwargs)` convention → migrate it + remove it from the guard allowlist.
* Touching inline `<script>` heredocs in controller actions → move them into Turbo Stream templates/Stimulus.
* Touching a duplicate Stimulus controller → consolidate on the `neo_*` variant (list: `app/javascript/controllers/CLAUDE.md`).

---

## Pattern Selection Quick Reference

* **ViewComponent**: Reusable UI components with encapsulation and testability
* **Service object**: Complex business logic, multiple steps, external APIs
* **Concern**: Small reusable logic shared across models/controllers
* **Job (Solid Queue)**: >200 ms, external requests, batching/retries needed
* **Turbo Stream**: Small local UI update, triggered server-side
* **Stimulus controller**: More complex client interactions or browser state
* **Feature flag**: Risky changes, incremental rollout
* **Form object / view model**: Complex forms, multiple models

---

## Actor Pattern (Write Seam)

Nontrivial writes go through **command objects** under `app/services/actors/`
(`Actors::SaveTicket`, `Actors::DestroyPost`, …). An actor encapsulates **one** write: transaction,
validation/error mapping, `Current.user` for activity tracking, side-effect jobs after commit.
Hardened in `Actors::BaseActor`; the contract is enforced by a guard spec
(`spec/services/actors/actor_contract_guard_spec.rb`).

### Naming (Resolving the Collision)
“Actor” here means a **command object**. It has **nothing** to do with `Activity#actor` /
`Notification#actor` — those identify the **audit user** who triggered a change.
Deliberately distinct; do not conflate them.

### Seam Rule: When Actor, When Controller?
* **Nontrivial write → actor.** Nontrivial = multiple steps / own transaction /
  activity tracking / fanout / background job / external API call / association sync.
* **Trivial write → controller.** Trivial = a single `update!`/`create!` on one model
  without side effects. Trivial CRUD stays in the controller (no blanket rollout).

### Contract (Binding, Guard-Checked)
* **Keyword arguments** everywhere: `Actors::X.new(project:, params:, id: nil, current_user:)`. The
  user parameter is named `current_user:` (NOT `actor:` — collision, see Naming).
* Prefer `Actors::X.call(...)` as the entry point; `.new(...).call` only when the caller needs `#record`
  before `#call` (e.g. `PostUpdateService`).
* **Tier 1** (default): implement only `#perform` (+ `#record`, optionally `#enqueue_jobs`)
  — `BaseActor#call` handles transaction, error mapping, `Current.user` and enqueuing.
* **Tier 2** (exception, in the guard spec's `tier_2_actors` allowlist): own `#call`, shares only the
  helpers. The authoritative list is the allowlist itself (currently 5: `SaveTicket`,
  `AcceptTicketSuggestion`, `CreateAiPost`, `GenerateGroupCustomerDescriptions`, `CreateSignup`; `MoveTicket` has been
  Tier 1 since 8 September 2026, with its number retry in `Tickets::Mover`) — per-actor reasons
  are comments on the `tier_2_actors` let in the guard spec.
* **Errors:** Domain failures through `raise Actors::ActorError, msg` (→ failure result);
  `RecordInvalid` is mapped automatically. Everything else is “unexpected” →
  `handle_unexpected_error`: dev/test **re-raise** (crash loudly), production log + failure.
* **Jobs:** NEVER raw `perform_later` — always `enqueue_after_commit { SomeJob.perform_later(...) }`,
  so the job fires only after the outermost real commit (correct under nesting).
* **`Current.user`:** NEVER set it manually — `with_actor_context` sets + restores it (no leak).
* **`#record`:** returns the primary record or `nil` (never a collection).

---

## Service Convention (app/services)

New services: entry point is `Klass.call(**kwargs)`, `#initialize` takes only keyword arguments, at least
one explanatory comment line at the file's top. Read/query objects with domain verbs instead declare
`# Entry point: <method>` in the header. Enforced by
`spec/services/service_convention_guard_spec.rb` (existing code on a shrink-only legacy allowlist —
migrate + remove on substantial changes). Details: `app/services/CLAUDE.md`.

---

## API Namespaces (Core and Separate Website)

Four namespaces under `/api`, distinguished by **who** calls:

| Namespace | Caller | Authentication | Contract |
|---|---|---|---|
| `Api::V1::*`, `Api::McpController` | A person with an account | Personal access token + Pundit | `doc/mcp_server_plan.md` |
| `Api::Public::*` | Anyone, including anonymous callers | None, read-only | `docs/api/public_v1.md` |
| `Api::Provisioning::*` | The separate website | A shared secret from ENV | `docs/api/provisioning_v1.md` |
| `Api::Auth::*` | A program signing a person in, without a token yet | Email and password in the body, once | “Sign-in door” section below, specs under `spec/requests/api/auth/` |

* Both new namespaces inherit from their **own** `ActionController::API` base, never from
  `ApplicationController`: no session, no Pundit, no tenant from the session. Guards:
  `spec/architecture/{public,provisioning}_api_contract_guard_spec.rb` check **classes**,
  not text.
* The provisioning entry point is **disabled when no secret is set** (404, not 403):
  another instance exposes no entry point it does not use. A personal access token is
  never accepted there; it belongs to a person with organisations.
* The write itself belongs to the actor also used by the core's form
  (`Actors::CreateSignup`). A second registration implementation alongside it is the mistake W2
  just eliminated.
* **Two forms, one write.** Our registration form lives in
  `gboyke/lalabase-website` and may look however we want; the core's form belongs to
  self-hosted instances and invited users (an invitation token cannot be redeemed by
  an external sign-in page). The **forms** are separate, never the actor. Anything specific
  to our business therefore belongs in the website form: the new-founder discount was
  removed from the core form on 20 September 2026; `FounderSignup` and the provisioning entry point
  remain.
* Responses carry **one** envelope: `data.<thing>` on success, `error.{code,messages}` on error.
  `code` is machine-readable, `messages` are translated text. Deliberate exception: `Api::Auth`
  returns errors in the `/api/v1` shape (`Api::V1::ErrorBody`) because the same client reads both
  entry points.

**Sign-in door `/api/auth/v1` (K6b, 2026-11-16, API 1.14.0, capability `app_sessions`).** A client
signs a person in with e-mail address and password and gets a device token
(`PersonalAccessToken`, kind `app_session`) once. `GET /api/auth/v1/methods` says what the instance
offers (`data.sign_in.methods`, the pages for reset, unlock and confirmation), names no version and
no instance, and has no method in demo mode. `POST /api/auth/v1/app_sessions` takes
`user.email`, `user.password` and `device.name` as `application/json` of at most 4 KB and answers
201 with `data.token`, `data.session` and `data.user`, `Cache-Control: no-store`.
`Api::Auth::BaseController` is its own `ActionController::API` base: no token, no Pundit, no
tenant, no session, routes with `format: false`; the guard
`spec/architecture/auth_api_contract_guard_spec.rb` checks the classes. Rules that must hold for
the next change:

* **The door never tells more than the web sign-in.** An unknown address, a wrong password and a
  locked account answer the same 401 (`reason: invalid_credentials`), a locked account also for
  the right password. There is no `account_locked` and no warning before the last attempt.
  `email_unconfirmed` and `account_deactivated` (403) answer the right password only.
* **It does not run through Warden.** `AppSessions::Authentication` asks Devise's questions in
  Devise's order (`find_for_database_authentication`, `valid_for_authentication?` with the
  password in the block, `active_for_authentication?`), hashes a password for nothing when the
  address is unknown, and resets the counter itself after a success. Failed attempts count
  towards the lock of the web.
* **The language comes from `Accept-Language`, else the default, never from the account:** the
  language of a refusal would tell whether the address exists.
* **No `Idempotency-Key`.** The answer holds the token, and that store keeps answers. A client
  that lost the answer signs in again.
* **The brake is shared with the web.** `Rack::Attack::APP_SIGN_IN_PATH` counts in `logins/ip`
  and `logins/email`; a bucket of its own would double the guesses. The address is read from the
  JSON body only, so the door refuses any other content type (415) and a larger body (413,
  `Lalabase::AuthBodyLimit`, a middleware in front of the parser like the provisioning limit).
* **Closed in demo mode (404):** the demo account has a published password and is exempt from
  the lock and the per-address brake.
* The write is `Actors::CreateAppSession`: under a lock on the user's row it makes room (at most
  `PersonalAccessToken::MAX_APP_SESSIONS` live devices, one more revokes the device unused
  longest, never a personal token), creates the token and notes the login
  (`login_method: app_session`, the device name). Two sign-ins at once wait for each other
  on that lock (`create_app_session_concurrency_spec.rb`, two connections).
* **The content type is read as sent** (`Rack::MediaType`), the way the brake reads it. Rails'
  own reading takes `text/x-json`, `application/jsonrequest` and `application/problem+json` for
  JSON and parses them; the door would have looked an account up where the brake found no
  address. The brake also reads the body of this path whatever the type says.
* **`Lalabase::AuthBodyLimit` refuses in front of the parser**: a body over 4 KB (claimed or
  measured, 413) and a body of bytes that are no UTF-8 (400, in the error shape). Rails refuses
  such bytes itself and names the value in the error line of its log, at the level of
  production and past the parameter filter; here the value may be a password. A body that is
  not sent as `application/json` is taken away before any parser reads it (the form parser
  names a value with a stray per cent sign the same way), and the door answers its 415. In
  demo mode the class answers 404 like the door. The brake reads an address it cannot decode as no
  address (`Rack::Attack.login_email`; it raised there, on the web sign-in as well).
* **The activity log reads the request through `AppSessions::RequestFacts`.** Only a known
  account is noted, so a header that made the note raise (a User-Agent the database refuses,
  a Client-IP that contradicts X-Forwarded-For) became an answer only a known address gave.
  A note that still fails never decides the answer of a refusal.
* **The password is asked once more under the lock** (`Actors::CreateAppSession`, code
  `stale_credentials`, answered as `invalid_credentials`): a new password revokes every token
  once, at the change, and a sign-in checked just before it must not write just after it.

Guards: `spec/requests/api/auth/v1/{methods,app_sessions,body_limit}_spec.rb`,
`spec/services/app_sessions/authentication_spec.rb`, `spec/services/actors/create_app_session_spec.rb`
and `create_app_session_concurrency_spec.rb`,
`spec/requests/auth_throttle_spec.rb` (the shared buckets), `spec/architecture/api_v1_error_body_guard_spec.rb`
(the folder `api/auth`).

**Sign-out `DELETE /api/v1/app_session` (K6c, 2026-11-16, API 1.15.0, capability
`app_session.revoke`).** It revokes the token the request came with, a device token or a personal
one, and no other: there is no id to name. It lives under `/api/v1` because a person with a token
calls: `authorize current_token, :destroy?` through `PersonalAccessTokenPolicy`, the write is
`Actors::RevokeAppSession` (`track_logout` with `logout_type: app_session` and the name of the
token). A read-only token is stopped by the gate of the base (403 `read_only`) and stays alive.
A second call with the same token gets 401, and a client reads 401 on a sign-out as done.

* `PersonalAccessToken#revoke!` writes without validation. A token that no longer passes a
  validation of its own (its only organisation is gone) still authenticates, so it must still
  be revocable; a validating save refused it, on the token page as well. It writes only a row
  that is not revoked yet and says whether it did: the first revocation keeps its moment, and
  the actor notes one logout for two calls that both read the token before either wrote.
* If the note of the logout fails, nothing happened: the write rolls back, the answer is 500
  and no answer is kept for the key. A token of another account raises when the actor is made.
* ⚠️ **The one step of `/api/v1` in front of authentication.** A retry with the same
  Idempotency-Key reads the first answer again, as on every write. But this write revokes the
  token the retry comes with, and the replay of the base sits behind authentication. So this
  action, and no other, looks for its stored answer first (`#replay_stored_sign_out`,
  `PersonalAccessToken.find_revoked`): the token must be revoked, the row its own, under this
  key, of this action and of the same request. It answers a revoked token only with what that
  token was told before. Every other call with it gets 401. Do not copy the step to another
  action: there a stored answer may hold more than a moment.

Guard: `spec/requests/api/v1/app_session_spec.rb`.

For the REST ticket member routes (including `GET /tickets/:ticket_id/posts/:id`) and the
number route, `Api::V1::ReadableTicket` resolves tickets
through the token's effective organisation/project reach and `TicketPolicy::Scope`:
missing and unreadable tickets return 404 with `{"error":"not_found","code":"not_found"}`.
Denied actions on readable tickets remain 403; read-only tokens reject writes with 403
(`"code":"read_only"`) before any ticket lookup, including missing IDs. Status and body are equal for missing and
unreadable tickets, but queries are not: discovering the unknown tenant reads only
`organisation_id` and `project_id` first. Ticket IDs are random UUIDs, not sequential
numbers; this deliberately accepts query asymmetry instead of searching every
organisation the token reaches. It makes no constant-time guarantee.

What a token holder can find is decided by `Tickets::ReadableForToken` alone (REST, MCP tools,
`Tickets::RelationAccess`), reach before policy scope. `token:` is required on it and on
`Tickets::RelationAccess`: `nil` means no second limit and is written out by the callers without
a token. Guards: `spec/architecture/ticket_token_lookup_guard_spec.rb` (also refuses these
finders and `TicketRelation.visible_to` without a token on the token surfaces) and
`ticket_relation_actor_callers_guard_spec.rb`.

**`/api/v1` for programs** (REST R0, 2026-10-28; the terminal client moves from MCP to REST
feature by feature):

* **Error bodies** keep `error` and the HTTP status as they always were and add `code`, the
  MCP vocabulary (`invalid_input`, `read_only`, `forbidden`, `not_found`, `refused`, plus
  `unauthorized`); an unmapped actor code is `refused` with the old value as `reason`. One
  status changed on purpose: an unexpected actor failure (`internal_error`) on
  `time_sessions.create` (R6) and `posts.create` (R3a) answers 500 without the exception's
  text, where it was a 422 that carried it. Every
  body comes from `Api::V1::ErrorBody` through `BaseController#render_error`; guard
  `spec/architecture/api_v1_error_body_guard_spec.rb`. Answers outside the controllers carry
  no `code`: the Rack::Attack 429 (plain text), a 500 from the exceptions app, a 400 for a
  query string Rack cannot decode (`?x=%`; raised in middleware before any controller), a query or path parameter of raw bytes that are no valid UTF-8 (`?q=%FF`, an HTML 400 before authentication, the same whatever exists), and a
  400 for a body parameter of raw bytes that are no valid UTF-8, form or JSON (Rails raises
  `ActionController::BadRequest` when it first reads the parameters, in its params wrapper or
  its request log, before any callback or `rescue_from` of `BaseController` runs; a JSON escape
  of a lone surrogate is a parse error instead, answered as 400 `bad_request` with `code`). The 401 of `/api/mcp` (same concern,
  `render_unauthorized`) keeps its old body.
* **`Idempotency-Key`** on every write (`idempotent :create` in the controller,
  `Api::V1::Idempotent`): the same key and request replays the first 2xx answer (status and
  body), another request answers 422 `idempotency_key_reused`. Same table and store as MCP
  (`Mcp::IdempotencyStore`); the REST fingerprint includes method and path, so a key never
  crosses surfaces. Runs inside authentication and the read-only gate. A key is at most 255
  bytes of valid UTF-8 without NUL (else: 422 `invalid_idempotency_key`, nothing written).
  One rule for both surfaces, `Mcp::IdempotencyStore.client_key` (strip, blank is no key) and
  `.storable_key?` (`IdempotencyStore.new` raises on any other key, before the write, so a
  third caller cannot skip it): since MCP 0.13.1 a write tool refuses such an `idempotency_key` as
  `invalid_input` before it runs, after the project and read-only gates (guard
  `spec/requests/api/mcp_idempotency_key_bound_spec.rb`; it used to write, fail to remember
  the key with -32603 and write again on every retry). A replay checks no rights
  (it repeats what the same token already got; keys do not expire), and a retry must send
  the same bytes. Multipart bytes Rack accepts but JSON cannot encode are fingerprinted
  without decoding, so the action still applies its permissions and input validation.
  Existing JSON fingerprints stay unchanged. Every write route must be `idempotent`
  (`spec/architecture/api_v1_writes_idempotent_guard_spec.rb`).
* ⚠️ **A `rescue_from` handler runs outside the token owner's language**: the action's
  `around_action :with_token_owner_locale` has ended by then. A text built at the raise is right;
  one built in the handler needs `with_token_owner_locale { ... }` (`TermsController#glossary_forbidden`).
* **One strict reading of a page value**: the lists that refuse a `page`/`per_page` they cannot
  read (the glossary on both doors; over REST the people directory, knowledge and meetings) read it
  through `ListPaging.strict_number`: a whole number from 1 to the maximum (as text digits only,
  as a JSON number also `2.0`), absent or empty the default, one wording in the token owner's
  language. Each door keeps its own error class and status (400 or 422). A new strict list uses it;
  the inbox, the posts of a ticket and `list_projects` keep rules of their own (they clamp).
  Guard: `spec/services/list_paging_spec.rb`.
* **`GET /api/v1/me`** names `api_version` and `capabilities` from `Api::V1::Capabilities`,
  pinned against the routes both ways (`spec/requests/api/v1/capabilities_spec.rb`): a new
  endpoint adds its line there. Additive changes bump the minor.

`POST /api/v1/tickets/:ticket_id/time_sessions` books by the rule the MCP tool
`create_time_session` books by (REST R6, 2026-10-29; feature `time_sessions.book` in
`/me`): `TimeSessions::Booking` refuses no duration, both `duration_string` and
`duration_minutes`, `duration_minutes` that is no whole number, and an `occurred_on` that is
no ISO 8601 date or timestamp (422
`validation_failed`/`invalid_input`, inside the read gate), dates the booking as the
calendar day in the token owner's profile zone (stored as midnight; absent = today there),
and writes through `Actors::SaveTimeSession`; an unexpected actor failure (`internal_error`)
answers 500 without its message. Rights stay in the controller. A booking
writes no activity and no notification; it touches the ticket's `updated_at`. Guard:
`spec/requests/api/v1/time_session_booking_spec.rb`.

**Ticket view** (REST R1, 2026-10-29, API 1.3.0):

* `GET /projects/:project_id/tickets` names `meta.available_statuses`, the project's status
  keys from the same source as MCP `list_tickets`.
* `GET /tickets/:id` takes opt-in pages: any one of `posts_page`, `posts_per_page` (at most
  50, above is 422), `posts_order` (`oldest`, `newest`), `attachments_page` (10 per page)
  switches the answer to the paged fields of MCP `get_ticket` (`posts_total`,
  `posts_truncated`, `attachments`, ...). **Without them the body stays what it was** (the
  contract records it; gboyke/lalabase-mcp reads it and passes it on), but for the additive
  `attachments` on a comment since R7, below. Invalid values: 422 `invalid_input`,
  checked before the ticket is looked up. A key without a value switches too. REST does not
  truncate bodies, nor the extracted `text` of attachments (up to 10 per page). These
  `attachments` are the ticket's own files only, with text and without URL (`attachments_total`
  counts those); `GET /tickets/:id/attachments` lists ticket and comment files with signed URLs.
* `GET /projects/:project_id/tickets/number/:number` answers what `GET /tickets/:id` answers,
  paging included. Missing, malformed (`abc`, `0`), unreadable, out of reach or foreign: the
  same 404. The number is looked up only inside that project.
* `GET /tickets/:ticket_id/posts/:id`: one readable comment, whole, in the shape of a comment
  in the ticket. Hidden private, foreign and missing comments: the same 404.
* Options and pages come from `Tickets::Reading`, shared with MCP `get_ticket`; MCP keeps its
  caps. Guard: `spec/requests/api/v1/ticket_view_spec.rb`.
* **A comment lists its files** (REST R7, 2026-10-30, API 1.8.0, MCP 0.14): `attachments`
  beside `attachments_count`, wherever a comment is served (`Tickets::Serializer#post_payload`:
  the ticket, whole or in pages, the number route, the comment route, MCP `get_ticket`), each
  with `id`, `filename`, `content_type`, `byte_size`, in id order. ⚠️ `id` is the
  `PostDocument`'s, which the file proxy takes (`/org/:org/files/post_document/:id`), NOT the
  Active Storage attachment's that `GET /tickets/:id/attachments` hands out with a signed URL.
  No URL and no text, so `get_ticket`'s caps hold as they were. No capability: a client takes
  the field's presence as the signal. Visibility is the comment's (`readable_by`), no second
  rule. `attachments_count` counts rows: a document that lost its blob stays in the count and
  leaves the list. Guard: `spec/requests/api/v1/comment_files_spec.rb`.

`GET /api/v1/time_sessions/open` lists the person's own open hours within the token's
reach, organisations AND projects, and only the rows the web time list shows them
(`TimeSessions::ViewingScope`). A booking on a ticket they cannot read keeps its row and
its minutes, with `ticket: null`. Owner: `TimeSessions::OpenHours`; guard:
`spec/requests/api/v1/time_sessions_open_access_spec.rb`.

`GET /api/v1/organisations` and `GET /api/v1/projects` read through
`PersonalAccessTokens::ReachListing`, the reader of the MCP tools `list_organisations` and
`list_projects` (MCP 0.15.0). The rows are the same, the rest differs on purpose: REST answers 200
with `[]` for an organisation out of reach and shows an admin archived projects unpaged and uncut;
MCP answers `not_found`, shows archived projects on request, pages by 100 and cuts a description.
MCP also lists only what the project gate opens; REST lists what the policy scope shows, which
is wider for a role holding nothing but time tracking.
Guards: `spec/services/personal_access_tokens/reach_listing_spec.rb`,
`spec/requests/api/mcp_list_projects_spec.rb`, `spec/requests/api/v1/projects_listing_spec.rb`.

`GET /api/v1/projects/:project_id/knowledge` (REST R2, 2026-10-29, API 1.6.0, capability
`knowledge.search`) lists a project's notes and documents by title through `Knowledge::Lookup`,
the read the MCP tool `search_knowledge` uses: the same rows, order (`updated_at` newest first,
then id), fields (`type`, `id`, `title`, `updated_at`, `link`) and `total` for the same search.
Rows only through the per-type policy scope: no title and no count of a type the reader may not
read; a reader who may open the project but read no knowledge gets an empty list. Without `q`
(or blank) REST lists every readable row; MCP keeps `q` required. `type` other than `note` or
`document`, and `page`/`per_page` that are no whole number from 1 to the maximum (`per_page` at
most 100, where MCP clamps) and a NUL in `q` or `type` answer 422 `invalid_input`, checked
before the project; an absent or empty `page`/`per_page` is the default. A page beyond the total
reads no rows. The project gate is MCP's (token reach and `ProjectAccessService`): missing,
malformed, beyond the reach, not openable (an archived project for a non-admin included) and foreign answer the same 404.
Guards: `spec/requests/api/v1/knowledge_spec.rb`, `spec/services/knowledge/lookup_spec.rb`.

`GET /api/v1/projects/:project_id/meetings` and `GET /api/v1/meetings/:id` (REST R8, 2026-11-03,
API 1.10.0, capabilities `meetings.list`, `meetings.show`; no MCP tool) read a project's meetings
and one meeting. Fields are `Meetings::Serializer`'s two allowlists: a row has no text of the
meeting, the whole answer adds `participants` (names only), `generated_summary` (Markdown),
`notes`, `transcript` (uncut, a leading metadata block left off as on the web), `updated_at`,
`path`. `creator.name` is null when the account is gone, the id stays. No analyses, ticket suggestions or linked tickets: each has a visibility rule of its own.
The list runs `Meetings::ListQuery`, the web list's order (`occurred_at`, then the entry time,
then `id`, all newest first) and `Meeting.search_by_content`, on `policy_scope(project.meetings)`
and nowhere else, because the search matches inside transcripts. Paging and `q` by the strict
rule of knowledge, before the project (a 422 says nothing about it). The list's gate is
`Api::V1::ReadableProject`, shared with knowledge; a reader without the meetings area gets an
empty list. `Api::V1::ReadableMeeting` answers one 404 in status and body for missing, malformed,
out of reach, foreign and no area, and turns a policy refusal into that 404 as well: unlike a
ticket, a meeting never answers 403. An archived project is the web's: closed to a member, open
to an account admin. Guard:
`spec/requests/api/v1/meetings_read_spec.rb`.

`GET /api/v1/organisations/:organisation_id/people` and `.../people/:id` (People S3b) read
the people directory through `People::Lookup`, the object the assistant's `find_people` /
`get_person` and their MCP twins read as well: one rights question (the people right, 403
without it), one search, one field selection (a list row never carries contact details or
notes; the card carries the notes, MCP and the assistant never do). Only a token that
reaches every project of the organisation reads its directory: a token limited to some
projects, an organisation outside the token (a deactivated membership included) and a
missing one answer the same 404, as do a missing and an invisible person. The list pages
by 50, at most 100; a value outside is a 400, never cut. Guards:
`spec/requests/api/v1/people_spec.rb`, `spec/requests/api/mcp_people_spec.rb`,
`spec/requests/api/people_parity_spec.rb` (REST and MCP answer the same rows).

`GET /api/v1/organisations/:organisation_id/terms` (K4c, 2026-11-06, API 1.11.0, capability
`terms.list`) and the MCP tool `get_glossary` (MCP 0.18.0, `:mcp` only) read an organisation's
glossary through `Glossary::Lookup`, for a device that hands the terms to its speech recognition
and replaces learnt wrong forms before it sends. Only what works: confirmed terms, and at them the
heard forms of `TermCorrection.effective` (a confirmed term without one has an empty `heard`),
grouped by the compared form with the spelling last heard, `count` the sum of `replaced_count`,
`speakers` as refs of the people directory. The glossary right of the token's owner
(`GlossaryPolicy`, an active membership) or 403 with `reason: glossary_forbidden` (MCP `refused`,
the same reason and text). Unlike the people directory, a token limited to some projects is
answered: every term, the heard forms of its projects only, and a form without a project only for
a token that reaches every project. An organisation outside the token, a foreign, a missing and a
malformed one answer the same 404 (MCP `not_found`, also for a malformed id); a member deactivated in
an organisation the token names gets the 403 of the missing right instead (the reach still leaves that
organisation out, `PersonalAccessToken#deactivated_member_of?` only words the refusal), a removed
membership the 404; `project_id` puts the
forms of its project first, outside the organisation or the token the same 404. `people` and
`speakers` only with the people right (`PersonPolicy`), named as the directory names them to the
reader; whom it does not list counts in `count` alone. No meeting, place or corrector in the
answer. Pages by 50, at most 100, a whole number outside is a 400 (MCP `invalid_input`, the same text
after the same checks: the bounds are the reader's, not the tool schema's). The types stay the schema's:
a value of another type, `null` included, the MCP SDK refuses before any tool runs, in its own words,
as for every tool; a whole number written as `2.0` is one (JSON Schema's integer). Guards:
`spec/requests/api/v1/terms_spec.rb`, `spec/requests/api/mcp_glossary_spec.rb`,
`spec/requests/api/glossary_parity_spec.rb` (REST and MCP answer the same),
`spec/services/glossary/lookup_spec.rb`.

`POST /api/v1/tickets/:ticket_id/posts` (REST R3a) writes by the rule the MCP tool
`post_comment` writes by, `Posts::Comment`, through `Actors::SavePost` like the web form:
`post[format]` `html` (the default, the body stored as sent) or `plain` (literal text through
`Posts::PlainTextBody`: escaped, blank lines into paragraphs, single breaks into `<br>`). An
unknown format, one that is no string (read raw: strong parameters would drop a list and fall
back to html), NUL in a plain body and a plain body that converts to nothing answer 422
`validation_failed`/`invalid_input` with a text from `services.post_comment.*`, checked inside
the read gate. Without `format` the answer stays byte for byte: an empty body is the model's
refusal, after the write check, with every model message (the contract case `html_empty` was
recorded before R3a), and a JSON `false` as body counts as none, as before. Raw invalid bytes
in a form or JSON body never reach the rule (the 400 above); MCP refuses them. Only a multipart
part can name a charset of its own (`text/plain; charset=...`): `html` hands it to ActionText as
it came, as before (a Latin-1 comment keeps its letters), `plain` transcodes it to UTF-8, and a
`plain` part declared binary must hold UTF-8. An unexpected actor failure (`internal_error`) answers 500 without the exception's
text, every other failure 422 `validation_failed` as before; MCP answers `comment failed:
unexpected error`. ⚠️ A failure after the commit (an after_commit callback or a job enqueue
that raised) leaves the comment written: `Posts::Comment#save` counts it as saved, so REST
answers 201 and keeps its Idempotency-Key, and MCP returns the comment. Answered as an error,
a retry with the same key wrote it twice, because the key keeps only successes. Capability
`posts.plain`. Guards:
`spec/requests/api/v1/post_comment_format_spec.rb`, `spec/services/posts/comment_spec.rb`,
`spec/requests/api/mcp_plain_comment_spec.rb`, `spec/locales/token_rule_refusal_texts_spec.rb`
(the refusals of `Posts::Comment`, `TimeSessions::Booking` and `Tickets::Change`, the MCP texts and
the de and en keys are three lists kept by hand; the guard holds them together).

`POST /api/v1/tickets/:id/changes` (REST R3b, 2026-10-30, API 1.7.0, capability
`tickets.changes`) changes ONE thing by the rule the MCP tool `update_ticket` changes by,
`Tickets::Change`: `change[title]`, `change[status]` (a key of `meta.available_statuses`), or
`change[add_assignee_ids]` and `change[remove_assignee_ids]` (at most 50 each, `"me"` is the token
owner) against the current list. The kind is decided by the keys present, not their values. It
answers 200 with the ticket summary, like `PATCH /tickets/:id`, which stays as it is: its
`assignee_ids` REPLACE the list, and `gboyke/lalabase-mcp` relies on that. `parent_id` on that
PATCH reaches the model (`Ticket#parent_unchanged`, a saved ticket keeps its parent): another
parent or an empty value is a 422 `validation_failed`/`invalid_input`, the current parent is no
change, so a client may send back what it read. That PATCH writes and answers under the same row
lock in the authorized project (`locked_ticket` in the controller, since 2026-11-05: a move after
the rights check let it write into a project the caller may not write; guard
`spec/requests/api/v1/ticket_update_concurrency_spec.rb`). Status and assignees
go through `Actors::ApplyTicketChanges` like a board drag (a `TicketBulkRun` included), the title
through `Actors::SaveTicket` alone under a lock on the row in its project, so the side effects are
the web's and MCP's, once. Order: read-only token 403, then the read gate (missing, malformed,
foreign, out of reach, hidden: one 404, whatever the body), then `authorize :update?` (403, whatever
the body), and only then the input, so a refusal of it only ever answers a caller who may write. A
body Rails cannot read comes before the gate: a 400, the same for every ticket.
Input refused (mixed kinds, an unknown key, no `change`, the title rule, a list that is no list,
over 50, the same person in both lists, text that is no UTF-8): 422
`validation_failed`/`invalid_input`, a text from `services.ticket_change.*` that repeats nothing the
client sent. One difference to MCP is Rails', not the rule's: a JSON `null` in a list is gone before
the rule reads it, so `[id, null]` is `[id]` here and refused there; it names nobody either way.
Stopped by the project's state: 422 with `code: refused`, and `error` and `reason` the
same word (`value_not_allowed`, `user_not_assignable`, `no_status_field`, `validation_failed`), a
text from `services.ticket_change_failure.*` in `errors` and, for a title the model refuses, its
messages behind it. The code is named in the controller: `Api::V1::ErrorBody` alone would read
`validation_failed` as invalid input. Nobody is removed by a refused change, and a stale assignment
stays unless it is named. A ticket that moved or was deleted after the rights check answers the same
404. After the write commits, the response takes a fresh lock in that same project and reads
the whole summary under it, so a concurrent move cannot disclose destination data.
A failure the rule does not name answers 500 without its text. Guards:
`spec/requests/api/v1/ticket_changes_spec.rb`, `spec/requests/api/v1/ticket_changes_side_effects_spec.rb`
(the same trail as MCP), `spec/requests/api/v1/ticket_changes_concurrency_spec.rb`
(the response against a concurrent move), `spec/services/tickets/change_spec.rb`.

## Admin: Operator Features Enter Only Through Slots

**Binding** (guard spec: `spec/architecture/admin_operator_boundary_guard_spec.rb`; runs through
the `spec/architecture/` directory entry in the CI guard list):

The admin area is being split (`doc/oss_core_split_plan.md` 5.5 through 5.7). 17 controllers remain
in the core for instance administration. Seven become a private engine loaded only by an internal process:
`accounts`, `account_discounts`, `price_lists`, `billing_lists`, `founder_signups`,
`founder_signup_settings`, `acquisitions`. Their routes do not exist in the public process or
on any other instance.

* **No core code calls a route of these seven controllers.** An `admin_account_path` in a
  core view does not render a dead link there; it **raises**, and the page is gone. The guard reads
  route names and paths from the router, not a word list, and recognizes three forms: the
  named helper, the polymorphic array (`[:admin, account]`) and the literal path
  (`'/admin/accounts'`, also in `.js`). Grep sees only **names**: `[:admin, record]` with
  an account in `record` is caught only by the request spec with an empty registry.
* **No exception list.** There was one, with the two founder-email templates; it has been
  empty and deleted since 22 September 2026.
* ⚠️ **A link from the core to the console is a stored URL, never a route.** The
  founder email renders in the public process and points to a console page under
  another host (tunnel). The operator therefore stores a template with a
  placeholder (`SystemSetting.founder_signup_console_url`, `%{account_id}`), and the core inserts
  only the ID. Empty means no link. Insertion uses replacement, **not**
  `Kernel#format`: that raises on a second placeholder or a stray percent sign,
  inside a mailer job, for a value someone typed weeks earlier.
* A core page that should display an operator section names a **slot**:
  `<%= admin_extension_slot(:user_sections, user: @user) %>`. A loaded extension registers a partial
  (`Lalabase::AdminExtensions.register`). Without a registration, the slot renders nothing.
* The slot list is a **closed constant** (`Lalabase::AdminExtensions::SLOTS`). A
  mistyped name raises instead of silently rendering nothing on a page where “nothing” is a
  valid state. A new slot means adding to the constant.
* **Register only in `config.to_prepare`.** `lib/` is autoloaded; a code reload
  replaces the registry, and `to_prepare` runs again afterwards.
* A core-page controller loads nothing displayed only by the console. The partial fetches it
  itself (reference: `Admin::Operator::UserBillingAccounts`).
* `spec/requests/admin/without_operator_extensions_spec.rb` pins how
  the public process serves the admin area: pages with an empty
  registry (`Lalabase::AdminExtensions.with_empty_registry`).

## What lalabase.com Claims About This Code

Since W3, public pages live in `gboyke/lalabase-website` and can no longer read this
code. **Three** guards in `spec/architecture/` preserve the connection, all automatically in the
CI guard list through its directory entry:

| Guard | Pins |
|---|---|
| `website_quoted_facts_guard_spec.rb` | **Values** quoted literally by a page: Devise `confirm_within`, `UnconfirmedSignupPurgeJob::RETENTION`, `AcquisitionSource::RETENTION`, `FounderSignup::REVENUE_BANDS`, the `path_prefix` default. The website keeps its copy in `CoreFacts` |
| `website_feature_claims_guard_spec.rb` | **Mechanisms** behind feature-page promises: no stopwatch, no monetary amounts, seven switches, only GitHub and GitLab, chat does not write, … |
| `ai_provider_disclosure_guard_spec.rb` | **Which AI providers** the code can offer. The privacy policy in the other repository must formally name each of them; this is the half only this repository can answer |

* **Red never means only “code” here.** Either the change is wrong, or a sentence on a
  public page has just become untrue and must be rewritten there. The
  failure message names the file in the other repository.
* Every guard quotes the sentence it supports; the spec in the other repository names the example
  supporting it. Anyone changing a page can find the mechanism, and vice versa.
* ⚠️ **Do not delete these along with the pages in W6.** When the core removes its copies of the pages, the
  page specs go with them. These two remain: they are the only thing still tying a public
  promise to the code (`doc/oss_core_split_plan.md` § 11.4).

## Third-party licenses: every dependency is permissive

**Binding** (guard spec: `spec/architecture/third_party_license_guard_spec.rb`; runs through
the directory entry `spec/architecture/` in the CI guard list):

The core is AGPL-3.0-only and has one copyright holder. While every dependency is permissive, how this
project is licensed is that holder's decision alone. One dependency under GPL or AGPL alone
ends that, and a `bundle update` can bring one without anybody noticing.

| What | Rule |
|---|---|
| Gems (the installed bundle) | every declared license is on the allowlist: MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, 0BSD, Ruby |
| npm packages (`package-lock.json`) | the same rule, without exceptions |
| Third-party code checked into the repository | every file has a `Path:` line in `THIRD_PARTY_NOTICES.txt`, and its section states a license from the same list (plus OFL-1.1 for fonts) |

* **Every** declared license has to be allowed, not one of them. A gemspec does not say whether
  its list is a choice (`ttfunk`: Ruby terms or GPL) or a sum (`nio4r`: MIT plus BSD for the
  bundled libev). A real choice is an entry in `GEM_EXCEPTIONS`, with the license taken and
  the reason.
* `GEM_EXCEPTIONS` only shrinks (nine entries on 2026-09-30). An entry holds while the gemspec
  declares what the entry recorded: a gem that changes its declaration turns red and has to
  be read again. An entry for a gem that left the lockfile, or that would pass on its own, is
  red as well.
* **Every gem of the lockfile is read**, not only the installed ones. A bundle installed
  without a group turns red instead of checking less. The three build tools that are
  installed on no platform we run stand in `NOT_INSTALLED`, read by hand.
* Red after a `bundle update` means: read the license text of the new gem. GPL or AGPL alone:
  find another gem.
* **What counts as checked-in third-party code:** everything git tracks under `vendor/`,
  `public/fonts/` and `app/assets/stylesheets/bootstrap-icons/`, and anywhere else a file
  named `*.min.js`, `*.min.css` or like a font, and a script or stylesheet under `app/` or
  `lib/` that opens with a license header. The paid theme scripts lived in `app/javascript`
  until #814, outside every vendor directory.
* **A notice is not a permit.** A new vendored file needs its name, version, source,
  `License:` and copyright line in `THIRD_PARTY_NOTICES.txt`, and the guard reads the
  `License:` line: a GPL file with a tidy notice is still red. A directory `Path:` may not lie
  above another entry (`Path: vendor/` would cover everything to come).
* ⚠️ **Not covered**, because no lockfile and no file name shows it:
  * what a gem carries inside itself: the Rust crates compiled into `commonmarker`, native
    libraries (the macOS build of `nokogiri` ships LGPL `libiconv`, the Linux build does
    not), the JavaScript inside `lexxy`, `turbo-rails` and `stimulus-rails`, the gems
    `brakeman` vendors;
  * system libraries loaded into the process (`libvips`, LGPL, through `ruby-vips`);
  * programs the application calls as separate processes (ImageMagick; for PDF previews
    Poppler or MuPDF);
  * a release that changes its license text and keeps its gemspec: an exception is tied to
    the declaration, not to the version;
  * single icon paths copied into views (Heroicons, Lucide) and locale files generated by
    gems (`devise`).

---

## Development Checklists

### Multi-Tenancy
- [ ] `acts_as_tenant` set?
- [ ] Default scope correct?
- [ ] Seeds/factories tenant-aware?
- [ ] Queries correctly filtered by tenant?

### Security & Authorization
- [ ] Strong parameters correct?
- [ ] Pundit policies applied?
- [ ] Negative tests: unauthorized users receive 403?
- [ ] Positive tests: authorized users may perform the action?

### Performance
- [ ] N+1 queries avoided with `includes`/`joins`?
- [ ] Indexes for new complex queries?
- [ ] Caching strategy considered?

### i18n
- [ ] All new user-facing strings use `t()`?
- [ ] Keys added in German **AND** English in the appropriate area file (`config/locales/views/<area>.{de,en}.yml`)?
- [ ] **Changed** text updated in German **AND** English, even if only one language was discussed?
- [ ] No hardcoded German/English strings in views/controllers?
- [ ] JavaScript strings translated through ERB or `data-*` attributes?

### Code Quality
- [ ] Tests green: `rspec`
- [ ] Linters clean: `rubocop`, `erblint`
- [ ] Security clean: `brakeman`
- [ ] Policies checked/created

---

## Common Scripts & Tools

* **Style guide**: Available in development at `/style-guide`
* **Change public-page wording**: `/de?wording=1` enables the in-place editor in
  development (`?wording=0` disables it). Click text; German and English appear
  side by side; saving writes to the exact lines in `config/locales`. Only `static.*`, development
  only, no multiline values. Details: `lib/dev/wording_mode.rb`
* **Server operations (backup, log retention)**: `ops/backup/` — production scripts, systemd units and logrotate configurations, plus restore instructions in `ops/backup/README.md`. These files are **not** deployed automatically: update **both** repository and server when changing them. **Our actual connection details are not stored here** (Storage Box subaccounts, hosts, key paths): scripts read them at runtime from `/etc/lalabase-backup/backup.conf` (template: `ops/backup/backup.conf.example`) and fail loudly without them.

---

## Authentication for Development
- Create a local demo account for development.
- **Demo from seeds** (fresh development database): `anna@example.com` (admin), `ben@example.com` (standard role), `clara@example.com` (project manager), `david@example.com` (viewer), `/admin` with `admin@example.com`, password for each: `lalabase-demo`

---

## Internationalization (i18n)

### Basic Rule
**NEVER** hardcode user-facing strings in views, controllers, models or mailers. **ALWAYS** use `t()`.

### Locale Structure
* **Files**: View strings live per area in `config/locales/views/<area>.{de,en}.yml`
  (`tickets`, `ansichten`, `zeiterfassung`, `meetings`, `inbox`, `wissen`, `dokumente`, `hilfe`, `organisation`,
  `personen`, `glossar`);
  the rest (common/shared/layouts/devise/admin/components) in `views.{de,en}.yml`. Rails loads
  subdirectories automatically. The guard (`spec/locales/no_duplicate_keys_guard_spec.rb`)
  rejects cross-file duplicates with different values — every key has exactly ONE owner.
* **Key convention**: `views.organisations.<controller>.<action>.<key>` for views
* **Shared keys**: `views.organisations.<controller>.shared.<key>` for strings shared across partials
* **Flash messages**: `controllers.<controller>.<action>.<key>`
* **Models/validations**: `activerecord.errors.models.<model>.<key>`
* **Numbers/amounts**: `rails-i18n` is **not** included — formats are maintained manually
  under `number.*` in **both** `de.yml` and `en.yml`. Without the German branch,
  `number_to_currency` and similar helpers silently fall back to English Rails defaults, and the German
  interface displays “€14.50” instead of “14,50 €”. Never format prices manually; use
  `PriceHelper#format_price_cents` (guard: `spec/helpers/price_helper_spec.rb` pins both
  locales).
* **Enumerations**: For the same reason, `support.array` is maintained manually in `de.yml`
  **and** `en.yml`. Without the German branch, `to_sentence` joins items on German pages with
  “, and” (`Status, Priorität, and Titel` in the German UI), including every flash message that
  concatenates validation errors (guard: `spec/helpers/timeline_helper_spec.rb`).
* **Dates** (guard: `spec/architecture/locale_date_format_guard_spec.rb`): a date on a page
  goes through `l()` with a named format from `date.formats` / `time.formats`, never through
  `strftime` with a format of its own. strftime writes English month names on the German
  page, and a typed `%d.%m.%Y` is German on the English one. A literal format stays only
  where it reads the same in both languages (ISO dates, the clock, month or day names alone
  through `l()`). The legacy list (51 formats in 29 files on 2026-10-18) only shrinks.

### A Request's Language (Since 20 August 2026, Core Version Since D5)

Public pages have lived in `gboyke/lalabase-website` since W6, and documentation in
`gboyke/lalabase-documentation` since D5. What remains here is the question of which language
the core uses in its response.

* **It is decided in `ApplicationController#switch_locale`**, an `around_action`
  before `authenticate_user!` (Devise translates its sign-in messages into the language in
  effect at that moment). Precedence: valid `?locale=`, signed-in user's profile language,
  remembered language of this session (`session[:public_locale]`), `Accept-Language`, German.
  In demo mode (`LALABASE_DEMO=1`), `Lalabase::Demo::LOCALE` always takes precedence: the demo world is
  written in that language, and the shared account must not retain a choice
  (guard: `spec/requests/demo_mode_spec.rb`).
  A valid `?locale=` is remembered. Registration copies the form's language
  into the profile. Guard: `spec/requests/locale_per_request_spec.rb`.
  ⚠️ **There used to be one higher precedence level: the language in the PATH.** `/docs/:locale/…`
  were the last routes carrying it, and they disappeared with D5 (public
  pages took theirs with them in W6). No route can set `request.path_parameters[:locale]`
  anymore, so this level was deleted instead of retained without checks. Anyone building a
  route with a language in the path must restore it: read it first, and remember it like `?locale=`.
* ⚠️ `I18n.locale` is thread state and **outlives the request**. `switch_locale` sets it
  through `I18n.with_locale` and restores it afterwards; an action may change it inside that context
  (the language setting). Outside this context, for example in a controller that does not
  inherit from `ApplicationController`, it remains for the next request on the same
  Puma thread. This is exactly how registration and login received the previous request's
  language until 10 September 2026.
* The language comes from `request.query_parameters['locale']`, **not** `params`:
  `params` forces request-body parsing, and this callback runs on every
  controller, including mail webhooks with their external payloads.
* **I18n** determines which languages exist, no longer a table belonging to the public
  pages (`supported_locale`). Missing English text does not fail loudly:
  `config/initializers/i18n.rb` sets `fallbacks = [:de]`.

### Legal Information Belongs to the Operator, Not Us

The core hosts no legal pages and names our company nowhere. The operator's name and the
URLs of the legal notice, privacy policy and terms are stored in system settings
(`LegalIdentity`, four `SystemSetting` rows, one query per request through `Current`).

* Render **exclusively** through `legal_operator_credit`, `legal_page_link` and
  `legal_footer_links`. Without an operator name, the translated text
  `powered by Lalabase` appears; without a URL, no link appears.
* **Operators without their own website** enter text in the admin area; the instance serves
  it under `/legal/<page>` (`LegalPagesController`, Markdown, sanitized). An
  entered **URL takes precedence** over text.
* ⚠️ No core code reads the public website: no `StaticHelper` constant, no
  public legal route, no `static.*` text. Guard:
  `spec/architecture/app_legal_identity_guard_spec.rb`, **without an exception list**.
* Two further guards pin what lalabase.com claims about this code — see
  the dedicated section.

### The Core Does Not Advertise Our Cloud

**Binding** (guard spec: `spec/architecture/app_operator_claims_guard_spec.rb`; runs through
the `spec/architecture/` directory entry in the CI guard list):

Visitors to pages before sign-in do not know whose instance they are on. Anything stated
there must be something the **operator** can say, not just us. Until 20 September 2026, every
sign-in page said “Hosting in Germany | DPA included”, the panel's window bar showed
`lalabase.app/inbox`, and registration offered our founder discount.

The guard checks the I18n areas of the seven pages before sign-in against five patterns
(examples retain the German words matched by the guard):

| Pattern | Example |
|---|---|
| Our domain | `lalabase.app`, `lalabase.com` |
| Hosting location | `Deutschland` (“Germany”), `Germany`, `hosted` |
| Contract with us | `AVV`, `DPA` (data processing agreement), `Auftragsverarbeitung` (“data processing”) |
| Price or discount | “50 %”, “14,50 €” |
| Payment terms | `Rechnung` (“invoice”), `kündbar` (“cancelable”), `Abo` (“subscription”) |

Also the markup itself: no `lalabase.*` in `app/views/devise/**` or the auth layout.
The instance name comes from `request.host`.

* ⚠️ **`app_legal_identity_guard_spec.rb` does NOT cover this.** It looks for `StaticHelper::`,
  public legal routes and `t('static.`. These texts lived under `views.devise.*` because
  their keys had been copied specifically from the pricing page so they would no longer be named
  `static.*`. The promise moved with them. Two guards, two questions: one keeps the core
  separate from the **website**, this one from our **business**.
* **No exception list.** There was one, with one entry, and the founder discount left the
  registration form on 20 September 2026. An empty list invites the first new entry.
* ⚠️ **Markup is read with ERB tags stripped out**
  (`AppOperatorClaimsGuard.literal_text`). Otherwise, `<%= index + 1 %>` reads as “1 %” and
  triggers the price pattern, and every comment explaining a removed promise triggers
  that promise's own pattern.
* An auth page's eyebrow text names a **state** (“Account locked”, “Confirmation missing”),
  never a promise.

### For Every New Feature / Change
0. **Change existing text** → ALWAYS both languages. A wording change to
   German text without the English version is unfinished and goes unnoticed:
   the key exists, the page renders, only the sentence is stale. This applies even when
   only the German page was discussed (user instruction, 21 August 2026).
1. **New strings** → write as a `t()` call immediately, add the key in German + English locales
2. **Change existing views** → check for remaining hardcoded strings and extract them at the same time if present
3. **JavaScript strings** → through ERB interpolation (`<%= t("...") %>`) in `.js.erb` or via `data-*` attributes
4. **Confirmation dialogs** → keys under `views.confirm.<key>` in both locales

### Example
```erb
<%# ✅ Correct %>
<h1><%= t('views.organisations.tickets.index.title') %></h1>
<%= link_to t('views.organisations.tickets.shared.back'), tickets_path %>

<%# ❌ Incorrect — hardcoded string %>
<h1>Tasks</h1>
<%= link_to "Back", tickets_path %>
```

---

## Constants & Magic Numbers

* No “magic numbers/strings” in code — move them into **constants** (`ALL_CAPS`) or I18n
* Group constants in topical namespaces: `Notifications::Constants::EVENT_TYPE_MAPPING`
* Make them immutable (`.freeze` for arrays/hashes)
* Thread-safe access in background jobs: `Notifications::Constants::EVENT_TYPE_MAPPING`

---

## Code Review Checklist

- [ ] Tests green & complete (system, request, unit tests)
- [ ] Regression test added for bug fixes
- [ ] Policies checked/created & tests present
- [ ] Linters & security scanners clean
- [ ] Multi-tenancy correctly implemented
- [ ] Background jobs use thread-safe constant access
- [ ] ViewComponents follow the Neo Brutalist design system
- [ ] **i18n**: All strings through `t()`, keys present in German + English

