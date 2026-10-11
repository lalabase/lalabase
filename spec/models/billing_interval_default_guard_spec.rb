# frozen_string_literal: true

require 'rails_helper'

# Guard: the DB default of `accounts.billing_interval` says the same thing as
# `Subscriptions::Constants::INTERVAL_MONTHLY`.
#
# Why this exists (the drift it prevents):
# The W3 migration writes the LITERAL 'monthly' rather than the constant, on
# purpose -- a migration has to replay from a bare checkout years from now, and
# referencing app code makes `db:migrate` from zero die with NameError once the
# constant is renamed or moved (see the comment in
# db/migrate/20260805180000_add_billing_state_to_accounts.rb).
#
# That deliberate duplication needs the other half: something that fails when the
# two halves drift. Renaming INTERVAL_MONTHLY leaves the already-run migration
# and every existing row untouched, so a new account would silently be created
# with an interval the model's own inclusion validation rejects.
#
# This lives here, and in the curated list in .github/workflows/guards.yml,
# because the CI job runs neither spec/models/ nor spec/requests/ wholesale. The
# model spec exercises the same agreement through `create(:account)`, but nothing
# automatic pulls that trigger -- a comment pointing at a check that never runs
# is worse than no comment, because it reassures the next reader falsely.
#
# Reads columns_hash rather than creating a record: no DB write, and it asks the
# schema directly instead of going through the factory, which could mask the
# drift by setting the attribute itself.
RSpec.describe 'accounts.billing_interval default' do
  let(:column_default) { Account.columns_hash['billing_interval'].default }

  it 'matches Subscriptions::Constants::INTERVAL_MONTHLY' do
    expect(column_default).to eq(Subscriptions::Constants::INTERVAL_MONTHLY),
                              'the DB default of accounts.billing_interval and ' \
                              'Subscriptions::Constants::INTERVAL_MONTHLY have drifted apart. ' \
                              'The migration writes the literal on purpose; when the constant ' \
                              'is renamed, add a migration that changes the column default too.'
  end

  # The weaker but independent half: even if someone changes BOTH the constant
  # and this guard's expectation, a default outside the registry would leave new
  # accounts failing their own inclusion validation on first save.
  it 'is a value the registry actually knows' do
    expect(Subscriptions::Constants::BILLING_INTERVAL_KEYS).to include(column_default)
  end

  it 'is what a new account actually gets' do
    expect(Account.new.billing_interval).to eq(Subscriptions::Constants::INTERVAL_MONTHLY)
  end
end
