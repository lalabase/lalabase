# frozen_string_literal: true

class EmbeddingProcessingJob < ApplicationJob
  queue_as :default

  # ONE run per record at a time. Before the fragment/embedding split two concurrent runs
  # could not collide: each wrote fresh fragments with fresh UUIDs, so their sidecar rows
  # never shared a (type, id, triple) slot. Reuse removed that property — unchanged text
  # now keeps its fragment ids, so both runs aim at the same unique slot in
  # idx_content_embeddings_unique_space.
  #
  # #attach_embedding survives the collision on its own; this exists so the collision is
  # rare rather than routine, because the wasted half is not the insert but the embedding
  # CALL before it, which is billed. Actors::SaveNote enqueues on every save, a title-only
  # edit included, so a burst of saves used to mean a burst of duplicate provider calls.
  #
  # ⚠️ :block, NOT :discard. The first draft discarded, on the reasoning that a duplicate
  # arriving mid-run has nothing left to do. That is true only while the TEXT has not
  # moved, and the loser of this race is exactly the run that carries the newer text:
  # Solid Queue destroys a conflicting job in `after_create` (Job::Executable#dispatch ->
  # #handle_concurrency_conflict), so a second save landing during the first run is gone
  # before a worker ever reads it. The first run then finishes over the OLDER text and
  # sets embeddings_creation_flag = true, and nothing comes back for it:
  # Embeddings::PendingEmbeddings selects on that flag, and the reindexer's delta mode
  # compares source_hash against the FRAGMENT's text, not the record's, so the drift
  # between record and fragment is invisible to it too. Stale search results until
  # somebody saves the record again.
  #
  # Blocking costs nothing that discarding saves. The billed half is the embedding CALL,
  # and EmbeddingProcessingService#write_fragments already reuses an unchanged fragment
  # set, so the released duplicate finds #unembedded_fragments empty and never reaches the
  # provider. Discarding only ever throws away work that was NOT a duplicate.
  limits_concurrency to: 1, key: ->(args) { "embed-#{args[:record_class]}-#{args[:record_id]}" },
                     duration: 30.minutes, on_conflict: :block

  discard_on ActiveRecord::RecordNotFound do |_job, error|
    Rails.logger.warn("EmbeddingProcessingJob discarded: #{error.message}")
  end

  def perform(record_class:, record_id:, fragment_association: :fragments)
    record = ActsAsTenant.without_tenant { record_class.find(record_id) }

    ActsAsTenant.with_tenant(record.organisation) do
      EmbeddingProcessingService.new(record, fragment_association).process
    end
  end
end
