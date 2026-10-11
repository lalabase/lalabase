# frozen_string_literal: true

# Embedding v2 PR 6a — flips the ANN-index membership of ONE vector space
# (details on the class).
module Embeddings
  # Turns the `indexed` flag of every sidecar row in ONE vector space, in batches
  # (doc/embedding_v2_pr6_retention_plan.md §4.5). Two directions, one mechanism:
  #
  #   RETIREMENT (indexed → false) runs AFTER a flip, asynchronously
  #     (Embeddings::RetireSpaceJob). The old space leaves the expression-partial ANN
  #     indexes; its rows stay as cold storage for a roll-back. No query-window risk:
  #     readers filter on the ACTIVE space's triple, so the old space's flag merely has
  #     to become false at some point.
  #
  #   REACTIVATION (indexed → true) runs BEFORE a roll-back flip, SYNCHRONOUSLY. This
  #     one is not symmetric in its timing, and that is the whole reason it exists in
  #     6a rather than later: Embeddings::NearestNeighbors filters on `indexed`, so
  #     flipping the pointer back to a retired space would serve zero rows org-wide —
  #     in the exact situation a roll-back is for.
  #
  # Counts are logged per space ("no silent caps"), and the row count is returned.
  #
  # Entry point: call
  class SpaceIndexFlag
    BATCH_SIZE = 5_000

    # @param space [EmbeddingSpace]
    # @param indexed [Boolean] target value of the flag
    # @return [Integer] number of rows changed
    def self.call(space:, indexed:, logger: Rails.logger)
      new(space: space, indexed: indexed, logger: logger).call
    end

    def initialize(space:, indexed:, logger: Rails.logger)
      @space = space
      @indexed = indexed
      @logger = logger
    end

    def call
      changed = 0
      # Only rows that actually differ: makes a re-run a no-op instead of a full
      # rewrite, and keeps the logged count honest about what this run did.
      @space.content_embeddings.where.not(indexed: @indexed)
            .in_batches(of: BATCH_SIZE) { |batch| changed += batch.update_all(indexed: @indexed) }

      @logger.info("[embeddings:#{@indexed ? 'reactivate' : 'retire'}] org=#{@space.organisation_id} " \
                   "space=#{@space.label} rows=#{changed}")
      changed
    end
  end
end
