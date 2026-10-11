# frozen_string_literal: true

require 'rails_helper'

# What: Overview::WidgetRegistry — the org-overview widget catalogue + its registry-owned `parse:`
#       lambdas (D3), exercised through the SHARED Dashboards::LayoutEngine.build_widget.
# Type: Pure model spec (no DB).
# Why:  The editor save path runs every submitted widget through build_widget. For the overview
#       surface, settings parsing is owned by each registry entry's `parse:` lambda (not the project
#       `case`). These pin that the lambdas store only valid, whitelisted settings — so a forged
#       value can never be persisted — and that setting-less widgets parse to just key (+ units).
RSpec.describe Overview::WidgetRegistry do
  def build(params)
    Dashboards::LayoutEngine.build_widget(ActionController::Parameters.new(params), registry: described_class::WIDGETS)
  end

  it 'stores a whitelisted item limit for org_activity_feed via its parse lambda' do
    expect(build(key: 'org_activity_feed', limit: '10')).to eq('key' => 'org_activity_feed', 'limit' => 10)
  end

  it 'drops a non-whitelisted item limit (keeps the component default)' do
    expect(build(key: 'org_activity_feed', limit: '7')).to eq('key' => 'org_activity_feed')
  end

  it 'does not persist a period for my_week_chart (no settings in v1)' do
    # The chart's range selector is reserved for a later version (WeekChartComponent ignores `period`
    # today), so the registry has no :parse for it: a submitted period is dropped rather than stored
    # as an inert setting.
    expect(build(key: 'my_week_chart', period: 'this_month')).to eq('key' => 'my_week_chart')
  end

  it 'parses no settings for a setting-less overview widget' do
    expect(build(key: 'unread_summary')).to eq('key' => 'unread_summary')
  end

  describe 'projects_table selection mode' do
    # Iterate the component's own whitelist constant (the SAME set the render path enforces) so the
    # two sources can't drift: dropping a value from the parse whitelist OR from SELECTION_MODES
    # turns one of these red. (selected without project_ids stores just the mode.)
    Overview::ProjectsTableComponent::SELECTION_MODES.each do |mode|
      it "stores the whitelisted non-default mode #{mode.inspect}" do
        expect(build(key: 'projects_table', mode: mode)).to eq('key' => 'projects_table', 'mode' => mode)
      end
    end

    it 'does not persist the default "all" mode nor a forged mode' do
      expect(build(key: 'projects_table', mode: 'all')).to eq('key' => 'projects_table')
      expect(build(key: 'projects_table', mode: 'bogus')).to eq('key' => 'projects_table')
    end

    it 'stores project_ids only for the selected mode, deduped with blanks dropped' do
      expect(build(key: 'projects_table', mode: 'selected', project_ids: ['a', 'a', '', 'b'])).to eq(
        'key' => 'projects_table', 'mode' => 'selected', 'project_ids' => %w[a b]
      )
    end

    it 'preserves submission order (not sorted) so the picker order round-trips' do
      # 'b' before 'a': a `.sort.uniq` mutation would reorder to %w[a b] and this would catch it.
      expect(build(key: 'projects_table', mode: 'selected', project_ids: %w[b a b])).to eq(
        'key' => 'projects_table', 'mode' => 'selected', 'project_ids' => %w[b a]
      )
    end

    it 'ignores project_ids for every non-selected mode' do
      %w[pinned with_entries].each do |mode|
        expect(build(key: 'projects_table', mode: mode, project_ids: %w[a b])).to eq(
          'key' => 'projects_table', 'mode' => mode
        )
      end
    end

    it 'drops empty / forged (non-array) project_ids for the selected mode' do
      # all-blank array, a scalar, an explicit nil, and a forged hash param all collapse to
      # "no ids" (and never crash) — the mode is still stored.
      [['', ''], 'x', nil, { 'evil' => '1' }].each do |forged|
        expect(build(key: 'projects_table', mode: 'selected', project_ids: forged)).to eq(
          'key' => 'projects_table', 'mode' => 'selected'
        )
      end
    end
  end

  it 'stores a whitelisted item limit for the my_open_tickets / my_mentions list widgets' do
    expect(build(key: 'my_open_tickets', limit: '15')).to eq('key' => 'my_open_tickets', 'limit' => 15)
    expect(build(key: 'my_mentions', limit: '20')).to eq('key' => 'my_mentions', 'limit' => 20)
  end

  it 'drops a non-whitelisted limit on the list widgets' do
    expect(build(key: 'my_open_tickets', limit: '7')).to eq('key' => 'my_open_tickets')
  end

  it 'stores my_open_tickets group_keys whitelisted and in canonical order (alongside the limit)' do
    # bogus dropped; the stored order follows GROUP_KEYS, not the submitted order.
    expect(build(key: 'my_open_tickets', limit: '15', group_keys: %w[overdue all_open bogus])).to eq(
      'key' => 'my_open_tickets', 'limit' => 15, 'group_keys' => %w[all_open overdue]
    )
  end

  it 'drops my_open_tickets group_keys when none are valid / none submitted (default = all open)' do
    expect(build(key: 'my_open_tickets', group_keys: %w[bogus])).to eq('key' => 'my_open_tickets')
    expect(build(key: 'my_open_tickets')).to eq('key' => 'my_open_tickets')
  end

  # Whitelist positive-iteration: every selectable bucket must round-trip on its own. Shrinking
  # GROUP_KEYS (dropping a bucket) makes the dropped key fail here instead of silently never persisting.
  Overview::MyOpenTicketsComponent::GROUP_KEYS.each do |key|
    it "round-trips the individual my_open_tickets group_key #{key.inspect}" do
      expect(build(key: 'my_open_tickets', group_keys: [key])).to eq('key' => 'my_open_tickets', 'group_keys' => [key])
    end
  end

  it 'stores the my_open_tickets deduplicate flag only when explicitly enabled (opt-in)' do
    expect(build(key: 'my_open_tickets', group_keys: %w[all_open overdue], deduplicate: '1')).to eq(
      'key' => 'my_open_tickets', 'group_keys' => %w[all_open overdue], 'deduplicate' => true
    )
    # Unchecked ("0") and absent both mean off — nothing stored (matches "persist only the opt-in").
    expect(build(key: 'my_open_tickets', group_keys: %w[all_open], deduplicate: '0')).to eq(
      'key' => 'my_open_tickets', 'group_keys' => %w[all_open]
    )
    expect(build(key: 'my_open_tickets', group_keys: %w[all_open])).to eq(
      'key' => 'my_open_tickets', 'group_keys' => %w[all_open]
    )
  end

  it 'stores the my_open_tickets display_mode only for the non-default "tabs" value' do
    expect(build(key: 'my_open_tickets', display_mode: 'tabs')).to eq(
      'key' => 'my_open_tickets', 'display_mode' => 'tabs'
    )
    # The default ('sections') and any forged value are dropped — the component falls back to sections.
    expect(build(key: 'my_open_tickets', display_mode: 'sections')).to eq('key' => 'my_open_tickets')
    expect(build(key: 'my_open_tickets', display_mode: 'bogus')).to eq('key' => 'my_open_tickets')
  end

  it 'stores a whitelisted item limit for recent_notifications' do
    expect(build(key: 'recent_notifications', limit: '15')).to eq('key' => 'recent_notifications', 'limit' => 15)
  end

  it 'stores org_stats_cards card_keys whitelisted and in canonical order' do
    # bogus dropped; the stored order follows CARD_KEYS, not the submitted order.
    expect(build(key: 'org_stats_cards', card_keys: %w[unbilled_hours active_projects bogus])).to eq(
      'key' => 'org_stats_cards', 'card_keys' => %w[active_projects unbilled_hours]
    )
  end

  it 'drops org_stats_cards card_keys when none are valid / none submitted (default = all cards)' do
    expect(build(key: 'org_stats_cards', card_keys: %w[bogus])).to eq('key' => 'org_stats_cards')
    expect(build(key: 'org_stats_cards')).to eq('key' => 'org_stats_cards')
  end

  it 'stores billing_overview stage_keys whitelisted and in canonical order' do
    # bogus dropped; the stored order follows STAGE_KEYS, not the submitted order.
    expect(build(key: 'billing_overview', stage_keys: %w[billed without_billing bogus])).to eq(
      'key' => 'billing_overview', 'stage_keys' => %w[without_billing billed]
    )
  end

  it 'drops billing_overview stage_keys when none are valid / none submitted (default = all stages)' do
    expect(build(key: 'billing_overview', stage_keys: %w[bogus])).to eq('key' => 'billing_overview')
    expect(build(key: 'billing_overview')).to eq('key' => 'billing_overview')
  end

  # Whitelist positive-iteration: every allowed stage must round-trip on its own. Shrinking STAGE_KEYS
  # (dropping a stage) makes the dropped key fail here instead of silently never persisting.
  Overview::BillingOverviewComponent::STAGE_KEYS.each do |key|
    it "round-trips the individual billing_overview stage_key #{key.inspect}" do
      expect(build(key: 'billing_overview', stage_keys: [key])).to eq('key' => 'billing_overview', 'stage_keys' => [key])
    end
  end

  describe 'billing_overview settings wiring (drives the editor picker)' do
    let(:entry) { described_class::WIDGETS['billing_overview'] }

    it 'feeds stage_keys to the live preview via extra_params (reads the stage_keys field)' do
      expect(entry[:extra_params].call('stage_keys' => %w[billed])).to eq(stage_keys: %w[billed])
    end

    it 'exposes a settings panel (the _edit_slot has_settings gate keys on :extra_params)' do
      expect(entry).to have_key(:extra_params)
    end
  end

  it 'stores a per-widget width only when above the registry minimum' do
    # projects_table minimum is 4 units; 6 is above it -> stored, 4 is the default -> not stored.
    expect(build(key: 'projects_table', units: '6')).to eq('key' => 'projects_table', 'units' => 6)
    expect(build(key: 'projects_table', units: '4')).to eq('key' => 'projects_table')
  end
end
