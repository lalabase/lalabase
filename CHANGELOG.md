# Changelog

What changes from release to release, for the people who run Lalabase. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

**Versions are dates:** `YEAR.MONTH.PATCH`, the month without a leading zero
(`2026.11.0`, `2027.1.0`). A release usually comes once a month; a second one in the
same month, typically a security fix, counts up the last number (`2026.11.1`).

**`main` is what our hosted service runs. To run your own instance, install a release**
(a tag), not `main`.

Every release has **Upgrade notes**: what you have to do when you update (a new
environment variable, a task that runs once, a new system dependency). Read them before
you update. Migrations and the data backfills run by themselves when the container
starts (`db:prepare lalabase:data_backfills`). Without Docker, run
`bin/rails db:migrate lalabase:data_backfills` after each update.

## [Unreleased]

### Added

- A Docker image for each release, `ghcr.io/lalabase/lalabase:<version>`, for linux/amd64
  and linux/arm64. It boots and passes the install check before it is pushed, and carries a
  signed record of where it was built (`gh attestation verify oci://ghcr.io/lalabase/lalabase:<version> --owner lalabase`).
  `compose.yml` of a release pulls the image of that release instead of building it, and
  `compose.build.yml` still builds the image from the checkout (#48).
- The MCP tools `list_organisations` and `list_projects`: an agent now finds the ids the other
  tools ask for itself, instead of taking them from the address bar. `GET /api/v1/organisations`
  and `GET /api/v1/projects` read through the same code and answer as before.

### Fixed

- Building the image yourself no longer fails on the first `up --build` with Docker 29:
  only the web service builds, and the worker runs the image it built (#48).

### Security

- The rate limit of `/api/v1` and `/api/mcp` no longer writes access tokens in plain text
  into the cache. It counts per digest of the token. With the default file cache, tokens
  that were in use stood in file names under `tmp/cache` (#92).

### Upgrade notes

- `compose.yml` no longer builds the image: it pulls `ghcr.io/lalabase/lalabase` in the
  version of the release you checked out. Update with `git checkout <release>`, then
  `docker compose pull && docker compose up -d`. To keep building the image on your
  server, add `COMPOSE_FILE=compose.yml:compose.build.yml` to `.env`.
- Leave `LALABASE_VERSION` out of `.env`. Set, it pins the image, and a release checked out
  later keeps running the pinned version.
- Unless you keep building the image, the image `lalabase:local` that earlier releases built
  is no longer used: `docker image rm lalabase:local` removes it.
- After updating, empty the contents of `tmp/cache` once. If that directory is part of a
  backup, or someone you do not trust could read it, replace your access tokens (#92).

## [2026.10.1] - 2026-10-21

<!-- drafted from d03168b613c25580924a59815580a512c0b95666 -->

### Added

- "Alle Meetings" works like the meetings page of a project: the shared filter bar with saved
  views and search, a filter by project, the column picker, and the detail lane on the right
  for opening a meeting or creating a new one with a project select (#5, #7, #8, #11).
- `bin/rails rich_text_embeds:resign_sgids` brings back the images and note mentions of rich
  texts after a new `SECRET_KEY_BASE` (run it with `DRY_RUN=1` first). It needs no old key.
  See "Moving to a new server or cloning a server" in the self-hosting docs (#23, #24, #25).
- A demo mode for a public demo instance, behind `LALABASE_DEMO=1`: a shared, published
  login, an invented example company, a reset every night, limits on uploads and AI requests.
  The nightly reset deletes all data of the instance. Do not set `LALABASE_DEMO` on a normal
  instance; without it nothing changes (#18, #21, #26, #28, #30, #33).

### Changed

- The API list of a ticket's files (`GET /api/v1/tickets/:id/attachments`) loads them in one
  query. The files of comments now come in the order of the comments' ids (#1).

### Fixed

- Images in rich texts are kept when an instance gets a new `SECRET_KEY_BASE`, for example
  after moving to a new server or cloning one. Until now, editing such a text afterwards
  detached its images and deleted the files (#23).
- Escape closes only the topmost menu or dialog. Before, a filter menu or the "+" dialog
  could also close the detail lane behind it, together with an unsaved edit (#9).
- The "+" on a project's meetings page opens the new-meeting form as its own state: the
  previously open meeting is no longer marked, and a reload shows the form again (#16).
- The dates in the knowledge list follow the language of the interface (#10).

### Security

- IDs taken from a request are now always checked against the organisation: the Kanban
  attribute of a view, the user mapping of the codebase user import, the recipient of a
  private comment through the API, and the users in smart folder rules (#3).
- A custom OpenAI-compatible AI endpoint is checked by the addresses its name resolves to,
  on saving and again on every request, and only public addresses are accepted. The
  connection test no longer shows raw network errors (#20, #22).
- Cloning a connected repository writes symbolic links as plain files, so documentation
  sync and code indexing cannot read files outside the repository (#19).
- The client address behind a reverse proxy comes from `X-Forwarded-For` only. A
  `Forwarded` header sent by a client is ignored, so it can no longer change the address
  that the sign-in and other request limits count (#27).

### Upgrade notes

- If the `SECRET_KEY_BASE` of your instance was ever changed (moved to a new server, cloned
  from another one), run `bin/rails rich_text_embeds:resign_sgids` once, first with
  `DRY_RUN=1` (in Docker: `docker compose exec web bin/rails rich_text_embeds:resign_sgids`).
  It reattaches images and note mentions that show as missing.
- Behind a reverse proxy, the client address now comes from `X-Forwarded-For` only. Caddy
  (as in `compose.yml`) and nginx set it. A proxy that sends only a `Forwarded` header makes
  every visitor count as the proxy, so all of them share one request limit: configure it to
  set `X-Forwarded-For`.

## [2026.10.0] - 2026-10-12

<!-- drafted from 4622099a2ca151fbe8fa3995108ca320a2d3cbee -->

### Added

- First public release. Lalabase has been developed since October 2024 (more than 2,300 commits,
  about 970 pull requests) and has run in production for customers since September 2025. The earlier
  history stays private: it holds customer data and details of our servers.

### Upgrade notes

- None.
