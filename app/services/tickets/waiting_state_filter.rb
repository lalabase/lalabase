# frozen_string_literal: true

# The two waiting states as a yes/no condition on a ticket list: waits on an open ticket
# (waiting, "Wartet" in the bar) and holds others up (blocking, "Hält auf"), each with "ist" and "ist nicht"
# (doc/ticket_relations_plan.md, revision 4, §9). The filter bar (AdHocFilterService) and the
# saved views (SmartFolders::Filters::WaitingFilter, BlockingFilter) both ask here, so the
# negation is built once.
#
# What a state means is Tickets::Waiting's alone; this class only picks the ticket set or its
# complement within `scope`. The complement holds every ticket of the scope that is not in the
# set, done tickets included: a done ticket never waits (plan §5.1). Either way the answer is a
# subset of `scope`, so a filter can only narrow the list the reader already sees.
module Tickets
  class WaitingStateFilter
    STATES = %w[waiting blocking].freeze

    # The one value the bar's category offers and a saved rule stores: the state applies.
    FLAG_VALUE = 'true'

    def self.call(**)
      new(**).call
    end

    # present: true keeps the tickets in the state, false the rest of the scope.
    def initialize(scope:, state:, present: true)
      raise ArgumentError, "unknown waiting state #{state.inspect}" unless STATES.include?(state)

      @scope = scope
      @state = state
      @present = present
    end

    def call
      matching = Tickets::Waiting.public_send(@state, @scope)
      return matching if @present

      @scope.where.not(id: matching.unscope(:select, :order, :limit, :offset, :preload).select(:id))
    end
  end
end
