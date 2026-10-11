# frozen_string_literal: true

# Resolves the selection a bulk request names into ticket ids, the same way for
# the summary, the run and the undo (doc/ticket_bulk_edit_plan.md, slice 2).
#
# Two modes. `ids`: the ticked rows, every one of them checked against the
# scope the reader may see; an id outside it refuses the whole selection, it is
# never dropped silently. `all`: every hit of the list's address, resolved from
# the same relation the table paginates (ObjectListController#filtered_objects,
# handed in as a lambda so it is only built when this mode asks for it) and
# compared with the count the reader saw: a different count means the list
# changed under the reader, and nothing is written on a stale basis.
#
# The cap is enforced here for both modes; the browser shows the same number
# beside a disabled "alle N auswählen".
module Tickets
  class BulkSelection
    # The most tickets one run touches. Measured 08.09.2026 at about 1 ms per
    # ticket through the model (D5); the page maximum is 200, a saved view
    # yields at most 1 000 hits.
    MAX_TICKETS = 1_000
    MODES = %w[ids all].freeze

    Resolution = Struct.new(:ids, :error, keyword_init: true) do
      def ok?
        error.nil?
      end

      def count
        ids.size
      end
    end

    def self.call(scope:, selection:, filtered_relation: nil)
      new(scope: scope, selection: selection, filtered_relation: filtered_relation).call
    end

    # scope: the tickets the reader may see in this project (policy scoped).
    # selection: { mode:, ids: [], expected_count: } as the request sent it.
    # filtered_relation: a lambda returning the list's relation for the address.
    def initialize(scope:, selection:, filtered_relation: nil)
      @scope = scope
      @selection = normalise(selection)
      @filtered_relation = filtered_relation
    end

    def call
      case @selection[:mode]
      when 'ids' then resolve_ids
      when 'all' then resolve_all
      else refuse(:unknown_mode)
      end
    end

    private

    def resolve_ids
      ids = Array(@selection[:ids]).map(&:to_s).reject(&:blank?).uniq
      return refuse(:empty) if ids.empty?
      return refuse(:too_many) if ids.size > MAX_TICKETS

      found = @scope.where(id: ids).pluck(:id).uniq.map(&:to_s)
      return refuse(:outside_scope) if found.size != ids.size

      Resolution.new(ids: found)
    end

    def resolve_all
      return refuse(:no_list) if @filtered_relation.nil?

      # reorder drops the search's rank order, which a count of ids does not
      # need; uniq is load bearing, pluck on a relation with includes can repeat
      # an id (see calculate_and_redirect_to_object_page).
      ids = @filtered_relation.call.reorder(nil).pluck(:id).uniq.map(&:to_s)
      expected = @selection[:expected_count]
      return refuse(:list_changed) if expected.present? && expected.to_i != ids.size
      return refuse(:empty) if ids.empty?
      return refuse(:too_many) if ids.size > MAX_TICKETS

      Resolution.new(ids: ids)
    end

    def refuse(code)
      Resolution.new(ids: [], error: code)
    end

    def normalise(selection)
      raw = selection.respond_to?(:to_unsafe_h) ? selection.to_unsafe_h : (selection || {}).to_h
      raw = raw.to_h.transform_keys(&:to_s)
      { mode: raw['mode'].to_s, ids: raw['ids'], expected_count: raw['expected_count'] }
    end
  end
end
