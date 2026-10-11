# frozen_string_literal: true

# Embedding v2 PR 6b — when did this space last stop serving?
#
# The retention GC keeps the (limit - 1) most recent non-active spaces and deletes the
# rest. "Most recent" has to mean LAST SERVED, not LAST CREATED: after a roll-back the
# two disagree, and ordering by created_at would keep the space that was rolled back
# FROM while deleting the one that was rolled back TO — the roll-back net, collected in
# the exact situation it exists for.
#
# NULL means "never served" (a build that was abandoned before its flip). Those sort
# LAST and are therefore collected FIRST, which is right: a space that never served is
# no roll-back target.
#
# No backfill: every space held today is the active one of its org, and the active
# space is never a GC candidate.
class AddRetiredAtToEmbeddingSpaces < ActiveRecord::Migration[8.0]
  def change
    add_column :embedding_spaces, :retired_at, :datetime
  end
end
