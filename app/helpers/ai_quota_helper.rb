# frozen_string_literal: true

# THE single source for the AI/quota display state (plan §4.6). The three states
# (off / exhausted / degraded) plus the two intermediate credit states are derived
# here and rendered by the shared shared/ai/* partials — no view re-derives them,
# so the bar, the banners and the search hint can never disagree with the gate.
module AiQuotaHelper
  # Warn once consumption reaches this % of the monthly budget.
  AI_QUOTA_WARN_PERCENT = 80

  # :off       — AI opt-in not active (Paket A)
  # :within    — under budget (normal); :grace — over budget, on the buffer
  # :exhausted — hard limit reached (gate blocks new calls)
  #
  # Pass an already-resolved `ledger` to reuse it (the consumption bar does) so the
  # page doesn't run the `used` sum twice; it defaults to a fresh ledger otherwise.
  def ai_quota_state(organisation, ledger = nil)
    return :off unless organisation&.ai_enabled?

    (ledger || organisation.ai_quota_ledger).state
  end

  # Fill colour for the consumption bar, shared by the bar + the banners. Cobalt =
  # active/"money" per the design system; amber = grace; red = exhausted.
  def ai_quota_fill_class(state)
    case state
    when :exhausted then 'bg-red-500'
    when :grace then 'bg-amber-500'
    else 'bg-cobalt-500'
    end
  end

  # True once the org should see the 80% pre-warning (still within budget).
  def ai_quota_warn?(ledger)
    ledger.within_budget? && ledger.usage_percent >= AI_QUOTA_WARN_PERCENT
  end
end
