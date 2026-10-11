# frozen_string_literal: true

# Policy for the AI area's protocol page (doc/ki_bereich_navigation_plan.md S5).
#
# Same gate as every other page of the area — AiOverviewPolicy, AiSettingsPolicy,
# AiSyncStatusPolicy and PromptPersonaPolicy#index? are all account_admin?, which §2.4
# of the plan checked before the area was cut: it can be a closed admin area without
# anyone losing a page they can reach today.
#
# The protocol has its own reason for the same answer, and it points the other way than
# one might expect. The page names who changed the AI configuration and when, which is
# personal data about colleagues, and it exposes the jurisdiction history of the
# organisation. It is evidence for the AVV, not a team activity feed — so it belongs to
# the people who answer for that record, not to everyone who can see the trail's
# effects.
class AiProtocolPolicy < ApplicationPolicy
  def show?
    account_admin?
  end
end
