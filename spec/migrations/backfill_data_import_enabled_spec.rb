# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260806190000_backfill_data_import_enabled_for_importing_organisations')

# The one-shot data migration that keeps existing CodebaseHQ users from silently
# losing the importer when the flag ships defaulted to false. It runs exactly once
# on deploy, so this loads the REAL migration file and calls #up on it: a spec that
# repeated the UPDATE inline would prove its own copy correct and nothing else.
RSpec.describe BackfillDataImportEnabledForImportingOrganisations, type: :model do
  subject(:run_migration) { described_class.new.tap { |m| m.verbose = false }.up }

  let(:importer) { create(:organisation) }
  let(:untouched) { create(:organisation) }

  before do
    ActsAsTenant.with_tenant(importer) do
      create(:codebase_import_file, organisation: importer, user: create(:user))
    end
  end

  it 'switches the flag on for an organisation that has already uploaded an import file' do
    expect(importer.reload.data_import_enabled).to be(false), 'expected the column default to be off'

    run_migration

    expect(importer.reload.data_import_enabled).to be(true)
  end

  it 'leaves an organisation that never imported switched off' do
    untouched

    run_migration

    expect(untouched.reload.data_import_enabled).to be(false)
  end

  it 'does not undo an operator who already switched it off again' do
    # Re-running the migration (a repeated deploy, a resumed migration run) must not
    # fight an operator decision made in between... it does, and that is accepted:
    # the migration is one-shot. Pinned so the behaviour is a recorded choice rather
    # than a surprise if someone ever schedules it periodically.
    run_migration
    importer.update!(data_import_enabled: false)

    run_migration

    expect(importer.reload.data_import_enabled).to be(true)
  end
end
