# frozen_string_literal: true

# app/services/actors/update_time_session_group_billing.rb
#
# Tier-1 actor: updates a TimeSessionGroup including its billing-status
# transition. ONE transaction, all-or-nothing: a validation failure on the
# remaining fields rolls the billing transition back (before: silent partial
# success, plan §9.3-3 — the update return value was ignored).
#
# Billing semantics ([P1] fix, plan §9.8-4): an ABSENT :billed key (or a value
# that casts to nil, e.g. "") means "no billing change" — never an implicit
# unbilling. TimeSessionGroupBillingService stays the single-transition service
# underneath (plan §9.6); its internal transaction joins this actor's outer one
# (no requires_new, so any raise rolls everything back).
module Actors
  class UpdateTimeSessionGroupBilling < BaseActor
    def initialize(group:, params:, current_user:)
      super()
      @group = group
      @params = params.to_h.symbolize_keys # decouple from ActionController::Parameters
      @current_user = current_user
    end

    def record
      @group
    end

    def perform
      # Race defense (plan §9.8-1, parity with the T1 actors and the generate
      # actor): re-read the billing state inside the transaction. Without this,
      # a group invoiced concurrently behind a stale unbilled instance slips
      # through the no-transition path and can blank its invoice_number while
      # the presence validation still checks the stale billed? == false.
      @group.reload

      if billing_transition?
        apply_billing_transition!
        @group.update!(@params.except(:billed, :invoice_number, :billed_at))
      else
        # No transition: full update like the previous elsif branch (a present
        # billed value equals the current state; invoice edits on billed groups
        # stay allowed and keep being tracked as billed_data_changed).
        @group.update!(@params.except(:billed))
      end
    end

    private

    # [P1] fix: only an explicitly submitted, castable :billed value that
    # DIFFERS from the current state is a transition. Absent key / nil / ""
    # (casts to nil) => no billing change.
    def billing_transition?
      return false unless @params.key?(:billed)
      return false if billed_target.nil?

      billed_target != @group.billed?
    end

    # Single cast site for :billed. billing_transition? filters the nil cast
    # (absent / blank key) before apply_billing_transition! relies on the value.
    def billed_target
      return @billed_target if defined?(@billed_target)

      @billed_target = ActiveModel::Type::Boolean.new.cast(@params[:billed])
    end

    def apply_billing_transition!
      if billed_target
        TimeSessionGroupBillingService.mark_as_billed(
          @group,
          invoice_number: @params[:invoice_number],
          billed_at: @params[:billed_at].presence || Time.current
        )
      else
        TimeSessionGroupBillingService.mark_as_unbilled(@group)
      end
    end
  end
end
