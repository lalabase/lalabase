# Contributing to Lalabase

Thank you for your interest in Lalabase. It is an open-source, privacy-first
project and knowledge platform for small service businesses, and it gets better
with every bug report and idea.

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Issues yes, unsolicited pull requests no

Lalabase is **open source, but not open contribution**. The code is public under
the AGPLv3. It is written by the maintainer and a few people we invite. We do
**not** accept unsolicited pull requests, and we will close them without review.
This is not about the quality of your work. In other projects we have seen that,
since AI coding assistants, outside pull requests take more work to review and fold
in than the change itself. Invited contributors license their contributions under
the Apache License 2.0 as well, so the project stays simple to license and to
maintain.

What helps us most:

- **Report bugs.** Open an issue with clear steps to reproduce, what you expected,
  and what happened instead.
- **Suggest features.** Open an issue describing the problem you want solved (the
  *why*), not only the solution.
- **Point out documentation gaps and translation errors.** Lalabase ships German and
  English; tell us where a text is wrong, unclear or missing in either language.

Please describe a fix in words rather than pasting a patch or a longer piece of
code into an issue. We can only take over code that its author has licensed under
the Apache License 2.0 as well.

> ⚠️ **Security issues are different.** Please do **not** open a public issue for
> security vulnerabilities. Follow our [Security Policy](SECURITY.md) instead.

## For invited contributors

If we have invited you to contribute code:

1. **License your work before the first commit.** Send the maintainer this
   sentence in writing (an email is enough): "I license all my contributions to
   Lalabase under the Apache License 2.0, in addition to the project's license."
   Nothing you write for Lalabase goes in before that, a concept or design text
   included.
2. **Mark every commit.** End each commit message with the line
   `License: Apache-2.0`, so the history shows which code the license covers.
3. **Make sure the code is yours to give.** If you are employed, code you write as
   part of your job may belong to your employer. Clear this with them before you
   send the sentence.
4. **Contribute only your own work.** No code copied from other projects or from
   Q&A sites, and no icons from other icon sets. Code an AI assistant writes for
   you is your responsibility: read it, and do not keep anything that reproduces
   someone else's code.
5. **New dependencies need a permissive license** (MIT, Apache-2.0, BSD, ISC; the
   full list is in [CLAUDE.md](CLAUDE.md), section "Third-party licenses").
   Vendored files also need an entry in
   [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).
6. **Commit with your GitHub noreply address** (`git config user.email` in your
   clone). A private address becomes public with every commit, and the leak check
   fails on it.
7. **Keep the diff free of anything private:** no keys, tokens, `.env` files, real
   host names, customer data or local paths. Test data is invented, and addresses
   use `example.com`.
8. **Work on a branch and open a pull request.** The maintainer reviews and merges.
   Commit messages are in English, in the imperative, with one line on what and why.
9. **All CI checks must pass.** A red RuboCop or Brakeman run means a new finding,
   not old debt.
10. **Follow the conventions in [CLAUDE.md](CLAUDE.md)** and in the directory notes
    (`app/**/CLAUDE.md`): tenant boundaries, actors for writes, every text in German
    and English, a failing test before a bug fix. Claude Code loads these files on
    its own.

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

> 💡 To run a release instead of working on the code, use the Docker setup in the
> [README](README.md#self-host-with-docker).

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

Code from invited contributors is also available under the
[Apache License 2.0](LICENSES/Apache-2.0.txt). Their commits end with the line
`License: Apache-2.0`.

The hosted Lalabase Cloud is operated by GBoyke Solutions on this same AGPLv3
codebase plus separately developed components. The open-source edition always
stays fully AGPLv3 and complete on its own.

## Questions?

Open an issue. Thank you for helping build a privacy-first alternative for
DACH teams. 💚
