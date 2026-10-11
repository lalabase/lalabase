# frozen_string_literal: true

# Tier-1 actor: moves ONE ticket into another project through Tickets::Mover,
# which owns the move (the number retry, the lost assignments and
# subscriptions, the time sessions, the activities) for this actor and for the
# bulk move alike (doc/ticket_bulk_edit_plan.md, slice 7). What the mover
# refuses becomes a coded failure here: :has_hierarchy, :conflict.
module Actors
  class MoveTicket < BaseActor
    MAX_RETRIES = Tickets::Mover::MAX_RETRIES

    def initialize(ticket:, target_project:, current_user:)
      super()
      @ticket = ticket
      @target_project = target_project
      @current_user = current_user
    end

    def record
      @ticket
    end

    # Impact data without performing the move (the dialog's preflight).
    def preflight
      mover.impact
    end

    def perform
      mover.call
    rescue Tickets::Mover::Refused => e
      raise ActorError.new(e.message, code: e.code)
    end

    private

    def mover
      @mover ||= Tickets::Mover.new(ticket: @ticket, target_project: @target_project, current_user: @current_user)
    end
  end
end
