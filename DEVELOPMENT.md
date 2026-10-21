# Developing Lalabase

Everything for working on the code: stack, setup, releases and where things live. To run an
instance, start with the [README](README.md#two-ways-to-run-it) instead.

## Stack

| | |
|---|---|
| Ruby / Rails | see `.ruby-version` / Rails 8.1 |
| Database | PostgreSQL with **pgvector** (extension `vector`; the schema creates HNSW indexes) |
| Frontend | Hotwire (Turbo + Stimulus), ViewComponent, Tailwind |
| Jobs | **Solid Queue**, the only job backend |
| Cache | Redis-compatible (the Docker setup starts Valkey), optional in development |
| Multi-tenancy | `acts_as_tenant`, root entity `Organisation` |

## Setup

```bash
bin/setup                           # dependencies, create the DB, load the schema, seeds (incl. demo)
npm install && npm run copy:fonts   # Bootstrap Icons into public/fonts (once)
```

### Running it in development: two processes

`Procfile.dev` has **no web server** (only the CSS watcher and Solid Queue), so start the
server separately:

```bash
bin/dev                      # terminal 1: Tailwind watcher + Solid Queue
bin/rails server -b 0.0.0.0  # terminal 2: the application
```

Signing in during development: a freshly created development database contains a small demo
(`db/seeds/demo.rb`): `anna@example.com` (admin), `ben@example.com` (standard role),
`clara@example.com` (project manager) and `david@example.com` (viewer), and `/admin` with
`admin@example.com`, each with the password `lalabase-demo`. On an existing database,
`bin/rails db:seed` creates them, and `bin/rails db:reset` rebuilds everything.

A fresh instance gets its first admin with `bin/rails lalabase:setup`.

### Your own keys for every installation

The repository ships no encrypted Rails credentials. In development and test, Rails creates
its own key in `tmp/local_secret.txt` on first start, and the local data encryption keys are
derived from it. Keep that file for later starts. This is also why `.env.example` has no active
`SECRET_KEY_BASE` example value.

For a **new** production installation without Docker, copy `.env.production.example` to `.env`,
fill in the database and the mail provider, and generate your own keys:

```bash
bin/rails secret               # put the output into .env as SECRET_KEY_BASE
bin/rails db:encryption:init   # copy the three values into ACTIVE_RECORD_ENCRYPTION_*
bin/rails db:prepare
bin/rails lalabase:setup
```

With these environment variables, neither a credentials file nor a `RAILS_MASTER_KEY` is
needed. If you use Rails credentials instead, create them yourself with
`bin/rails credentials:edit --environment production` and put the matching key on the server.
If `secret_key_base` lives in the credentials, remove or comment out the `SECRET_KEY_BASE` line
in `.env`: even an empty environment value overrides the credentials. The three data encryption
keys must still be set, in the credentials or in the environment. Credentials files and keys
stay outside this public repository.

**Existing installations:** keep your existing credentials, master keys, `SECRET_KEY_BASE` and
data encryption keys, and back them up separately from the source code. Existing credentials
must still be provided through your deployment configuration after updates. New keys do not
migrate existing encrypted data.

### Running it with Docker

The Docker steps are in the [README](README.md#self-host-with-docker). They install a release;
for development, use the two processes described here.

### User documentation

The handbook and the self-hosting guide live at [lalabase.com/docs](https://lalabase.com/docs),
in German and English, and are not part of this repository. The in-app help (`/hilfe`) links to
them. `DOCS_CATALOGUE_PATH` can point the help at a local catalogue file instead; its format is
not public yet.

## Releases

**Versions are dates:** `YEAR.MONTH.PATCH`, the month without a leading zero (`2026.11.0`,
`2027.1.0`). A release usually comes once a month; a second one in the same month, typically a
security fix, counts up the last number.

**`main` is what our hosted service runs. To run your own instance, install a release** (a tag,
see the Docker steps in the README), not `main`. Before an update, read the release's
**Upgrade notes** in [CHANGELOG.md](CHANGELOG.md): what you have to do (a new environment
variable, a changed `compose.yml`). Migrations and the data backfills run by themselves when the
container starts; without Docker, run `bin/rails db:migrate lalabase:data_backfills` after each
update.

For maintainers, `script/release` cuts one:

```bash
script/release draft               # next version and draft notes from the merged pull requests
script/release prepare [VERSION]   # writes the draft into CHANGELOG.md: edit, pull request, merge
script/release publish VERSION     # on an up-to-date main: tag, push the tag, GitHub release
```

`publish` refuses while a pull request merged after the draft is not named in the notes as
`(#N)`, or while a commit on `main` came without a pull request. Add the line by a pull request
on `CHANGELOG.md`, or, after reading what it names, pass `--anyway`.

The rules (version scheme, sections, where a draft goes) are in `lib/lalabase/release.rb`;
`spec/architecture/changelog_guard_spec.rb` keeps the file in the shape the script reads.

## Everyday commands

```bash
bundle exec rspec                      # tests (a single one: rspec path/to_spec.rb:42)
npm test                               # JS tests (Node, no browser needed)
bundle exec rubocop                    # Ruby linter, against the frozen .rubocop_todo.yml baseline
bundle exec erblint --lint-all         # ERB linter
bundle exec brakeman                   # security scanner
bin/rails tailwindcss:build            # build the CSS once (needed in a fresh worktree)
```

**CI** does not run the full suite. `.github/workflows/guards.yml` runs six jobs on pull
requests: a curated list of guard specs, the JavaScript tests, the Python tests of `bin/lala`,
RuboCop, Brakeman and a dependency audit. `.github/workflows/leaks.yml` checks every pull
request and every push to `main` for secrets. A red run means a convention was actually
broken, not legacy drift.

## Finding your way: what lives where

### Core entities

`Organisation` is the tenant root; everything hangs off it. `Account` sits *above* it and groups
organisations for billing. Below it: `Project` → `Ticket` → `Post` / `TimeSession`, plus
`Document`, `Note`, `Meeting` and `Chat`.

### Feature areas → code

Controllers live under `app/controllers/organisations/`; the views mirror that structure.

| Area | Controllers (selection) | Central models |
|---|---|---|
| Tasks | `tickets`, `ticket_attribute_definitions`, `smart_folders` | `Ticket`, `TicketAttributeDefinition` |
| Time & billing | `time_sessions`, `time_session_groups` | `TimeSession`, `TimeSessionGroup` |
| Knowledge & files | `knowledge`, `notes`, `documents` | `Note`, `Document`, `Fragment` |
| AI assistant | `chats`, `chatposts`, `ai_settings`, `prompt_personas` | `Chat`, `Chatpost`, `ContentEmbedding` |
| Meetings | `meetings`, `meeting_analyses`, `meeting_ticket_suggestions` | `Meeting`, `MeetingAnalysis` |
| Notifications | `notifications`, `notification_subscriptions`, `mentions` | `Notification`, `OutboxEvent`, `Activity` |
| Organisation & permissions | `memberships`, `roles`, `project_permissions`, `access_matrix` | `Membership`, `Role` |
| Documentation | `documentation`, `documentation_sets` | `DocumentationPage`, `DocumentationSet` |

### Places that are not obvious

* **Writes** go through command objects in `app/services/actors/`, not through the controller.
  Contract and tier rules: `CLAUDE.md`, section "Actor-Pattern".
* **Every write triggers a side-effect chain** (Activity → Outbox → Fanout) that is invisible
  where it is called. Start at `app/models/concerns/trackable.rb`, then `app/models/activity.rb`,
  `app/models/outbox_event.rb` and `app/services/notifications/fanout_service.rb`.
* **Ticket status and priority are not columns** but JSONB values configured per project
  (`app/models/ticket_attribute_definition.rb`). A hard-coded status string is the most common
  mistake there.
* **List pages** (tickets, notes, documents) inherit behaviour from the `ObjectListController`
  stack, which brings its own `index`/`show` and five `before_action`s →
  `app/controllers/concerns/CLAUDE.md`.
* **Paths under `doc/` or `docs/`** in code comments point to an internal archive of plans and
  work logs that is not public.

## Conventions

Binding rules are in `CLAUDE.md`; `AGENTS.md` is a shorter summary. The four that are
overlooked most often:

1. **No `<style>` blocks in views**: CSS belongs in `app/assets/stylesheets/`.
2. **No rails-ujs options**: use `data: { turbo_method: … }` instead of `method:`, otherwise it
   is silently dead code (rails-ujs is not loaded).
3. **i18n without exception**: every user-facing text goes through `t()`, with keys in **German
   and English**.
4. **Multi-tenancy**: new models need `acts_as_tenant`; `without_tenant` is reserved for the
   admin area only.

Several of these rules are enforced automatically by guard specs (`spec/**/*guard*`).
