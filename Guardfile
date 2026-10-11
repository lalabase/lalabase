# frozen_string_literal: true

# Improved Guardfile for Rails + RSpec
# Faster boot, smarter watchers, fewer full-suite runs

# Requirements (Gemfile – development & test):
# gem "guard"
# gem "guard-rspec", require: false
# gem "spring-commands-rspec", group: [:development, :test]
# gem "parallel_tests", group: [:development, :test] # optional

# -----------------------------------------------------------------------------
# Main guard :rspec block
# -----------------------------------------------------------------------------

# :cmd uses the Spring binstub → startup < 1 s
# keep_failed  : remembers failing examples automatically (≙ --only-failures)
# failed_mode  : reruns only failed examples on change until they pass
# all_* flags  : don’t waste time running the whole suite unless requested
# notification : on by default – disable via GUARD_NOTIFY=0

guard :rspec,
      cmd: 'bin/rspec --color --format progress',
      all_on_start: false,
      all_after_pass: false,
      keep_failed: true,
      failed_mode: :focus,
      notification: true do
  require 'guard/rspec/dsl'
  dsl = Guard::RSpec::Dsl.new(self)

  # ---------------------------------------------------------------------------
  # Fast default: run the changed spec file itself
  # ---------------------------------------------------------------------------
  watch(dsl.rspec.spec_files)

  # When helpers change, run the whole suite (they affect everything)
  watch(%r{^spec/(spec_helper|rails_helper)\.rb$}) { dsl.rspec.spec_dir }

  # ---------------------------------------------------------------------------
  # Generic file-to-spec mapping
  # ---------------------------------------------------------------------------

  # lib/foo/bar.rb → spec/lib/foo/bar_spec.rb (if you keep lib specs separate)
  watch(%r{^lib/(.+)\.rb$}) { |m| "spec/lib/#{m[1]}_spec.rb" }

  # app/models/foo.rb → spec/models/foo_spec.rb
  watch(%r{^app/models/(.+)\.rb$}) { |m| "spec/models/#{m[1]}_spec.rb" }

  # Controllers – also run routing specs for changed controller
  watch(%r{^app/controllers/(.+)_controller\.rb$}) do |m|
    [
      "spec/controllers/#{m[1]}_controller_spec.rb",
      "spec/routing/#{m[1]}_routing_spec.rb"
    ]
  end

  # Views trigger matching system specs (Capybara)
  watch(%r{^app/views/(.*)\.(erb|haml|slim)$}) { |m| "spec/system/#{m[1]}_spec.rb" }

  # Service objects → spec/services
  watch(%r{^app/services/(.+)\.rb$}) { |m| "spec/services/#{m[1]}_spec.rb" }

  # Jobs → spec/jobs
  watch(%r{^app/jobs/(.+)_job\.rb$}) { |m| "spec/jobs/#{m[1]}_job_spec.rb" }

  # GraphQL types, resolvers etc. (example)
  watch(%r{^app/graphql/(.+)\.rb$}) { |m| "spec/graphql/#{m[1]}_spec.rb" }

  # Routes change ⇒ run routing specs
  watch(%r{^config/routes\.rb$}) { 'spec/routing' }

  # DB migrations can affect models → run model layer
  watch(%r{^db/migrate/.*\.rb$}) { 'spec/models' }

  # Locales – useful if you have I18n-dependent views/system specs
  watch(%r{^config/locales/.+\.yml$}) { 'spec/system' }

  # ---------------------------------------------------------------------------
  # Optional: Turnip / feature specs
  # ---------------------------------------------------------------------------
  watch(%r{^spec/acceptance/(.+)\.feature$})
  watch(%r{^spec/acceptance/steps/(.+)_steps\.rb$}) do |m|
    Dir["spec/acceptance/**/#{m[1]}.feature"]
  end
end
