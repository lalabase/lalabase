# frozen_string_literal: true

module Subscriptions
  # Dedups a billable User across every Organisation of ONE Account -- D4.1:
  # dedup happens exclusively within an Account's own organisations, never
  # across Accounts (a User can independently be a billable seat in unrelated
  # Accounts at the same time; that is two business relationships, not double
  # counting).
  #
  # D5: iterates organisations individually via ActsAsTenant.with_tenant,
  # deliberately NOT a raw without_tenant cross-tenant query in this
  # money-relevant path (s. feedback_without_tenant_admin_only).
  #
  # D7: NO rescue per organisation. A broken organisation propagates its error
  # loudly and blocks the count for this Account, instead of silently
  # under-billing -- a still-skipped org would only surface as a wrong invoice
  # months later.
  class SeatCounter
    def initialize(account)
      @account = account
    end

    def call
      all_billable_user_ids = @account.organisations.each_with_object([]) do |org, user_ids|
        ActsAsTenant.with_tenant(org) do
          user_ids.concat(billable_user_ids(org))
        end
      end

      # The dedup step (D4.1): the SAME user counts once, no matter how many
      # of this account's organisations they are a billable member of.
      all_billable_user_ids.uniq.count
    end

    private

    def billable_user_ids(org)
      org.memberships
         .joins(:role)
         .where(active: true, roles: { billable: true })
         .pluck(:user_id)
    end
  end
end
