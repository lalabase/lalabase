# frozen_string_literal: true

# Step 4 of doc/projekt_chat_abbau_plan.md, release 1 of three: the operator flag
# gets the name of the thing it actually gates.
#
# `project_chat_enabled` was named after a page that projekt_chat_abbau removed. What
# it decides is whether a connected repository is INDEXED at all -- the two indexer
# jobs, the reindex POST, the activation backfill's revive and the indexing UI all
# read it. The old name made it look like the switch of a surface that no longer
# exists, which is how a gate quietly loses its subject.
#
# ⚠️ ADD ONLY. The old column stays, is still written by the admin toggle, and is
# still read (as the second half of an OR) for the length of this release. `cap`
# migrates BEFORE it restarts, so a release that renamed in one step would run this
# migration while the previous code was still serving reads of the old column.
#
# The backfill is NOT here: `rake organisations:backfill_code_indexing` copies the
# values after the deploy. A data migration belongs in a task, not in a schema
# migration (CLAUDE.md), and this one has to run at a moment the deploy cannot pick.
class AddCodeIndexingEnabledToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :code_indexing_enabled, :boolean, default: false, null: false
  end
end
