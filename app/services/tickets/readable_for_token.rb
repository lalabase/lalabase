# frozen_string_literal: true

# The one place that answers "which tickets can this holder find": the rows of `organisation`,
# inside the policy scope of `user`, inside the reach of `token`. Missing, foreign, unreadable
# and out of reach are all the same absence here, so a caller cannot tell them apart.
#
# It decides what can be FOUND, never the answer: no authorize, no 404, no wording. Those stay
# with the caller.
#
# token: nil is legitimate. The assistant calls the same tools as MCP and has no token; its reach
# is the person's own, which is the policy scope alone. nil therefore means "no second limit",
# and a caller that holds a token must pass it. A token's reach of nil means every project of the
# organisation, [] means none, also for an organisation outside the token.
#
# Built under `organisation` as the tenant, like TicketRelation.visible_to, and bound by
# organisation_id, so the rows and the rights do not depend on the tenant current at the call.
# ⚠️ That holds for the rows only: a preload chained onto the relation runs at execution, under
# the tenant current THEN, and finds nothing under another one. The caller runs the query inside
# ActsAsTenant.with_tenant(organisation).
module Tickets
  class ReadableForToken
    def self.call(**)
      new(**).call
    end

    def initialize(user:, organisation:, relation: Ticket, token: nil)
      @user = user
      @organisation = organisation
      @relation = relation
      @token = token
    end

    def call
      ActsAsTenant.with_tenant(@organisation) do
        readable = Pundit.policy_scope!(@user, @relation.where(organisation_id: @organisation.id))
        within_reach(readable)
      end
    end

    private

    def within_reach(readable)
      return readable if @token.nil?

      reached = @token.reach.project_ids_for(@organisation.id)
      reached.nil? ? readable : readable.where(project_id: reached)
    end
  end
end
