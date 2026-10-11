# frozen_string_literal: true

# Overview widget: the "what others did in your projects" feed. A thin presentation wrapper around
# the SHARED Dashboard::DailyBriefing#recent_activities_others (already Policy::Scope-gated and
# notification-deduped) — the component adds no data logic of its own, it only renders.
#
# WHY should_render? is unconditionally true (permission-only, no "no data" gate): the feed is
# org-wide ambient and self-scopes via DailyBriefing, so visibility is not a permission question.
# An empty result renders the IN-COMPONENT empty state, never a hidden widget — otherwise an
# owned-layout slot would wrongly collapse to a placeholder just because the feed happens to be empty
# right now (see the owned/placeholder rule in dashboard_row_slots).
class Overview::ActivityFeedComponent < ViewComponent::Base
  # `briefing` is the single DailyBriefing instance built once per request (briefings#show) and
  # injected via the overview base_params, so every converted widget shares its memoised aggregates.
  def initialize(organisation:, user:, briefing:, limit: nil)
    @organisation = organisation
    @user = user
    @briefing = briefing
    @limit = limit
  end

  def should_render?
    true
  end

  private

  attr_reader :organisation, :user, :briefing

  # Only override the briefing's own default row count when the user configured an explicit,
  # whitelisted limit — otherwise keep today's behaviour (DailyBriefing's built-in default).
  def activity_groups
    @activity_groups ||=
      if (limit = Dashboards::LayoutEngine.sanitized_item_limit(@limit))
        briefing.recent_activities_others(limit: limit)
      else
        briefing.recent_activities_others
      end
  end

  # Above this count the lane collapses with a "show more" toggle (neo-lane-expand), as on the
  # original briefing page.
  def lane_threshold
    10
  end

  def current_organisation
    organisation
  end
end
