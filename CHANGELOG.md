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

- A glossary for each organisation: terms in their right spelling and the forms in which
  speech recognition heard them wrong, on a page of its own reached from the meetings pages.
  Two new role rights decide who may see and who may keep it, see the upgrade notes
  (#113), (#114), (#140), (#145).
- A misheard word in a meeting's transcript is corrected in place, only there or everywhere
  in the meeting, and the correction is learnt for the glossary with its speaker and project.
  Without the right to keep the glossary it is a proposal there, which works nowhere until
  someone with the right confirms it (#121). A meeting shows what a recording device replaced from the glossary (#127).
- The glossary takes a pasted list of terms, checked line by line before the import (#128),
  and suggests terms from tickets, public comments, notes and documents that the person who
  starts it may read, with the organisation's AI model and a review list where a person accepts, merges or dismisses each one (#129), (#130).
- Sub-tasks can have sub-tasks, to any depth. The ticket head shows the trail of its parents
  (#97). A sub-task added in the ticket shows in the ticket list beside it at once (#100).
- An organisation chooses an inbox project for meetings. Programs create meetings over
  `POST /api/v1/organisations/:organisation_id/meetings` and the MCP tool `create_meeting`;
  without a project they land in the inbox. API version 1.9.0, MCP 0.16.0 (#105), (#106).
- A program that creates a meeting can send what it replaced from the glossary before
  sending (`meeting[glossary_replacements]`: heard form, term, count, at most 500 rows). A
  list that does not fit is refused as a whole as `invalid_input`. `GET /api/v1/meetings/:id`
  gives the list back. Capability `meetings.glossary_replacements`, API version 1.12.0 (#127).
- The MCP tool `get_meeting` reads one meeting whole: its head with the participants, and the
  summary, notes and transcript in pages (`part`, `offset`). MCP 0.17.0 (#112).
- An inbox above all organisations at `/inbox`: the notifications of every organisation a
  person belongs to in one list, with unread counts per organisation, actions on a row and on
  several rows at once, kept current while open. Tickets, notes, project events and documents
  open in its lane (#166), (#167), (#168), (#169), (#173), (#174), (#175).
- The inbox of an organisation has actions named in words on every row, a search while
  typing, a "Read" view, a period filter and its views as tabs (#135), (#136), (#138), (#139).
- The REST API reads meetings: `GET /api/v1/projects/:project_id/meetings` with search and
  pages, and `GET /api/v1/meetings/:id` with participants, summary, notes and transcript.
  API version 1.10.0 (#111).
- The REST API and the MCP server read the glossary of an organisation:
  `GET /api/v1/organisations/:organisation_id/terms` and the tool `get_glossary` give its
  confirmed terms with the heard forms speech recognition wrote instead, how often and by
  whom, in pages. A token limited to some projects gets every term, but the heard forms of
  its projects only; speakers are named only with the right to the people directory.
  API version 1.11.0, MCP 0.18.0 (#124).
- `TRADEMARKS.md` says what forks and hosts may do with the name and the logo: talk about
  Lalabase, run it and build on it, but not call their own version or service Lalabase or
  make it look official. The AGPL covers the code, not the name (#102).

### Changed

- The inbox has the list-and-lane design of the other list pages (#132), (#133).
- A click on a ticket description no longer opens its editor and the text no longer reacts to
  hover; edit it with the pencil (#104).
- The inbox of an organisation opens on "All" (unread and read) instead of "Unread" (#136).
- A saved ticket keeps its parent. `PATCH /api/v1/tickets/:id` used to drop `parent_id` and
  answer 200; another parent or an empty value is now a 422 `validation_failed`, the current
  parent is no change. A web `PATCH` with `ticket[parent_id]` is refused as well. A script
  that brings over a tree creates the parents before the children (#97).
- The list pages share one look: the bar of the ticket list with views as tabs and the search
  on the right on the inbox, people and glossary, one view switch in the page head, one column
  head, the main action outermost in every head (#137), (#139), (#141), (#142), (#143),
  (#145), (#146), (#165).
- The management area has its own navigation in the sidebar, a section head with a crumb on
  each page, and the AI section a tab row (#147), (#148), (#149), (#150), (#151), (#153),
  (#154), (#156), (#160).
- The level above the organisations and the account pages have sidebars of their own, and
  the header with the organisation switcher shows on every level. For people in several
  organisations the logo leads to the organisation select page (#155), (#163), (#177),
  (#178), (#179).
- The account page has three tabs: personal data, password, delete account. The picture
  and the shown email moved to the profile. The preferences are one page with an outline
  that saves every change at once (#152), (#158), (#159), (#161), (#162).
- The sign-in, sign-up and password pages have the design of the public website (#122).
- The news entry is out of the account menus while no news are written (#157).
- The organisation a session returns to follows the pages a person opens, not every request
  in the background (#172).
- Hard shadows are kept to the main action and the clickable card (#131).
- The demo world (`LALABASE_DEMO=1`) holds two contacts, a glossary, a chain of sub-tasks, a
  meeting linked to its ticket and a second organisation, the client's, where the published
  login is a member and has two tickets. The demo login now lands in two organisations (#185).
- Synced documentation pages show their images from your instance. The sync copies them
  out of the repository, and they are served behind the right to read the documentation,
  so a reader no longer contacts the repository host and images from private repositories
  show. An image that cannot be served shows as its alt text, one with a full address
  becomes a link. SVG is not shown yet. Limits: 5 MB per image, 200 images per set (#107).
- The assistant's time report over a whole organisation reads the rights once and sums in
  one query, instead of three queries and a sum for every project (#120).
- The REST API refuses a `page` or `per_page` it cannot read with the same wording on every
  list that refuses one (people, knowledge, meetings and the glossary), in the language of
  the token's owner and naming the refused value. Before, people, knowledge and meetings
  answered in English only, in two different wordings. Status codes and error codes stay as
  they were (#125).

### Fixed

- The meeting and note edit forms ask before they delete (#170).
- Cancelling or deleting in the note editor of the inbox keeps the editor's frame (#176).
- A note mention in a rich text draws its chip again (#182).
- A file opened without a login leads to the login page (#103).
- A project event reaches everyone who may read it, and a run that created notifications and
  failed halfway is rolled back and retried in full instead of leaving people out (#99).
- Expired cache entries are swept every hour, and the file cache has its own directory (#115).
- A person in two or more organisations who opens the bare domain, leaves the account area
  without a way back, or is refused an action in the demo lands in the organisation they
  joined first. It used to be whichever had the smaller random id (#185).
- Input that answered a 500 on `/api/v1` and MCP is answered now. The ticket list takes the
  search together with a tag filter, and ignores a date bound with a year PostgreSQL cannot
  store, like any other unusable one. A page no list has, or a page sent as a list, is a 400
  on the ticket list and both time session lists, and invalid input in `list_tickets`. A
  `time_session` that is no object is a 400 (#118).
- The provisioning endpoint answers a body that is no JSON in its error envelope (#118).

### Security

- The search of the ticket list in `/api/v1` and in the MCP tool `list_tickets` (`q`) no
  longer matches the text of comments. It matched every comment, private ones the reader may
  not read included, so a hit told the searcher what a private comment said. It now searches
  title and description, as `list_tickets` describes it. The search on the web pages was not
  affected (#117).
- `/api/mcp` refuses a JSON-RPC batch (an array of calls) before any call in it runs. Each
  call was carried out, and the per-token rate limit counted the request once (#118).
- `create_ticket` and `create_meeting` over MCP answer an unexpected failure with a fixed
  text instead of the exception message, as the other write tools do. `search_code_symbols`
  no longer passes on the message of a credential or embedding error, which named internal
  ids (#118).
- The code tools of the assistant (`search_code_symbols`, `get_symbol_details`) neutralise
  code fences in the name and path of a symbol, which come from the repository (#118).
- `PATCH /api/v1/tickets/:id` writes and answers under a lock on the ticket in the project
  it was authorized in. A ticket moved to another project in between used to be written
  there, where the caller may not write, and its answer could show data of that project.
  It is a 404 now, as if never found. A concurrent change to another attribute is no
  longer written back with its old value (#119).
- Password reset, confirmation resend, unlock and sign-in no longer tell whether an
  address has an account (Devise's paranoid mode). The three forms said "not found" for an
  unknown address, and sign-in said an account was locked even after a wrong password. A
  locked person now reads "Invalid email or password" like everybody else and learns of the
  lock from the unlock mail; the warning before the last attempt is gone for the same
  reason. The sign-up form still says when an address is taken (#180).
- The unlock form has a rate limit of its own, 3 requests per minute and IP address, like the
  password reset and the confirmation resend. It mails an arbitrary address on request (#180).
- The sign-up closes for a day to a client address that was told five times in a day that an
  email address already has an account (429, at the form and at the provisioning endpoint,
  there per visitor). The form still gives that answer, because a new account is signed in at
  once and a taken address cannot be; with a password too short on purpose it gave it 20
  times an hour without writing anything. An instance that wants the answer gone closes
  registration: then no address is looked at (#181).
- Updated dependencies: rack 3.2.8 (#98), addressable 2.9.2 (#109), Rails 8.1.4.1 with
  nokogiri 1.19.7, loofah 2.25.3 and rails-html-sanitizer 1.7.2 (#116), together closing more
  than 40 published advisories.
- View output that was marked as safe HTML by hand now goes through Rails' own escaping or
  through `sanitize`: translations with markup, the rendered changelog entries, the style
  guide and the preview of the email log. No known hole is closed by it; it is a second line
  behind the inputs (#171).

### Upgrade notes

- Run `bin/rails documentation:resync_all` once after updating. Until then a page keeps
  its old image addresses, unless its repository receives a new commit (#107).
- No existing role gets the new rights `view_glossary` and `manage_glossary`. Account admins
  need neither; for everyone else, grant them in the roles of the organisation. Glossary
  suggestions need an AI model configured for the organisation.
- The Rails cache moves to `tmp/cache/store`, and an hourly job deletes its expired entries
  (#115). With Docker, `compose.yml` has a new volume `cache`, mounted in `web` and `worker`:
  if you changed your `compose.yml`, compare it with this one first. Without the shared
  volume the worker never sweeps what the web container wrote. The cache starts empty once,
  so rate limit counters start from zero.
- Without Docker, the old cache entries stay in `tmp/cache/` in directories named by three
  hex digits and are read by nobody. Remove them once, in your shared `tmp/cache`:
  The directory is the `tmp/cache` your app server uses (with Capistrano `shared/tmp/cache`,
  which `current/tmp/cache` links to; `-H` follows that link):
  `find -H tmp/cache -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9A-F]{3}' -exec rm -rf {} +`
  (GNU `find`; with BSD `find` on macOS write `find -E -H tmp/cache ... -regex '.*/[0-9A-F]{3}'`
  without `-regextype`).
- If you build the image yourself (`compose.build.yml`), rebuild it: the Dockerfile changed
  and creates the new cache directory (#115).
- API clients: `PATCH /api/v1/tickets/:id` with another or an empty `parent_id` now answers
  422 `validation_failed` instead of 200 and an unchanged parent (#97).
- No new required environment variables.

## [2026.11.0] - 2026-10-31

<!-- drafted from d31c38282b6a52e09e33ebbe4195546d11421234 -->

### Added

- A Docker image for each release, `ghcr.io/lalabase/lalabase:<version>`, for linux/amd64
  and linux/arm64. It boots and passes the install check before it is pushed, and carries a
  signed record of where it was built (`gh attestation verify oci://ghcr.io/lalabase/lalabase:<version> --owner lalabase`).
  `compose.yml` of a release pulls the image of that release instead of building it, and
  `compose.build.yml` still builds the image from the checkout (#48).
- A people directory for each organisation: members appear on their own, contacts without a
  login are added by hand, with a salutation and up to ten labelled details (a second phone, a
  website, an address). A person shows their last contact and their meetings, and a meeting
  participant can point to a person. Two new role rights decide who may see and who may keep the
  list, see the upgrade notes (#50), (#51), (#54), (#59), (#61), (#64), (#65), (#70), (#74).
- The assistant looks people up in the directory, and the directory can be read over MCP and
  `/api/v1`, by the same rights (#73), (#77).
- A member chooses which email the others see: the login address (the default, as before), a
  separate contact address, or none, under **Profile** (#82), (#88).
- A meeting can move to another project, with its booked time, under the new role right
  `move_meetings` (#45).
- A meeting linked to a ticket opens beside the ticket in a read-only panel that fits the
  width of the page, and the assistant is offered both (#40), (#42), (#43).
- Search hits show their date, and their labels are translated (#66).
- MCP server 0.15 with 19 tools, five more than 2026.10.1. `list_organisations` and
  `list_projects`: an agent now finds the ids the other tools ask for itself, instead of taking
  them from the address bar. `summarize_time_sessions`, and `find_people` and `get_person` for
  the directory. `get_ticket` lists the files of a comment (#71), (#77), (#89), (#90), (#93), (#94), (#95).
- `/api/v1` is now fit for programs (API 1.8.0, the Lalabase CLI uses it): an error `code` next
  to `error`, an `Idempotency-Key` on every write, `api_version` and `capabilities` in
  `GET /api/v1/me`, the ticket view with pages and by number, time booking, plain text comments,
  a project's knowledge, `POST /api/v1/tickets/:id/changes`, and the files of a comment
  (#72), (#76), (#78), (#81), (#83), (#85), (#87), (#89).

### Changed

- The page with name, login address and password is now called **Account**, and the page with
  the picture, the shown email and the name spelling **Profile** (#86).

### Fixed

- AI answers no longer run short because the model spent its output limit on thinking
  (Gemini 2.5 and OpenAI reasoning models). An answer cut off at the limit is an error for
  meeting summaries and analyses, not a result (#49).
- Building the image yourself no longer fails on the first `up --build` with Docker 29:
  only the web service builds, and the worker runs the image it built (#48).
- An MCP write with an `idempotency_key` that cannot be stored is refused before it writes.
  It used to write, fail, and write again on every retry (#84).
- `bundle install` works on Ubuntu 26.04, for installs without Docker (#41).

### Security

- The rate limit of `/api/v1` and `/api/mcp` no longer writes access tokens in plain text
  into the cache. It counts per digest of the token. With the default file cache, tokens
  that were in use stood in file names under `tmp/cache` (#92).
- An email a member keeps from the others is held back everywhere: pages, search, the
  assistant, MCP and `/api/v1`. Activities no longer store login addresses, and the addresses
  they stored, with their copies in notifications and outbox events, are removed when you
  update (#82).
- The meetings shown on a ticket are checked against the project each meeting is in. After a
  ticket moved to another project, its page could show titles and dates of meetings the reader
  had no rights to (#39).
- An unexpected failure while booking time or commenting over `/api/v1` no longer returns the
  text of the exception (#78), (#81).
- Backups kept in the repository directory stay out of an image you build yourself (#60).
- Updated dependencies: crass 1.0.8 for GHSA-pq4g-8rxf-4g29 (#46), ViewComponent 4.14.0 for
  GHSA-8qw7-6phv-7q6p (#47), mcp 1.8.2 for GHSA-4m5j-jjfc-97gx (#52).

### Maintenance

- Tests and CI, with no effect on a running instance (#53), (#67), (#68), (#69), (#75), (#79), (#80).
- Repository documentation: invited contributions may also be licensed under Apache-2.0, the
  README names the terminal client, and `ops/backup` says it describes our servers, not a
  self-hosting guide (#44), (#62), (#63), (#91).

### Upgrade notes

- Take a backup first. Six migrations run when the container starts, and a data backfill
  (`activities:drop_stored_emails`) removes stored login addresses for good. Both run by
  themselves; without Docker, run `bin/rails db:migrate lalabase:data_backfills` as usual. The
  backfill reads the activities, notifications and outbox events at each start.
- `compose.yml` no longer builds the image: it pulls `ghcr.io/lalabase/lalabase` in the
  version of the release you checked out. Update with `git fetch --tags && git checkout 2026.11.0`,
  then `docker compose pull && docker compose up -d`. If you changed your `compose.yml`,
  compare it with this one first.
- To keep building the image on your server, add `COMPOSE_FILE=compose.yml:compose.build.yml`
  to `.env`, and update with `docker compose up -d --build`, now and for later releases.
  In this setup `docker compose pull` stops with an error, and `docker compose up -d`
  without `--build` goes on running the old image and says nothing.
- Leave `LALABASE_VERSION` out of `.env`. Set, it pins the image, and a release checked out
  later keeps running the pinned version.
- Unless you keep building the image, the image `lalabase:local` that earlier releases built
  is no longer used: `docker image rm lalabase:local` removes it.
- Access tokens in `tmp/cache` (#92). With Docker the directory lives in the container and
  goes when the update replaces it, unless you mounted a volume there. Otherwise empty its
  contents once after updating. If that directory is part of a backup, or someone you do not
  trust could read it, replace your access tokens.
- No existing role gets the new rights `view_people`, `manage_people` and `move_meetings`.
  Account admins need none of them; for everyone else, grant them in the roles of the
  organisation.
- The members page now shows only the email a member chose, to organisation admins as well.
  The login address stays visible in the instance admin area. For API and MCP clients, the
  `email` of a member can be the contact address or `null`.
- API clients: an unexpected failure of `POST /api/v1/tickets/:ticket_id/time_sessions` or
  `POST /api/v1/tickets/:ticket_id/posts` now answers 500 instead of 422. A write on `/api/v1`
  with an `Idempotency-Key` over 255 bytes is refused with 422.
- No new required environment variables. `LALABASE_VERSION` and `COMPOSE_FILE` are optional,
  see above.

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
