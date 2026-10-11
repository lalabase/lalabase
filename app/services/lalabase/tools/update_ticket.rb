# frozen_string_literal: true

module Lalabase
  module Tools
    # Changes ONE thing on a ticket per call: its title, its status or its
    # assignees (terminal client S2, lalabase-private
    # doc/terminal_client_s2_update_ticket_plan.md). It adds no write path of its
    # own, one per field:
    #   * status and assignees: Actors::ApplyTicketChanges with one ticket, the
    #     call the board and the head's people menu make
    #     (TicketsController#update_kanban_attribute). It writes only the status
    #     key of custom_attributes and adds/removes against the CURRENT assignees
    #     under the row lock, so "assign to me" removes nobody and a stale list in
    #     a client cannot remove anybody it did not name.
    #   * title: Actors::SaveTicket with the title alone. Never with assignee_ids
    #     (that REPLACES the list, and TicketAssignmentSync silently drops a new
    #     person who may not be assigned),
    #     never with custom_attributes. Under a lock on the ticket in THIS
    #     project: SaveTicket finds a ticket organisation-wide and builds a new
    #     one for an id it does not find, so a ticket moved or deleted after the
    #     rights check would otherwise be renamed elsewhere or created anew.
    #
    # The kind is decided by which keys are PRESENT, not by their values, so
    # `{title: "", status: "x"}` is a mixed call, and a key the tool does not
    # know is refused rather than ignored (an agent that guessed `priority`
    # must not read "ok"). The schema stays flat on purpose (no oneOf): the
    # terminal client detects a feature by the top-level properties of a schema
    # only, so the rule lives here. The title rule is shared with create_ticket
    # (TicketTitle).
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
      MAX_ASSIGNEE_IDS = 50
      # Stands for the caller in either assignee list, as `assignee: "me"` does
      # in list_tickets.
      ME = 'me'
      ASSIGNEE_KEYS = %i[add_assignee_ids remove_assignee_ids].freeze
      KIND_KEYS = { title: %i[title], status: %i[status], assignees: ASSIGNEE_KEYS }.freeze
      # Every argument the tool reads. Mcp::ToolCall strips project_id and
      # idempotency_key before the tool runs.
      KNOWN_KEYS = ([:ticket_id] + KIND_KEYS.values.flatten).freeze
      # The names a client may print: a key is caller text like any value, so
      # one with control characters or of any length is counted, not repeated.
      PLAIN_NAME = /\A[A-Za-z0-9_]{1,64}\z/

      ONE_CHANGE = 'exactly one change per call: title, status, or add_assignee_ids/remove_assignee_ids'
      UPDATE_FAILED = 'update failed'
      NO_STATUS_FIELD = 'this project has no status field'
      # The actor answers these for a status when the project has no active
      # single-select field named "status" (a multiselect gives nothing_to_change).
      NO_STATUS_FIELD_CODES = %i[unknown_field nothing_to_change unknown_kind].freeze

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
        refusal = refused_arguments(args)
        return refusal if refusal

        ticket_id = args[:ticket_id].to_s.strip
        return Result.invalid_input('ticket_id is required') if ticket_id.empty?
        return Result.invalid_input('invalid ticket_id format') unless ticket_id.match?(UUID_FORMAT)

        kinds = KIND_KEYS.select { |_kind, keys| keys.any? { |key| args.key?(key) } }.keys
        return Result.invalid_input(ONE_CHANGE) unless kinds.one?

        kind = kinds.first
        change = requested_change(kind, args, context)
        return change if change.is_a?(Result)

        # Inside the read scope: a ticket the caller may not read answers like a
        # missing one (Base.readable_tickets).
        ticket = readable_tickets(context, context.project.tickets).find_by(id: ticket_id)
        return not_found(ticket_id) if ticket.nil?

        # The right the board and the head menu ask for every field.
        authorize!(context, ticket, :update?)

        result = write(kind, change, ticket, context)
        # nil: the ticket left this project, or was deleted, after the lookup.
        return not_found(ticket_id) if result.nil?
        return failure(kind, result, ticket_id) unless result.success?

        json_result(Tickets::Serializer.new(current_user: context.actor).summary(ticket.reload))
      end

      # Unknown keys, and text that is not UTF-8 (a direct call; JSON over the
      # wire is always UTF-8), anywhere in the arguments.
      def self.refused_arguments(args)
        unknown = args.keys - KNOWN_KEYS
        return unknown_arguments(unknown) if unknown.any?

        texts = args.values.flat_map { |value| Array(value) }.grep(String)
        Result.invalid_input('arguments must be valid UTF-8') unless texts.all?(&:valid_encoding?)
      end
      private_class_method :refused_arguments

      def self.unknown_arguments(keys)
        names = keys.map(&:to_s)
        plain = names.grep(PLAIN_NAME).sort
        hidden = names.size - plain.size
        listed = plain + (hidden.positive? ? ["#{hidden} not shown"] : [])
        Result.invalid_input("unknown arguments: #{listed.join(', ')}")
      end
      private_class_method :unknown_arguments

      # The title (String), the status change or the assignee change the actor
      # takes, or the Result that refuses the request.
      def self.requested_change(kind, args, context)
        case kind
        when :title then TicketTitle.check(args[:title])
        when :status then requested_status(args[:status])
        else requested_assignees(args, context)
        end
      end
      private_class_method :requested_change

      def self.requested_status(value)
        return Result.invalid_input('status must be a string') unless value.is_a?(String)

        status = value.strip
        return Result.invalid_input('status is required') if status.empty?

        { 'field' => 'status', 'value' => status }
      end
      private_class_method :requested_status

      def self.requested_assignees(args, context)
        lists = {}
        ASSIGNEE_KEYS.each do |key|
          ids = args.key?(key) ? requested_user_ids(key, args[key], context) : []
          return ids if ids.is_a?(Result)

          lists[key] = ids
        end
        add, remove = lists.values_at(*ASSIGNEE_KEYS)
        return Result.invalid_input('add_assignee_ids or remove_assignee_ids must name at least one user') if add.empty? && remove.empty?
        # The actor would let add win; a client that sends both has a bug, and
        # "add wins" would hide it.
        return Result.invalid_input('add_assignee_ids and remove_assignee_ids name the same user') if add.intersect?(remove)

        { 'field' => 'assignees', 'add' => add, 'remove' => remove }
      end
      private_class_method :requested_assignees

      def self.requested_user_ids(key, value, context)
        return Result.invalid_input(%(#{key} must be a list of user UUIDs or "#{ME}")) unless value.is_a?(Array) && value.all?(String)
        return Result.invalid_input("at most #{MAX_ASSIGNEE_IDS} user ids per list") if value.size > MAX_ASSIGNEE_IDS

        ids = value.map(&:strip)
        return Result.invalid_input("invalid user id in #{key}") unless ids.all? { |id| id == ME || Lalabase::Uuid.valid?(id) }

        # One spelling (the one Postgres hands back), so the same person in
        # capitals or without dashes is the same person in the overlap check
        # and in the actor's option list. Duplicates stay: the actor collapses
        # them (AddRemoveBase#add).
        ids.map { |id| id == ME ? context.actor.id.to_s : Lalabase::Uuid.dashed(id) }
      end
      private_class_method :requested_user_ids

      # The actor's result, a Result the tool answers with, or nil when the
      # ticket is no longer in this project.
      def self.write(kind, change, ticket, context)
        return write_title(change, ticket, context) if kind == :title
        return Result.refused(NO_STATUS_FIELD, reason: :no_status_field) if kind == :status && !status_field?(context)

        Actors::ApplyTicketChanges.call(project: context.project, ticket_ids: [ticket.id], changes: [change],
                                        current_user: context.actor)
      end
      private_class_method :write

      # The status field of the tool's contract is the one list_tickets reads its
      # keys from: an active single select named "status". The bulk actor writes
      # any active field of that name, a checkbox or a date included.
      def self.status_field?(context)
        TicketAttributeDefinition.select_for(context.project, 'status').present?
      end
      private_class_method :status_field?

      # The row is locked in THIS project for the whole write, so SaveTicket's
      # organisation-wide lookup finds exactly this ticket: it can neither have
      # moved to a project the caller may not write nor have been deleted (and
      # then built anew).
      #
      # The caller is Current.user around the WHOLE transaction: the title
      # activity is written on commit and names Current.user, and this commit
      # comes after SaveTicket's own with_actor_context restored the previous
      # value. Current.set restores it afterwards in turn.
      def self.write_title(title, ticket, context)
        result = nil
        Current.set(user: context.actor) do
          ActiveRecord::Base.transaction do
            next unless context.project.tickets.lock.exists?(id: ticket.id)

            result = Actors::SaveTicket.call(project: context.project, params: { title: title }, id: ticket.id,
                                             current_user: context.actor)
          end
        end
        result
      end
      private_class_method :write_title

      def self.failure(kind, result, ticket_id)
        # A refusal of the tool's own (no status field).
        return result if result.is_a?(Result)

        code = result.code&.to_sym
        # The ticket left the project between the lookup and the actor's row lock.
        return not_found(ticket_id) if code == :outside_scope
        return refused_value(kind) if code == :value_not_allowed
        return Result.refused(NO_STATUS_FIELD, reason: :no_status_field) if kind == :status && NO_STATUS_FIELD_CODES.include?(code)
        return refused_validation(kind, result) if code == :validation_failed

        if code == :user_not_assignable
          # Only a person the change ADDS is checked (Ticket#assignable_user_ids
          # keeps whoever stays assigned), so this is one who lost access after
          # the option list was read.
          return Result.refused('nothing was changed: a person in this change no longer has access to this project',
                                reason: :user_not_assignable)
        end

        Result.refused(UPDATE_FAILED, reason: nil)
      end
      private_class_method :failure

      # Neither answer repeats the value: a client prints the answer, and the
      # value is whatever the caller sent, control characters included. The
      # allowed statuses come from list_tickets. Unknown person and person
      # without access read the same, so the answer tells no existence.
      def self.refused_value(kind)
        if kind == :status
          Result.refused('status is not a status of this project; use a key from meta.available_statuses',
                         reason: :value_not_allowed)
        else
          Result.refused('a user in this change cannot be assigned in this project', reason: :value_not_allowed)
        end
      end
      private_class_method :refused_value

      # SaveTicket's messages are the model's validation messages, read again in
      # English (the actor rendered them in the request's locale; the MCP answer
      # is English like every other tool text). The bulk actor's are a generic
      # board text, so a status or assignee change says only that the ticket
      # refused it.
      def self.refused_validation(kind, result)
        return Result.refused('the ticket could not be saved', reason: :validation_failed) unless kind == :title

        messages = english_messages(result.resource)
        message = ['title could not be saved', messages.join(', ').presence].compact.join(': ')
        Result.refused(message, reason: :validation_failed)
      end
      private_class_method :refused_validation

      def self.english_messages(record)
        return [] unless record.respond_to?(:errors)

        I18n.with_locale(:en) { record.errors.full_messages }
      end
      private_class_method :english_messages

      def self.not_found(ticket_id)
        Result.new(content: "No ticket found for #{ticket_id}.", citations: [], kind: :empty)
      end
      private_class_method :not_found
    end
  end
end
