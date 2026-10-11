# frozen_string_literal: true

# Policy for the AI area's "Verbrauch" page (doc/ki_bereich_navigation_plan.md S6).
#
# Same gate as the page this content came from: AiSettingsPolicy#show? is
# account_admin?, and §2.4 of the plan checked that every page of the area shares that
# gate before it was cut. Moving the quota bar, the six-month Nachweis and the token
# statistic onto a route of their own must not widen who may read them — consumption
# per action is exactly the "wer hat wann was ausgelöst" record the opt-in text
# promises only administrators get to see.
#
# ⚠️ Named after the PAGE, not after the AiUsage model. The two are unrelated: this
# policy is always invoked with an Organisation and an explicit `policy_class:`, and
# nothing authorises an AiUsage record. Should that ever change, the new policy needs a
# different name rather than a second meaning here.
class AiUsagePolicy < ApplicationPolicy
  def show?
    account_admin?
  end
end
