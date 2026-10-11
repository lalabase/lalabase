# frozen_string_literal: true

# app/services/actors/create_group_and_assign_time_sessions.rb
#
# Tier-1 actor: creates a new (unbilled) billing group and assigns a set of time
# sessions to it — one transaction, so a guard violation in the assign step leaves
# NO orphaned group behind. Shares the assign write with AssignTimeSessionsToGroup
# through the TimeSessionGroupAssigner PORO (plan §9.8-2: no actor-in-actor
# composition). Serves the popover "create + assign" path and the create-new
# branch of time_sessions#bulk_assign_group.
#
# #outcome carries the pre-write counters for the call sites' flashes; read it
# after a successful #call via the .new(...).call form.
module Actors
  class CreateGroupAndAssignTimeSessions < BaseActor
    attr_reader :outcome

    def initialize(sessions:, name:, organisation:, current_user:)
      super()
      @sessions = sessions
      @name = name
      @organisation = organisation
      @current_user = current_user
    end

    def record
      @group
    end

    def perform
      # Both statements run inside BaseActor's transaction (it wraps #perform), so
      # if the assigner raises a billed-guard error the group creation rolls back
      # with it — no orphaned group is left behind.
      @group = TimeSessionGroup.create!(
        organisation: @organisation, name: @name, creator: @current_user, billed: false
      )
      @outcome = TimeSessionGroupAssigner.call(sessions: @sessions, group: @group)
    end
  end
end
