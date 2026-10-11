# Repository Guidelines

## Project Structure & Module Organization
- app/: Rails code (models, controllers, views, ViewComponents in `app/components`, policies, services, jobs, javascript Stimulus controllers).
- config/: environment, routes, initializers. db/: migrations and seeds. lib/: utilities.
- spec/: RSpec tests (unit, request, system). public/: static assets.
- bin/: entrypoints (`bin/dev`, `bin/rspec`, `bin/rubocop`, `bin/setup`).

## Build, Test, and Development Commands
- `bin/setup`: install gems, prepare database, clear tmp/log.
- `bin/dev`: start app via Foreman using `Procfile.dev` (Rails server, Tailwind watch, Solid Queue).
- `bin/rails db:setup|db:migrate|db:seed`: database lifecycle (PostgreSQL).
- `bin/rails tailwindcss:build`: build the Tailwind CSS. `npm run copy:fonts`: copy the Bootstrap Icons fonts to `public/fonts` (once after `npm install`).
- `bin/rspec [path]`: run test suite (add a path to scope).
- `bin/rubocop`: lint/format Ruby per `.rubocop.yml`. `bundle exec erblint app/views`: lint ERB. `bin/brakeman`: security scan.

## Coding Style & Naming Conventions
- Ruby: 2-space indent; follow RuboCop Rails Omakase. Keep methods small and object-oriented (policies/services/components).
- ViewComponents: place in `app/components`, name `something_component.rb` with matching `.html.erb` template; keep inputs explicit.
- Stimulus: controllers in `app/javascript/controllers`, named `thing_controller.js`; data-attributes in kebab-case.
- Tests/files: snake_case for files; classes/modules in CamelCase; controllers plural, models singular.

## Testing Guidelines
- Frameworks: RSpec + Capybara + Shoulda Matchers + FactoryBot. Prefer fast unit tests; add request/system specs for flows.
- Conventions: `*_spec.rb` under `spec/` (e.g., `spec/models/user_spec.rb`, `spec/system/login_spec.rb`). Component specs in `spec/components/`.
- Running: `bin/rspec` for all; use tags like `:system` when needed. Database cleaning is configured via `database_cleaner`.

## Commit & Pull Request Guidelines
- Commits: Conventional style (e.g., `feat(scope): ...`, `fix: ...`, `chore: ...`, `docs: ...`, `refactor: ...`). One logical change per commit.
- PRs: clear description, link issues, note migrations, include screenshots/GIFs for UI/ViewComponent changes, and add/adjust tests.
- Pre-push checks: `bin/rspec && bin/rubocop && bundle exec erblint app/views && bin/brakeman && bin/rails tailwindcss:build`.

## Security & Configuration Tips
- Env: copy `.env.example` to `.env`; never commit secrets. Use Pundit policies and add policy specs for new permissions.

## Documentation location
- The maintainers' internal plans, work logs and reviews live outside this repository. Do not create `doc/` or `docs/` here, and do not recreate a file a comment refers to under those paths.
- Comments that name `doc/...` or `docs/...` point to that internal archive; it is not part of the public repository.
- User help and self-hosting guides are a separate documentation project; this repository holds no copy. `app/services/docs/` and `spec/fixtures/docs_catalogue/` are application code and test data, not part of that archive.
