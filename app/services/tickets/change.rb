# frozen_string_literal: true

# The one rule of a ticket change through a token: the MCP tool update_ticket
# and POST /api/v1/tickets/:id/changes both change a ticket through it, so the
# two surfaces cannot drift apart (REST R3b). ONE thing per call: the title, the
# status or the assignees. PATCH /api/v1/tickets/:id is another write on purpose:
# its assignee_ids REPLACE the list.
#
# Entry point: parse
#
# Two steps, because the callers find and authorize the ticket in between:
# `parse` refuses what the request alone decides, and `write` changes a ticket the
# caller has found readable and may write. Rights stay with the callers, this
# object holds none, and so does the wording: a refusal and a failure are names,
# each surface says them in its own words.
#
# No write path of its own, one per field:
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
# `{title: "", status: "x"}` is a mixed call, and a key the rule does not
# know is refused rather than ignored (a client that guessed `priority`
# must not read "ok"). The title rule is shared with create_ticket
# (Lalabase::Tools::TicketTitle).
module Tickets
  class Change
    MAX_ASSIGNEE_IDS = 50
    # Stands for the caller in either assignee list, as `assignee: "me"` does
    # in list_tickets.
    ME = 'me'
    ASSIGNEE_KEYS = %i[add_assignee_ids remove_assignee_ids].freeze
    KIND_KEYS = { title: %i[title], status: %i[status], assignees: ASSIGNEE_KEYS }.freeze
    KEYS = KIND_KEYS.values.flatten.freeze

    # Why `parse` turns a change away, in the order it checks: what the request
    # alone decides. Each caller words it for its surface.
    REFUSALS = [
      :unknown_keys, :invalid_utf8, :one_kind,
      *Lalabase::Tools::TicketTitle::REFUSALS,
      :status_not_string, :status_empty,
      :assignees_not_a_list, :too_many_assignees, :assignee_invalid, :no_assignees, :assignees_overlap
    ].freeze
    # The first two come before a caller's own arguments, see #unreadable?.
    UNREADABLE = %i[unknown_keys invalid_utf8].freeze

    # Why `write` changes nothing although the request was fine: what the
    # project's state decides. Each with the reason a client branches on; each
    # caller words the failure itself.
    REASONS = {
      no_status_field: :no_status_field,
      status_not_allowed: :value_not_allowed,
      assignee_not_allowed: :value_not_allowed,
      user_not_assignable: :user_not_assignable,
      title_not_saved: :validation_failed,
      ticket_not_saved: :validation_failed
    }.freeze
    FAILURES = REASONS.keys.freeze

    # The actor answers these for a status when the project has no active
    # single-select field named "status" (a multiselect gives nothing_to_change).
    NO_STATUS_FIELD_CODES = %i[unknown_field nothing_to_change unknown_kind].freeze

    # What a write came to. `failure` is nil when the change is written, :gone
    # when the ticket left the project or was deleted after the caller found it
    # (answered like a missing ticket), one of FAILURES, or :unexpected: anything
    # else, to be answered with a fixed text, because the actor's message may be
    # the exception of an unexpected failure (a PostgreSQL error, say).
    Outcome = Struct.new(:failure, :record, keyword_init: true) do
      def written?
        failure.nil?
      end

      def gone?
        failure == :gone
      end

      def unexpected?
        failure == :unexpected
      end

      def reason
        REASONS.fetch(failure)
      end

      # What the model said about a refused title, in the current locale. The
      # other failures have no messages worth repeating: the bulk actor's are a
      # generic board text.
      def messages
        return [] unless failure == :title_not_saved && record.respond_to?(:errors)

        record.errors.full_messages
      end
    end

    # `fields` are the keys of the change, symbols or strings. `beside` names
    # what the caller reads itself (the MCP tool's ticket_id): no unknown key and
    # no kind, but text like the rest.
    def self.parse(fields, actor:, beside: [])
      new(fields: fields, actor: actor, beside: beside)
    end

    attr_reader :kind, :refusal, :refusal_details

    def initialize(fields:, actor:, beside:)
      @actor = actor
      @refusal_details = {}
      @refusal = refusal_for(fields.to_h.symbolize_keys, beside)
    end

    def refused?
      !@refusal.nil?
    end

    # Refused before the fields were read: for a caller that answers these ahead
    # of its own arguments, as the MCP tool always did.
    def unreadable?
      UNREADABLE.include?(@refusal)
    end

    # => Outcome. A change the actor refuses writes nothing.
    def write(ticket:, project:)
      raise ArgumentError, "refused change: #{@refusal}" if refused?
      return Outcome.new(failure: :no_status_field) if @kind == :status && !status_field?(project)

      result = @kind == :title ? write_title(ticket, project) : write_field(ticket, project)
      # nil: the ticket left this project, or was deleted, after the lookup.
      return Outcome.new(failure: :gone) if result.nil?
      return Outcome.new if result.success?

      Outcome.new(failure: failure_of(result), record: result.resource)
    end

    private

    def refusal_for(fields, beside)
      unknown = fields.keys - KEYS - beside
      return refuse(:unknown_keys, keys: unknown) if unknown.any?
      return refuse(:invalid_utf8) unless fields.values.flat_map { |value| Array(value) }.grep(String).all? { |text| utf8?(text) }

      kinds = KIND_KEYS.select { |_kind, keys| keys.any? { |key| fields.key?(key) } }.keys
      return refuse(:one_kind) unless kinds.one?

      @kind = kinds.first
      case @kind
      when :title then read_title(fields[:title])
      when :status then read_status(fields[:status])
      else read_assignees(fields)
      end
    end

    def refuse(refusal, **details)
      @refusal_details = details
      refusal
    end

    # JSON and forms give UTF-8 (a raw invalid byte in a form or JSON body is a
    # 400 before any controller, Rails' own check). Only a multipart part (REST)
    # can name a charset of its own or none, and the title's patterns and
    # String#strip raise on those unless the text is plain ASCII.
    def utf8?(text)
      text.valid_encoding? && (text.encoding == Encoding::UTF_8 || text.ascii_only?)
    end

    def read_title(value)
      title = Lalabase::Tools::TicketTitle.read(value)
      return refuse(title, max: Ticket::TITLE_MAX_LENGTH) if title.is_a?(Symbol)

      @title = title
      nil
    end

    def read_status(value)
      return refuse(:status_not_string) unless value.is_a?(String)

      status = value.strip
      return refuse(:status_empty) if status.empty?

      @field_change = { 'field' => 'status', 'value' => status }
      nil
    end

    def read_assignees(fields)
      lists = {}
      ASSIGNEE_KEYS.each do |key|
        ids = fields.key?(key) ? user_ids(key, fields[key]) : []
        return ids if ids.is_a?(Symbol)

        lists[key] = ids
      end
      add, remove = lists.values_at(*ASSIGNEE_KEYS)
      return refuse(:no_assignees) if add.empty? && remove.empty?
      # The actor would let add win; a client that sends both has a bug, and
      # "add wins" would hide it.
      return refuse(:assignees_overlap) if add.intersect?(remove)

      @field_change = { 'field' => 'assignees', 'add' => add, 'remove' => remove }
      nil
    end

    def user_ids(key, value)
      return refuse(:assignees_not_a_list, list: key) unless value.is_a?(Array) && value.all?(String)
      return refuse(:too_many_assignees, max: MAX_ASSIGNEE_IDS) if value.size > MAX_ASSIGNEE_IDS

      ids = value.map(&:strip)
      return refuse(:assignee_invalid, list: key) unless ids.all? { |id| id == ME || Lalabase::Uuid.valid?(id) }

      # One spelling (the one Postgres hands back), so the same person in
      # capitals or without dashes is the same person in the overlap check
      # and in the actor's option list. Duplicates stay: the actor collapses
      # them (AddRemoveBase#add).
      ids.map { |id| id == ME ? @actor.id.to_s : Lalabase::Uuid.dashed(id) }
    end

    # The status field of the rule is the one list_tickets reads its keys from:
    # an active single select named "status". The bulk actor writes any active
    # field of that name, a checkbox or a date included.
    def status_field?(project)
      TicketAttributeDefinition.select_for(project, 'status').present?
    end

    def write_field(ticket, project)
      Actors::ApplyTicketChanges.call(project: project, ticket_ids: [ticket.id], changes: [@field_change],
                                      current_user: @actor)
    end

    # The row is locked in THIS project for the whole write, so SaveTicket's
    # organisation-wide lookup finds exactly this ticket: it can neither have
    # moved to a project the caller may not write nor have been deleted (and
    # then built anew).
    #
    # The caller is Current.user around the WHOLE transaction: the title
    # activity is written on commit and names Current.user, and this commit
    # comes after SaveTicket's own with_actor_context restored the previous
    # value. Current.set restores it afterwards in turn.
    def write_title(ticket, project)
      result = nil
      Current.set(user: @actor) do
        ActiveRecord::Base.transaction do
          next unless project.tickets.lock.exists?(id: ticket.id)

          result = Actors::SaveTicket.call(project: project, params: { title: @title }, id: ticket.id,
                                           current_user: @actor)
        end
      end
      result
    end

    def failure_of(result)
      code = result.code&.to_sym
      # The ticket left the project between the lookup and the actor's row lock.
      return :gone if code == :outside_scope
      return @kind == :status ? :status_not_allowed : :assignee_not_allowed if code == :value_not_allowed
      return :no_status_field if @kind == :status && NO_STATUS_FIELD_CODES.include?(code)
      return @kind == :title ? :title_not_saved : :ticket_not_saved if code == :validation_failed
      # Only a person the change ADDS is checked (Ticket#assignable_user_ids
      # keeps whoever stays assigned), so this is one who lost access after
      # the option list was read.
      return :user_not_assignable if code == :user_not_assignable

      :unexpected
    end
  end
end
