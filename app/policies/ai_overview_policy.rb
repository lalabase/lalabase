# frozen_string_literal: true

# Policy for the AI area's hub (doc/ki_bereich_navigation_plan.md S2).
#
# Same gate as every page the hub links to — AiSettingsPolicy, AiSyncStatusPolicy and
# PromptPersonaPolicy#index? are all account_admin?, which §2.4 of the plan checked
# before the area was cut: it can be a closed admin area without anyone losing a page
# they can reach today. A weaker gate here would be the one hole in that wall, because
# the hub NAMES what is behind it (package, jurisdiction, quota, backlog) even where it
# does not link.
class AiOverviewPolicy < ApplicationPolicy
  def show?
    account_admin?
  end
end
