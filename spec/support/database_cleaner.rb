# frozen_string_literal: true

# Configure Database Cleaner for RSpec
require 'database_cleaner/active_record'

# System specs clean by truncation, so the fixture transaction buys them nothing,
# and it costs minutes: Rails opens it on EVERY pool, Solid Queue's own included.
# A job the browser's request enqueues then sits locked in that open transaction,
# and the truncation below waits on the lock until something times out (about two
# minutes per example, and the next example's browser call dies with
# Net::ReadTimeout). Puma also needs committed rows to read them.
module NontransactionalSystemSpecs
  extend ActiveSupport::Concern

  included { self.use_transactional_tests = false }
end

RSpec.configure do |config|
  config.include NontransactionalSystemSpecs, type: :system

  # Start with a clean state for every test
  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
  end

  # Use transactions for most tests as they're faster
  config.before(:each) do
    DatabaseCleaner.strategy = :transaction
  end

  # Reset tenancy between tests to avoid data leakage
  config.before(:each) do
    ActsAsTenant.current_tenant = nil
  end

  # Use truncation for system tests or tests that need JavaScript
  config.before(:each, type: :system) do
    DatabaseCleaner.strategy = :truncation
  end

  # Clean before each test
  config.before(:each) do
    DatabaseCleaner.start
  end

  # Drain pending browser requests via Capybara reset before deleting their records.
  config.append_after(:each) do
    DatabaseCleaner.clean
    ActsAsTenant.current_tenant = nil
  end
end
