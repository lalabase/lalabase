# frozen_string_literal: true

# Which records are still waiting to be embedded, per content type, as lazy relations
# for the two enqueue paths.
#
# Entry point: relations_by_model
module Embeddings
  # THE single definition of "still pending" over the types in Embeddings::ContentTypes.
  # The type list and the per-type opt-in rules live THERE; this module adds exactly one
  # thing, the state: "embedding flag is NULL or false".
  #
  # Two callers share it, in DIFFERENT tenant contexts — and acts_as_tenant applies the
  # org scope from the AMBIENT context when each relation is materialised, so one builder
  # correctly serves both:
  #   - EmbeddingReprocessingService (enqueue) runs inside with_tenant(org) → the
  #     relations self-scope to that org.
  #   - Embeddings::PendingBacklog (monthly catch-up discovery) runs inside
  #     without_tenant → the relations span all orgs.
  #
  # ⚠️ Deliberately WITHOUT an error term: a record whose last attempt failed is handed
  # out again so the button can retry it. Embeddings::IndexHealth and the sync page count
  # the same record as FAILED, not pending — that difference is pinned in
  # index_health_pending_parity_spec.rb so it stays a decision rather than a surprise.
  module PendingEmbeddings
    module_function

    # @return [Hash{Class => ActiveRecord::Relation}] content model → its pending
    #   relation, in registry order. The class is what the enqueue path needs; #relations
    #   drops it.
    def relations_by_model
      ContentTypes.entries.to_h do |entry|
        relation = entry.model.all
        relation = relation.joins(entry.join) if entry.join
        [entry.model, relation.where(entry.opt_in).where(ContentTypes.flag_pending(entry.table))]
      end
    end

    # @return [Array<ActiveRecord::Relation>] the pending relations, model-agnostic.
    def relations
      relations_by_model.values
    end
  end
end
