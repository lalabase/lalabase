# frozen_string_literal: true

module Lalabase
  module Tools
    # Changes ONE thing on a ticket per call: its title, its status or its
    # assignees (terminal client S2, lalabase-private
    # doc/terminal_client_s2_update_ticket_plan.md). The rule, its write paths and
    # the reading of their results are Tickets::Change's, shared with
    # POST /api/v1/tickets/:id/changes (REST R3b); here stay the arguments, the
    # rights and the texts.
    #
    # The schema stays flat on purpose (no oneOf): the terminal client detects a
    # feature by the top-level properties of a schema only, so the rule lives in
    # the service.
    #
    # Errors: what the request alone decides is invalid_input; what the project's
    # state decides is refused with a reason (value_not_allowed,
    # user_not_assignable, no_status_field, validation_failed). Anything else is
    # refused with a fixed text, never the actor's message: in production that is
    # the exception message of an unexpected failure (a PostgreSQL error, say).
    #
    # Mutating (D3): a read-only PAT never reaches it. Record-mode (D7): the
    # ticket is authorized :update? before the write; a missing or unreadable
    # ticket answers kind: :empty and writes nothing.
    class UpdateTicket < Base
      MAX_ASSIGNEE_IDS = Tickets::Change::MAX_ASSIGNEE_IDS
      # The names a client may print: a key is caller text like any value, so
      # one with control characters or of any length is counted, not repeated.
      PLAIN_NAME = /\A[A-Za-z0-9_]{1,64}\z/

      # The refusals of this surface (Tickets::Change::REFUSALS), unchanged since
      # the tool's first answer.
      REFUSAL_TEXT = {
        unknown_keys: 'unknown arguments: %<names>s',
        invalid_utf8: 'arguments must be valid UTF-8',
        one_kind: 'exactly one change per call: title, status, or add_assignee_ids/remove_assignee_ids',
        **TicketTitle::REFUSAL_TEXT,
        status_not_string: 'status must be a string',
        status_empty: 'status is required',
        assignees_not_a_list: %(%<list>s must be a list of user UUIDs or "#{Tickets::Change::ME}"),
        too_many_assignees: "at most #{MAX_ASSIGNEE_IDS} user ids per list",
        assignee_invalid: 'invalid user id in %<list>s',
        no_assignees: 'add_assignee_ids or remove_assignee_ids must name at least one user',
        assignees_overlap: 'add_assignee_ids and remove_assignee_ids name the same user'
      }.freeze

      # The failures of this surface (Tickets::Change::FAILURES). Neither answer
      # repeats a value: a client prints the answer, and the value is whatever
      # the caller sent, control characters included. The allowed statuses come
      # from list_tickets. Unknown person and person without access read the
      # same, so the answer tells no existence.
      FAILURE_TEXT = {
        no_status_field: 'this project has no status field',
        status_not_allowed: 'status is not a status of this project; use a key from meta.available_statuses',
        assignee_not_allowed: 'a user in this change cannot be assigned in this project',
        user_not_assignable: 'nothing was changed: a person in this change no longer has access to this project',
        title_not_saved: 'title could not be saved',
        ticket_not_saved: 'the ticket could not be saved'
      }.freeze
      UPDATE_FAILED = 'update failed'

      # Writes on behalf of context.actor. No chat set may ever carry a mutating
      # tool, so the Runner's bar can never fire here; the declaration is kept
      # truthful anyway, so the registry guard stays a derived rule.
      def self.requires_actor?
        true
      end

      def self.mutating?
        true
      end

      def self.authorization_mode
        :record
      end

      def self.tool_name
        'update_ticket'
      end

      def self.description
        'Changes ONE thing on a ticket per call: its title, its status, or its assignees ' \
          '(add_assignee_ids and/or remove_assignee_ids; nobody else is touched). A call naming more ' \
          'than one of these is refused. Returns the ticket summary.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            ticket_id: { type: 'string', description: 'UUID of the ticket to change.' },
            title: { type: 'string',
                     description: "New title, one line, at most #{Ticket::TITLE_MAX_LENGTH} characters." },
            status: { type: 'string',
                      description: 'New status: one of the KEYS in meta.available_statuses of list_tickets ' \
                                   '(per project, e.g. "in_progress"), not a display label.' },
            add_assignee_ids: { type: 'array', items: { type: 'string' },
                                description: 'User UUIDs (or "me") to add. Everybody else stays assigned.' },
            remove_assignee_ids: { type: 'array', items: { type: 'string' },
                                   description: 'User UUIDs (or "me") to remove. Everybody else stays assigned.' }
          },
          required: %w[ticket_id]
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil?

        args = symbolized(args)
        change = Tickets::Change.parse(args, actor: context.actor, beside: %i[ticket_id])
        # The order this tool always answered in: the keys and their encoding,
        # then its own id, then the change.
        return refused(change) if change.unreadable?

        ticket_id = args[:ticket_id].to_s.strip
        return Result.invalid_input('ticket_id is required') if ticket_id.empty?
        return Result.invalid_input('invalid ticket_id format') unless ticket_id.match?(UUID_FORMAT)
        return refused(change) if change.refused?

        # Inside the read scope: a ticket the caller may not read answers like a
        # missing one (Base.readable_tickets).
        ticket = readable_tickets(context, context.project.tickets).find_by(id: ticket_id)
        return not_found(ticket_id) if ticket.nil?

        # The right the board and the head menu ask for every field.
        authorize!(context, ticket, :update?)

        outcome = change.write(ticket: ticket, project: context.project)
        return not_found(ticket_id) if outcome.gone?
        return failure(outcome) unless outcome.written?

        json_result(Tickets::Serializer.new(current_user: context.actor).summary(ticket.reload))
      end

      def self.refused(change)
        details = change.refusal_details
        details = { names: printable_names(details[:keys]) } if change.refusal == :unknown_keys
        Result.invalid_input(format(REFUSAL_TEXT.fetch(change.refusal), details))
      end
      private_class_method :refused

      def self.printable_names(keys)
        names = keys.map(&:to_s)
        plain = names.grep(PLAIN_NAME).sort
        hidden = names.size - plain.size
        (plain + (hidden.positive? ? ["#{hidden} not shown"] : [])).join(', ')
      end
      private_class_method :printable_names

      def self.failure(outcome)
        return Result.refused(UPDATE_FAILED, reason: nil) if outcome.unexpected?

        Result.refused(failure_text(outcome), reason: outcome.reason)
      end
      private_class_method :failure

      # A title's messages are the model's validation messages, read again in
      # English (the actor rendered them in the request's locale; the MCP answer
      # is English like every other tool text).
      def self.failure_text(outcome)
        messages = I18n.with_locale(:en) { outcome.messages }
        [FAILURE_TEXT.fetch(outcome.failure), messages.join(', ').presence].compact.join(': ')
      end
      private_class_method :failure_text

      def self.not_found(ticket_id)
        Result.new(content: "No ticket found for #{ticket_id}.", citations: [], kind: :empty)
      end
      private_class_method :not_found
    end
  end
end
