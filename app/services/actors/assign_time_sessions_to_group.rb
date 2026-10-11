# frozen_string_literal: true

# app/services/actors/assign_time_sessions_to_group.rb
#
# Tier-1 actor: assigns a set of time sessions to an EXISTING billing group. The
# write itself (two-sided billed guard + set-based update_all + pre-write counters)
# lives in the shared TimeSessionGroupAssigner PORO, so this actor and
# CreateGroupAndAssignTimeSessions cannot drift. Authorization stays at each call
# site (decision D5, plan §9.5 backlog) — the actor only writes.
#
# The pre-write counters are exposed via #outcome for the call sites' flashes;
# read them after a successful #call via the .new(...).call form (documented
# BaseActor exception, like MergeTicketAttributeOption#updated_count).
module Actors
  class AssignTimeSessionsToGroup < BaseActor
    attr_reader :outcome

    def initialize(sessions:, group:, current_user:)
      super()
      @sessions = sessions
      @group = group
      @current_user = current_user
    end

    def record
      @group
    end

    def perform
      @outcome = TimeSessionGroupAssigner.call(sessions: @sessions, group: @group)
    end
  end
end
