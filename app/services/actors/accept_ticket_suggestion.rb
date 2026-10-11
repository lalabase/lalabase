# frozen_string_literal: true

# app/services/actors/accept_ticket_suggestion.rb

module Actors
  # Tier-2 actor (owns #call because it composes Actors::SaveTicket and needs the
  # atomic 3A guard). Accepting a meeting ticket suggestion is a CROSS-AREA write:
  # it turns the suggestion into a REAL ticket (Actors::SaveTicket) and links the
  # meeting to it (Reference, exact meeting_ticket_links pattern), then records
  # created_ticket_id for the audit trail (decision 3 — no reference metadata).
  #
  # Concurrency (Eng-Review 3A): the open→accepted flip is an atomic
  # `where(status: open).update_all` INSIDE the transaction — only a hit-count of 1
  # proceeds; a second concurrent accept (double-click, two tabs) hits 0 and gets a
  # friendly :already_processed failure, NEVER a second ticket. If the ticket
  # creation or link then fails, the whole transaction rolls back — including the
  # status flip — so the suggestion returns to `open` for a clean retry.
  #
  # SaveTicket's own transaction nests inside ours (the PostUpdateService precedent),
  # and its after-commit embedding enqueue hangs on OUR outermost commit.
  class AcceptTicketSuggestion < BaseActor
    def initialize(meeting:, suggestion:, current_user:)
      super()
      @meeting = meeting
      @suggestion = suggestion
      @current_user = current_user
      @ticket = nil
    end

    def record
      @ticket
    end

    def call
      with_error_mapping do
        with_actor_context do
          ActiveRecord::Base.transaction do
            @meeting.lock!
            allowed = MeetingPolicy.new(@current_user, @meeting).update? &&
                      ProjectPolicy.new(@current_user, @meeting.project).area_access?(:tickets, :write)
            raise ActorError.new(I18n.t('assistant_suggestions.unavailable'), code: :forbidden) unless allowed

            claim_open_suggestion!
            @suggestion.reload
            run = @suggestion.meeting_ticket_suggestion_run
            raise ActorError.new(I18n.t('assistant_suggestions.unavailable'), code: :forbidden) if run && run.project_id != @meeting.project_id

            @ticket = create_ticket!
            link_meeting_to_ticket!(@ticket)
            @suggestion.update!(created_ticket_id: @ticket.id, status: :accepted)
          end
          success(@ticket)
        end
      end
    end

    private

    # 3A: atomically move open → accepted. update_all does NOT run enum casting, so
    # pass explicit integers. A hit-count other than 1 means another request already
    # accepted/dismissed it → abort with a friendly domain failure (no second ticket).
    # The row-level update also acts as the concurrency lock for the rest of the chain.
    def claim_open_suggestion!
      # the atomic status flip IS the
      # concurrency guard; a single UPDATE ... WHERE status = open is exactly what
      # makes a double accept impossible. Validations/callbacks are irrelevant here.
      claimed = MeetingTicketSuggestion
                .where(id: @suggestion.id, meeting_id: @meeting.id, status: MeetingTicketSuggestion.statuses[:open])
                .update_all(status: MeetingTicketSuggestion.statuses[:accepted], updated_at: Time.current)
      return if claimed == 1

      raise ActorError.new(I18n.t('services.actors.accept_ticket_suggestion.already_processed'),
                           code: :already_processed)
    end

    # Reuse Actors::SaveTicket for the real ticket write (assignee/document syncs are
    # no-ops for a bare support ticket). content is ActionText (has_rich_text) — a
    # plain description string is accepted. A failure rolls the outer transaction
    # (incl. the status flip) back via the raised ActorError.
    def create_ticket!
      result = Actors::SaveTicket.call(
        project: @meeting.project,
        params: { title: @suggestion.title, content: @suggestion.description, ticket_type: 'support' },
        current_user: @current_user
      )
      raise ActorError.new(result.errors, code: :ticket_creation_failed) unless result.success?

      result.resource
    end

    # Meeting→Ticket reference, exact meeting_ticket_links_controller pattern:
    # pre-check + RecordNotUnique backstop + title snapshot (truncated to the column
    # cap so it can never fail the save).
    def link_meeting_to_ticket!(ticket)
      return if @meeting.outgoing_references.exists?(target: ticket)

      @meeting.outgoing_references.create!(
        organisation: @meeting.organisation,
        target: ticket,
        target_title_snapshot: ticket.display_title&.truncate(255)
      )
    rescue ActiveRecord::RecordNotUnique
      # Race backstop: the link already exists — fine, the ticket stays linked.
      nil
    end
  end
end
