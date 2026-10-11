# frozen_string_literal: true

module Embeddings
  # Retires ONE vector space after a flip: its rows leave the ANN indexes
  # (`indexed` → false), the rows themselves stay as the roll-back net until the
  # retention GC collects them (embedding v2 PR 6a, sheet §4.5).
  #
  # Enqueued exclusively by Actors::FlipEmbeddingModel via enqueue_after_commit, so it
  # can never run against a pointer change that was rolled back.
  #
  # Deliberately asynchronous: the flip itself must stay a single-column UPDATE, and
  # retirement touches every sidecar row of the old space. Readers are unaffected
  # either way — they filter on the ACTIVE space's triple, so the old flag only has to
  # become false eventually. (Reactivation is the asymmetric one and runs synchronously
  # BEFORE a roll-back flip — see Embeddings::SpaceIndexFlag.)
  class RetireSpaceJob < ApplicationJob
    queue_as :indexing

    # @param organisation_id [String] tenant scope for the space lookup
    # @param space_id [String] the space to retire
    def perform(organisation_id, space_id)
      organisation = Organisation.find_by(id: organisation_id)
      return if organisation.nil?

      space = ActsAsTenant.with_tenant(organisation) do
        EmbeddingSpace.find_by(id: space_id, organisation_id: organisation.id)
      end
      # Already collected by the retention GC between flip and job pickup — nothing to
      # retire, and nothing wrong either.
      return if space.nil?

      ActsAsTenant.with_tenant(organisation) do
        retire_unless_active(organisation, space)
      end
    end

    private

    # Guard and update in ONE transaction, with the organisation row locked.
    #
    # A bare `return if space.active?` before the update was a time-of-check/time-of-use
    # gap (review finding R1): a roll-back landing between check and the batched update
    # would de-index the space that is serving RIGHT NOW — org-wide zero hits, silently,
    # in the exact situation a roll-back exists for. The lock makes a concurrent flip
    # wait until this decision is committed.
    #
    # Reading the pointer FRESH inside the lock is the other half: `space.active?` would
    # answer from the association loaded before the lock was taken.
    def retire_unless_active(organisation, space)
      ActiveRecord::Base.transaction do
        locked = Organisation.lock.find_by(id: organisation.id)
        # nil   → the org was deleted while this job waited; nothing to retire.
        # equal → this space is active AGAIN (flip → roll-back within queue latency).
        next if locked.nil? || locked.active_embedding_space_id == space.id

        Embeddings::SpaceIndexFlag.call(space: space, indexed: false)
      end
    end
  end
end
