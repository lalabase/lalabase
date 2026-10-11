# frozen_string_literal: true

# Overview widget: a grid of org-wide key figures. Which cards show is user-configurable (card picker
# in the editor); the values come from the org-wide Overview::PortfolioStats (built here, memoised so a
# co-rendered billing_overview shares the queries), except "new activity" which is a today-focus figure
# read from the shared Dashboard::DailyBriefing.
#
# Per-card PERMISSION (like the project dashboard's stat cards): a card whose data is gated — open
# tickets (tickets:read), unbilled hours (time_sessions:read) — is hidden from a viewer without that
# access in any project, rather than shown as a meaningless 0. active projects / new activity carry no
# gate. The widget renders as long as at least one of the selected cards is permitted.
class Overview::OrgStatsCardsComponent < ViewComponent::Base
  include Overview::PortfolioLinks

  # Available cards in canonical display order, each with its optional permission. CARD_KEYS is the
  # whitelist the editor's card picker + the registry parse validate against.
  CARDS = {
    'active_projects' => { permission: nil },
    'open_tickets' => { permission: { area: :tickets, action: :read } },
    'overdue_tickets' => { permission: { area: :tickets, action: :read } },
    'new_activities' => { permission: nil },
    'unbilled_hours' => { permission: { area: :time_sessions, action: :read }, unit: true }
  }.freeze
  CARD_KEYS = CARDS.keys.freeze

  # Default selection for a never-configured overview. `overdue_tickets` is OPT-IN (available in the
  # card picker, not shown until the user adds it) so the default 2x2 grid is unchanged.
  DEFAULT_CARD_KEYS = %w[active_projects open_tickets new_activities unbilled_hours].freeze

  def initialize(organisation:, user:, briefing:, card_keys: nil)
    @organisation = organisation
    @user = user
    @briefing = briefing
    @card_keys = card_keys
  end

  def should_render?
    visible_card_keys.any?
  end

  private

  attr_reader :organisation, :user, :briefing

  def stats
    @stats ||= Overview::PortfolioStats.new(organisation: organisation, user: user)
  end

  # nil card_keys (never configured) -> all cards (default); a configured list -> that subset in the
  # canonical order. Then drop any card the viewer lacks permission for. An explicit empty selection
  # renders nothing (the editor's empty-card guard blocks saving that; only a forged payload reaches it).
  def visible_card_keys
    selected = @card_keys.nil? ? DEFAULT_CARD_KEYS : (CARD_KEYS & Array(@card_keys).map(&:to_s))
    selected.select { |key| card_permitted?(key) }
  end

  def card_permitted?(key)
    perm = CARDS.dig(key, :permission)
    perm.nil? || Current.area_access_anywhere?(user, organisation, perm[:area], perm[:action])
  end

  # Each card: i18n key (label resolved in the template, per convention) + value (+ hours unit flag)
  # + optional drill-down href (only the unbilled-hours card links out; see #card_href).
  def cards
    visible_card_keys.map do |key|
      { key: key, value: card_value(key), unit: CARDS.dig(key, :unit) || false, href: card_href(key) }
    end
  end

  # Only the unbilled-hours figure drills down — to the time-tracking list filtered to the same
  # billing statuses it sums (loose + in-billing), pinned to all-time so the list matches the figure.
  # The other cards belong to other surfaces (tickets / projects / activity) and stay non-clickable.
  def card_href(key)
    return unless key == 'unbilled_hours'

    time_tracking_drilldown_path(Overview::PortfolioLinks::UNBILLED_STATUS_KEYS)
  end

  def card_value(key)
    case key
    when 'active_projects' then stats.active_projects_count
    when 'open_tickets'    then stats.open_tickets_count
    when 'overdue_tickets' then stats.overdue_tickets_count
    when 'new_activities'  then briefing.new_activities_count
    when 'unbilled_hours'  then stats.unbilled_hours
    end
  end
end
