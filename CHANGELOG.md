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

### Fixed

- Images in rich texts are kept when an instance gets a new `SECRET_KEY_BASE`, for example
  after moving to a new server or cloning one. Until now, editing such a text afterwards
  detached its images and deleted the files.

### Added

- `bin/rails rich_text_embeds:resign_sgids` brings back the images and note mentions of
  rich texts after a new `SECRET_KEY_BASE` (run it with `DRY_RUN=1` first). See "Moving to
  a new server or cloning a server" in the self-hosting docs.

## [2026.10.0] - 2026-10-12

<!-- drafted from 4622099a2ca151fbe8fa3995108ca320a2d3cbee -->

### Added

- First public release. Lalabase has been developed since October 2024 (more than 2,300 commits,
  about 970 pull requests) and has run in production for customers since September 2025. The earlier
  history stays private: it holds customer data and details of our servers.

### Upgrade notes

- None.
