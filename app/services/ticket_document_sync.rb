# frozen_string_literal: true

# Syncs a ticket's attached documents from the submitted params: destroys the
# documents marked for removal and creates one TicketDocument per uploaded file.
#
# Extracted from Actors::SaveTicket#handle_ticket_documents. Deliberately does NOT
# enqueue the post-processing job itself: it RETURNS the created TicketDocuments so
# the caller (the actor) schedules processing via its guard-checked
# enqueue_after_commit boundary. Keeping job enqueuing in the actor is what the
# actor contract guard enforces — the collaborator stays a pure DB step.
#
# The caller owns the transaction (the ticket write commits first; this runs after,
# mirroring the previous behaviour where document sync happened outside the txn).
class TicketDocumentSync
  # @return [Array<TicketDocument>] the documents created this run (possibly empty)
  def self.call(ticket:, remove_document_ids: nil, document_files: nil)
    new(ticket: ticket, remove_document_ids: remove_document_ids, document_files: document_files).call
  end

  def initialize(ticket:, remove_document_ids:, document_files:)
    @ticket = ticket
    @remove_document_ids = remove_document_ids
    @document_files = document_files
  end

  def call
    destroyed_any = destroy_marked
    created = create_new

    # Refresh the association cache so the response renders fresh data.
    @ticket.ticket_documents.reload if destroyed_any || created.any?

    created
  end

  private

  def destroy_marked
    return false if @remove_document_ids.blank?

    destroyed_any = false
    @remove_document_ids.each do |doc_id|
      doc = @ticket.ticket_documents.find_by(id: doc_id)
      if doc&.destroy
        destroyed_any = true
        Rails.logger.debug "[TicketDocumentSync] Destroyed ticket_document #{doc_id}"
      else
        Rails.logger.warn "[TicketDocumentSync] Could not destroy ticket_document #{doc_id} (not found or destroy failed)"
      end
    end
    destroyed_any
  end

  def create_new
    return [] if @document_files.blank?

    @document_files.filter_map do |file|
      next if file.blank?

      TicketDocument.create!(ticket: @ticket, ticket_document_file: file)
    end
  end
end
