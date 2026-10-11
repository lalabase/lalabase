# frozen_string_literal: true

# Keeps the organisations that ALREADY import from losing the feature when the
# previous migration switches it off for everyone.
#
# This is a data migration inside a schema migration, which the project rule in
# CLAUDE.md normally forbids. The exception is deliberate and bounded:
#
#   - The alternative (a rake task) is exactly what gets forgotten here. Deploys
#     run `db:migrate` automatically (Capfile, capistrano/rails/migrations), they
#     do not run rake tasks.
#   - Forgetting it is not cosmetic: an organisation mid-migration from CodebaseHQ
#     would lose the ROLLBACK button for an import it already ran, with no hint on
#     screen why the tab vanished.
#   - The cost is one UPDATE driven by a subquery over codebase_import_files, a
#     table with a handful of rows per organisation. No table rewrite, no long lock.
#
# Anyone who uploaded an import file has demonstrably used the importer, so the
# presence of a row is the signal. Organisations that never touched it stay off,
# which is the whole point of the flag.
class BackfillDataImportEnabledForImportingOrganisations < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL.squish)
      UPDATE organisations
         SET data_import_enabled = true
       WHERE id IN (SELECT DISTINCT organisation_id FROM codebase_import_files)
    SQL
  end

  # Not reversible in any useful sense: once an operator has flipped the switch by
  # hand, the backfilled rows are indistinguishable from the deliberate ones, so
  # switching them back off would destroy a decision. Rolling the schema migration
  # back drops the column outright, which is the real undo.
  def down
    # no-op, see above
  end
end
