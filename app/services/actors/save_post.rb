# frozen_string_literal: true

# app/services/actors/save_post.rb
#
# Creates or updates a Post on a Ticket, optionally schedules embedding
# processing, and tracks a "post_added" activity for newly created posts.
# A new comment also marks its author's notifications about the ticket as read:
# who answers has read it (Notifications::MarkTicketRead, user, 30.09.2026).

module Actors
  class SavePost < BaseActor
    def initialize(ticket:, params:, current_user:, id: nil)
      super()
      @post = find_or_new_post(ticket, params, id)
      @post_params = params
      @current_user = current_user
    end

    def record
      @post
    end

    def perform
      is_new_post = @post.new_record?

      if @post.id.present?
        @post.update!(@post_params)
      else
        @post.user = @current_user
        @post.assign_attributes(@post_params)
        @post.save!
      end

      if is_new_post
        track_new_post(@post)
        @notifications_marked_read = Notifications::MarkTicketRead.call(user: @current_user, ticket: @post.ticket)
      end
      purge_attachment_index_when_now_private
      redact_excerpt_when_now_private
    end

    def enqueue_jobs
      reindex_attachments_when_public_again

      if @notifications_marked_read.present?
        ids = @notifications_marked_read
        enqueue_after_commit { Notifications::MarkTicketRead.broadcast(ids) }
      end

      return unless @post&.create_embeddings?

      enqueue_after_commit do
        EmbeddingProcessingJob.perform_later(
          record_class: Post,
          record_id: @post.id,
          fragment_association: :fragments
        )
      end
    end

    private

    # The THIRD door of "a private comment's attachment is never indexed".
    # PostDocumentProcessingJob guards the upload and Embeddings::PendingEmbeddings the
    # re-index; neither can see this one, a comment that was PUBLIC when its file was
    # indexed and turns private afterwards. Inside #perform, so the purge shares the
    # transaction with the write that caused it.
    def purge_attachment_index_when_now_private
      return unless @post.saved_change_to_is_private? && @post.is_private?

      Fragment.purge_with_embeddings(fragmentable_type: 'PostDocument',
                                     fragmentable_ids: @post.post_documents.ids)
    end

    # The excerpt a public comment left in its activity and in the notifications
    # copied from it outlives the flip to private. Same transaction as the write.
    def redact_excerpt_when_now_private
      return unless @post.saved_change_to_is_private? && @post.is_private?

      Posts::ExcerptRedaction.call(post: @post)
    end

    # The way back. Only on the FLIP, and only for documents that have something to
    # embed — otherwise every edit of a public comment would re-embed its files, and the
    # billed half of that is the provider call.
    def reindex_attachments_when_public_again
      return unless @post&.saved_change_to_is_private?
      return if @post.is_private?

      @post.post_documents.each do |document|
        next unless document.create_embeddings? && document.plain_text_version.present?

        enqueue_after_commit do
          EmbeddingProcessingJob.perform_later(
            record_class: PostDocument, record_id: document.id, fragment_association: :fragments
          )
        end
      end
    end

    # Org-scoped lookup; builds a new post on the ticket when none is found.
    def find_or_new_post(ticket, params, id)
      Post.where(organisation: ticket.organisation, id: id).first || ticket.posts.build(params)
    end

    def track_new_post(post)
      post.ticket.track_post_added(post) if post.ticket.respond_to?(:track_post_added, true)
    end
  end
end
