# frozen_string_literal: true

# app/services/actors/destroy_post.rb

module Actors
  class DestroyPost < BaseActor
    def initialize(id:)
      super()
      @post_id = id
      @post = nil
      @blob_ids_to_purge = []
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      # Lookup happens here (not in the constructor) so a missing/foreign id
      # becomes a clean failure Result instead of a constructor exception.
      @post = Post.find_by(id: @post_id)
      raise ActorError, 'Post not found' if @post.nil?

      # Pre-delete post_documents in batch to avoid N+1 from touch/purge callbacks.
      delete_post_documents_in_batch
      @post.destroy!
    end

    def enqueue_jobs
      purge_detached_blobs
    end

    private

    # Blob purge runs after the destroy commits: we must not purge files for a
    # rolled-back destroy. One PurgeJob per blob (ActiveStorage has no batch
    # purge), bounded by the number of attachments on the post — the same kind
    # of per-record enqueue the suite allows (see spec/support/prosopite.rb).
    def purge_detached_blobs
      return if @blob_ids_to_purge.empty?

      enqueue_after_commit do
        ActiveStorage::Blob.where(id: @blob_ids_to_purge).find_each(&:purge_later)
      end
    end

    def delete_post_documents_in_batch
      pd_ids = @post.post_documents.ids
      return if pd_ids.empty?

      # Fragments AND their sidecar rows, sidecar first (the subselect needs the fragment
      # rows). Through Fragment.purge_with_embeddings since the privacy toggle in
      # Actors::SavePost needs the identical sequence: one owner instead of two copies.
      Fragment.purge_with_embeddings(fragmentable_type: 'PostDocument', fragmentable_ids: pd_ids)

      # Detach attachments now (atomic with the destroy); remember the blobs so
      # they can be purged after commit.
      attachments = ActiveStorage::Attachment.where(record_type: 'PostDocument', record_id: pd_ids)
      @blob_ids_to_purge = attachments.pluck(:blob_id)
      attachments.delete_all

      # Delete post_documents (skip individual destroy callbacks to avoid touch N+1)
      PostDocument.where(id: pd_ids).delete_all
      @post.association(:post_documents).reset
    end
  end
end
