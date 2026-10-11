# frozen_string_literal: true

# Overview widget: the org's billing pipeline in HOURS (the data model has no monetary rate). Three
# stages — unbilled-loose -> in-billing (grouped) -> billed — from the org-wide Overview::PortfolioStats
# (built here, memoised so a co-rendered org_stats_cards shares the queries).
#
# Gated on time_sessions:read in any project (billing is a time-tracking concern). All-zero hours show
# the in-component empty state rather than hiding the widget.
class Overview::BillingOverviewComponent < ViewComponent::Base
  include Overview::PortfolioLinks

  # Pipeline stages in canonical left-to-right order: THE shared constant, not a copy of it. This
  # name stays because the editor's stage picker and the registry parse validate against it as their
  # whitelist (mirroring org_stats_cards' CARD_KEYS), but the list itself has one owner.
  STAGE_KEYS = TimeSession::BILLING_STATUS_FILTERS

  def initialize(organisation:, user:, briefing:, stage_keys: nil)
    @organisation = organisation
    @user = user
    # Part of the overview base_params contract; billing figures come from PortfolioStats, not the
    # briefing, but it is stored like the other overview components.
    @briefing = briefing
    @stage_keys = stage_keys
  end

  # Needs time access AND at least one selected stage (an explicit empty selection renders nothing,
  # same as org_stats_cards; the editor's empty-card guard blocks saving that — only a forged payload
  # reaches it).
  def should_render?
    Current.area_access_anywhere?(user, organisation, :time_sessions, :read) && visible_stage_keys.any?
  end

  private

  attr_reader :organisation, :user

  def stats
    @stats ||= Overview::PortfolioStats.new(organisation: organisation, user: user)
  end

  # nil stage_keys (never configured) -> all stages (default); a configured list -> that subset in the
  # canonical order.
  def visible_stage_keys
    @stage_keys.nil? ? STAGE_KEYS : (STAGE_KEYS & Array(@stage_keys).map(&:to_s))
  end

  # `accent` highlights the actionable backlog (loose unbilled) in cobalt and mutes the finished
  # (billed) end. Each stage drills down to the time-tracking list filtered to that one billing
  # status (pinned all-time, so the list matches the figure).
  ACCENTS = {
    'without_billing' => 'text-cobalt-600',
    'in_billing' => 'text-cream-900',
    'billed' => 'text-cream-500'
  }.freeze

  # Built from the constant, so a stage cannot be listed here in one order and in the picker in
  # another. `label` comes from the one owner of the three words.
  def stages
    visible_stage_keys.map do |key|
      { key: key,
        hours: stats.public_send(:"#{key}_hours"),
        accent: ACCENTS.fetch(key),
        label: helpers.time_billing_state_label(key),
        href: time_tracking_drilldown_path([key]) }
    end
  end

  # Tailwind sees these literals here, so they survive the purge. Adapts the column count to the number
  # of selected stages (1/2/3) so a reduced picker stays balanced instead of leaving empty columns.
  def grid_cols_class
    { 1 => 'grid-cols-1', 2 => 'grid-cols-2' }.fetch(stages.size, 'grid-cols-3')
  end

  def any_hours?
    stages.any? { |stage| stage[:hours].positive? }
  end
end
