# Contributing to Lalabase

Thank you for your interest in Lalabase. It is an open-source, privacy-first
project and knowledge platform for small service businesses, and it gets better
with every bug report and idea.

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Issues yes, pull requests no

Lalabase is **open source, but not open contribution**. The code is public under
the AGPLv3, and all of it is written by the maintainer. We do **not** accept pull
requests, and we will close them without review. This is not about the quality of
your work: it keeps the copyright in one hand, so the project can stay simple to
license and to maintain.

What helps us most:

- **Report bugs.** Open an issue with clear steps to reproduce, what you expected,
  and what happened instead.
- **Suggest features.** Open an issue describing the problem you want solved (the
  *why*), not only the solution.
- **Point out documentation gaps and translation errors.** Lalabase ships German and
  English; tell us where a text is wrong, unclear or missing in either language.

Please describe a fix in words rather than pasting a patch or a longer piece of
code into an issue. We write every change ourselves, and we cannot take over code
someone else wrote.

> ⚠️ **Security issues are different.** Please do **not** open a public issue for
> security vulnerabilities. Follow our [Security Policy](SECURITY.md) instead.

## Forks

The AGPLv3 lets you fork Lalabase and change it for your own use. If you run a
modified version as a network service, the license requires you to offer its
source code to your users. The setup below is the supported way to run it locally.

## Development Setup

**Prerequisites**

- Ruby (see [`.ruby-version`](.ruby-version))
- PostgreSQL 14+ with the [`pgvector`](https://github.com/pgvector/pgvector)
  extension (used for AI/embedding features)
- Node.js (for asset tooling and Bootstrap icon fonts)

**Getting started**

```bash
git clone https://github.com/lalabase/lalabase.git
cd lalabase

bundle install
npm install
npm run copy:fonts          # copy Bootstrap icon fonts into public/fonts

bin/rails db:setup          # create, load schema, and seed
bin/rails tailwindcss:build # build the Tailwind stylesheet

bin/dev                         # Tailwind watcher + Solid Queue
bin/rails server -b 0.0.0.0     # the web server, in a second terminal
```

`bin/dev` does not start the web server, so both processes are needed.

> 💡 A one-command `docker compose up` setup is on the roadmap. Until then, the
> steps above are the supported path.

### Checks

```bash
bundle exec rspec                # tests
bundle exec rubocop              # Ruby style
bundle exec erblint --lint-all   # ERB style
bundle exec brakeman             # security scanner
```

## License

Lalabase is released under the
[GNU Affero General Public License v3.0](LICENSE), version 3 only
(SPDX: `AGPL-3.0-only`). Bundled third-party
components keep their own licenses, listed in
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).

The hosted Lalabase Cloud is operated by GBoyke Solutions on this same AGPLv3
codebase plus separately developed components. The open-source edition always
stays fully AGPLv3 and complete on its own.

## Questions?

Open an issue. Thank you for helping build a privacy-first alternative for
DACH teams. 💚
