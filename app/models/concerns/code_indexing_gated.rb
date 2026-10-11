# frozen_string_literal: true

# The operator switch for "may this organisation have its repositories indexed at
# all". ONE predicate, asked by both indexer jobs, the reindex POST, the activation
# backfill's revive, the indexing UI and its unavailable hint.
#
# ⚠️ A CONCERN and not a method on Organisation, because Admin::Organisation is a
# separate class over the same table and the admin toggle reads this. That is the
# mistake spec/models/admin_twin_concern_parity_guard_spec.rb was written for after it
# happened three times: a behaviour declared on the tenant-side twin alone does
# nothing on the operator's path, silently.
#
# RELEASE 2 of a three-release rename (doc/projekt_chat_abbau_plan.md step 4). The
# column was called `project_chat_enabled`, named after a page projekt_chat_abbau
# removed; what it always decided is whether the code index gets built.
#
#   Release 1  added code_indexing_enabled, read BOTH here, wrote both, then
#              `rake organisations:backfill_code_indexing` (6 organisations, 31.08.2026)
#   Release 2  THIS: the new column alone; the old one is in Organisation's and
#              Admin::Organisation's ignored_columns, so nothing SELECTs it any more
#   Release 3  drop the old column
#
# Three, not two: `cap` migrates BEFORE it restarts, so a drop shipped with the code
# that stops reading the column would run while the previous code was still serving.
# The `ignored_columns` in this release is what makes release 3 safe -- without it a
# dropped column against a model that still selects it is a 500 on every read.
#
# This is an OPERATOR switch, deliberately NOT an AI-availability question.
# `ai_available_for?(:repository_indexing)` answers whether the organisation can ROUTE
# the call; folding the two together would hand the feature to every AI-enabled
# organisation and take away the operator's ability to withhold it.
module CodeIndexingGated
  extend ActiveSupport::Concern

  def code_indexing?
    code_indexing_enabled?
  end
end
