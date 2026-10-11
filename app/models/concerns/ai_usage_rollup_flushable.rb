# frozen_string_literal: true

# Rescues an organisation's AI consumption before `dependent: :destroy` takes it
# (T17, doc/billing_agentur_konto_plan.md §17.3b).
#
# Included in BOTH Organisation and Admin::Organisation for the same reason
# AccountAutoAssignable is: the two classes map to the same table but keep
# entirely separate callback cycles, so a callback declared on one is invisible
# to writes performed through the other. There is no organisation-destroy path
# in the app today -- this concern exists so the first one that gets built
# cannot silently delete billing history.
module AiUsageRollupFlushable
  extend ActiveSupport::Concern

  included do
    # prepend: true is load-bearing, not decoration. `has_many :ai_usages,
    # dependent: :destroy` registers its OWN before_destroy at declaration time,
    # and callbacks run in declaration order -- a plainly declared callback
    # would run after the cascade and aggregate an empty table. Pinned by
    # spec/models/ai_usage_rollup_flush_spec.rb ("runs before the cascade").
    before_destroy :flush_ai_usage_rollups, prepend: true
  end

  private

  # Deliberately WITHOUT a rescue. This runs inside the destroy transaction, so
  # a failure rolls the deletion back -- the organisation survives and can be
  # deleted again once the cause is fixed. The opposite trade (swallow the
  # error, complete the deletion) would destroy the only copy of the data.
  def flush_ai_usage_rollups
    Subscriptions::AiUsageAggregator.flush_for(organisation: self)
  end
end
