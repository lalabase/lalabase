# frozen_string_literal: true

# app/services/actors/save_ticket.rb
#
# Tier-2 actor: owns #call because assignee and document sync run OUTSIDE the
# ticket transaction. It reuses the shared BaseActor helpers (with_error_mapping,
# with_actor_context, success/failure, enqueue_after_commit) instead of the Tier-1
# #perform template.
#
# The two cohesive side-effect blocks live in their own collaborators:
# TicketDocumentSync (pure DB step, returns created docs so this actor schedules
# their processing jobs) and TicketAssignmentSync (assignee delta + subscriptions
# + activity tracking). The actor orchestrates: ticket write, then the syncs.

module Actors
  class SaveTicket < BaseActor
    def initialize(project:, params:, current_user:, id: nil)
      super()
      @project = project
      @ticket = find_or_new_ticket(project, params, id)
      @ticket_params = params
      @current_user = current_user
    end

    def record
      @ticket
    end

    def call
      with_error_mapping do
        with_actor_context do
          assignee_ids = nil
          is_new_ticket = !@ticket.persisted?

          ActiveRecord::Base.transaction do
            if check_current_user
              assignee_ids = @ticket_params[:assignee_ids]
              ticket_params_without_assignees = @ticket_params.except(:assignee_ids, :ticket_document_files, :remove_document_ids)

              if @ticket.id.present?
                @ticket.updater = @current_user
                @ticket.update!(ticket_params_without_assignees)
              else
                @ticket.creator = @current_user
                @ticket.assign_attributes(ticket_params_without_assignees)
                @ticket.save!
              end
            end
          end

          # Side-effects run after the ticket transaction has committed.
          enqueue_embedding_processing if @ticket.create_embeddings?
          sync_documents
          TicketAssignmentSync.call(ticket: @ticket, assignee_ids: assignee_ids, is_new_ticket: is_new_ticket) if assignee_ids

          success(@ticket)
        end
      end
    end

    private

    def check_current_user
      member = @current_user.present? && @current_user.member_of_organisation?(@project.organisation)
      raise ActorError.new(I18n.t('services.actors.not_member'), code: :not_member) unless member

      true
    end

    # TicketDocumentSync is a pure DB step that returns the documents it created;
    # the actor owns the post-commit job enqueue (guard-checked boundary).
    def sync_documents
      created = TicketDocumentSync.call(
        ticket: @ticket,
        remove_document_ids: @ticket_params[:remove_document_ids],
        document_files: @ticket_params[:ticket_document_files]
      )
      created.each { |td| enqueue_after_commit { TicketDocumentProcessingJob.perform_later(td) } }
    end

    def find_or_new_ticket(project, ticket_params, id)
      # Find org-wide (tickets may move between projects of the org), but build a
      # new ticket under this specific project. The shared helper enforces the
      # tenant-safe lookup; the org-scoped find_scope keeps a foreign id from
      # resolving to another tenant's ticket.
      find_or_build(
        Ticket.where(organisation: project.organisation),
        id,
        ticket_params.except(:assignee_ids, :ticket_document_files, :remove_document_ids),
        build_scope: project.tickets
      )
    end

    def enqueue_embedding_processing
      enqueue_after_commit do
        EmbeddingProcessingJob.perform_later(
          record_class: Ticket,
          record_id: @ticket.id,
          fragment_association: :fragments
        )
      end
    end
  end
end
