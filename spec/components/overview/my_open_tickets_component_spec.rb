# frozen_string_literal: true

require 'rails_helper'

# What: Overview::MyOpenTicketsComponent — the viewer's open tickets across the org.
# Type: Component spec (gate + route-free empty state + limit logic; populated list -> request spec).
# Why:  Pins the tickets gate, the configurable limit (shared sanitise-or-default), and that an empty
#       work-list shows the in-card empty state instead of collapsing the slot.
RSpec.describe Overview::MyOpenTicketsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def component(limit: nil)
    described_class.new(organisation: organisation, user: user,
                        briefing: instance_double(Dashboard::DailyBriefing), limit: limit)
  end

  describe '#should_render?' do
    it 'renders with tickets access in some project' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :tickets, :read).and_return(true)
      expect(component.should_render?).to be true
    end

    it 'is hidden without tickets access anywhere' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :tickets, :read).and_return(false)
      expect(component.should_render?).to be false
    end
  end

  it 'shows the empty state when the viewer has no open assigned tickets' do
    allow(Current).to receive(:area_access_anywhere?).and_return(true)
    render_inline(component)
    expect(page).to have_text(I18n.t('overview.tickets.empty'))
  end

  it 'honours a whitelisted item limit and falls back to the default otherwise' do
    expect(component(limit: '15').send(:effective_limit)).to eq(15)
    expect(component(limit: '7').send(:effective_limit)).to eq(Dashboards::LayoutEngine::DEFAULT_ITEM_LIMIT)
  end

  describe 'group buckets (due-date triage board)' do
    def grouped(group_keys)
      described_class.new(organisation: organisation, user: user,
                          briefing: instance_double(Dashboard::DailyBriefing), group_keys: group_keys)
    end

    it 'defaults to a single "all open" bucket and reads as a plain list (no sections)' do
      c = grouped(nil)
      expect(c.send(:visible_group_keys)).to eq(Overview::MyOpenTicketsComponent::DEFAULT_GROUP_KEYS)
      expect(c.multiple_groups?).to be false
    end

    it 'returns the selected buckets in canonical order and drops forged keys' do
      c = grouped(%w[overdue all_open not_a_bucket])
      expect(c.send(:visible_group_keys)).to eq(%w[all_open overdue])
      expect(c.multiple_groups?).to be true
    end

    it 'renders one labeled section per selected bucket' do
      allow(Current).to receive(:area_access_anywhere?).and_return(true)
      render_inline(grouped(%w[all_open overdue]))
      expect(page).to have_text(I18n.t('overview.my_open_tickets.group_all_open'))
      expect(page).to have_text(I18n.t('overview.my_open_tickets.group_overdue'))
    end
  end

  describe 'de-duplication across overlapping buckets' do
    # The dedup orchestration is exercised over a stubbed `ordered_scope` so it stays a fast unit test:
    # the real bucket SQL (matching_due_preset) is covered in the model specs; here we pin only the
    # ownership rule (narrowest bucket keeps the ticket) and the off-by-default behavior.
    def component(group_keys:, deduplicate:, scopes:)
      described_class.new(organisation: organisation, user: user,
                          briefing: instance_double(Dashboard::DailyBriefing),
                          group_keys: group_keys, deduplicate: deduplicate).tap do |c|
        allow(c).to receive(:effective_limit).and_return(10)
        allow(c).to receive(:ordered_scope) { |key| scopes.fetch(key) }
      end
    end

    def tickets_by_section(comp)
      comp.groups.to_h { |group| [group[:key], group[:tickets]] }
    end

    it 'orders the fill narrowest-first, independent of the display order of group_keys' do
      c = described_class.new(organisation: organisation, user: user,
                              briefing: instance_double(Dashboard::DailyBriefing),
                              group_keys: %w[all_open due_next_7_days overdue due_today due_this_week])
      expect(c.send(:fill_order, c.send(:visible_group_keys)))
        .to eq(%w[due_today due_this_week due_next_7_days overdue all_open])
    end

    it 'gives EVERY selectable bucket an explicit dedup priority (none silently sorts last)' do
      # DEDUP_PRIORITY and GROUP_KEYS are maintained separately. A bucket present in GROUP_KEYS but
      # missing from DEDUP_PRIORITY would fall back to "sorts last" (fill_order's `|| length`) and could
      # never claim a ticket under dedup. This keeps the two lists in sync.
      expect(described_class::DEDUP_PRIORITY).to match_array(described_class::GROUP_KEYS)
    end

    it 'shows each ticket only in its narrowest matching bucket when dedup is on' do
      overdue_t = instance_double(Ticket, id: 'a')
      today_t   = instance_double(Ticket, id: 'b')
      open_only = instance_double(Ticket, id: 'c')
      c = component(group_keys: %w[all_open overdue due_today], deduplicate: true,
                    scopes: { 'all_open' => [overdue_t, today_t, open_only],
                              'overdue' => [overdue_t], 'due_today' => [today_t] })

      by_section = tickets_by_section(c)
      expect(by_section['due_today']).to eq([today_t])
      expect(by_section['overdue']).to eq([overdue_t])
      # The two dated tickets were claimed by their narrower buckets, so all_open keeps only the rest.
      expect(by_section['all_open']).to eq([open_only])
    end

    it 'keeps a ticket in every matching bucket when dedup is off (default)' do
      overdue_t = instance_double(Ticket, id: 'a')
      c = component(group_keys: %w[all_open overdue], deduplicate: false,
                    scopes: { 'all_open' => [overdue_t], 'overdue' => [overdue_t] })

      by_section = tickets_by_section(c)
      expect(by_section['all_open']).to eq([overdue_t])
      expect(by_section['overdue']).to eq([overdue_t])
    end
  end

  describe 'display mode (sections vs tabs)' do
    def grouped(group_keys, **opts)
      described_class.new(organisation: organisation, user: user,
                          briefing: instance_double(Dashboard::DailyBriefing),
                          group_keys: group_keys, **opts)
    end

    it 'defaults to stacked sections' do
      expect(grouped(%w[all_open overdue]).tabs?).to be false
    end

    it 'is tabs? when display_mode is tabs, and falls back to sections for a forged value' do
      expect(grouped(%w[all_open overdue], display_mode: 'tabs').tabs?).to be true
      expect(grouped(%w[all_open], display_mode: 'bogus').tabs?).to be false
    end

    it 'forces de-duplication off in tabs mode (each pill is its own independent filter)' do
      overdue_t = instance_double(Ticket, id: 'a')
      c = grouped(%w[all_open overdue], deduplicate: true, display_mode: 'tabs')
      allow(c).to receive(:effective_limit).and_return(10)
      allow(c).to receive(:ordered_scope) { |key| { 'all_open' => [overdue_t], 'overdue' => [overdue_t] }.fetch(key) }

      by_section = c.groups.to_h { |g| [g[:key], g[:tickets]] }
      # The same ticket stays in BOTH buckets — tabs mode never deduplicates (only one is ever visible).
      expect(by_section['all_open']).to eq([overdue_t])
      expect(by_section['overdue']).to eq([overdue_t])
    end

    it 'opens on the first NON-empty bucket in tabs mode, so it never lands on an empty panel' do
      ticket = instance_double(Ticket, id: 'a')
      c = grouped(%w[all_open overdue due_today], display_mode: 'tabs')
      allow(c).to receive(:effective_limit).and_return(10)
      # all_open empty, overdue populated -> overdue (not the first key) is the default-active pill.
      allow(c).to receive(:ordered_scope) { |key| key == 'overdue' ? [ticket] : [] }

      expect(c.default_active_key).to eq('overdue')
    end

    it 'renders a pill tablist (with count badges) and shows exactly one panel on load in tabs mode' do
      allow(Current).to receive(:area_access_anywhere?).and_return(true)
      result = render_inline(grouped(%w[all_open overdue], display_mode: 'tabs'))

      expect(result.css('[data-controller="tabs"]')).to be_present
      expect(result.css('[data-tabs-target="tab"]').map { |t| t['data-tab-id'] }).to eq(%w[all_open overdue])
      # Each pill carries a count badge (one <span> per tab).
      expect(result.css('[data-tabs-target="tab"] span').size).to eq(2)

      panels = result.css('[data-tabs-target="panel"]')
      expect(panels.size).to eq(2)
      # Inactive panels must be hidden via the `hidden` CSS CLASS (not the HTML attribute): tabs_controller
      # toggles visibility with classList.toggle("hidden", ...), which can only reveal a panel hidden by
      # the class. Hiding via the attribute would leave switched-to panels stuck empty. Exactly one panel
      # (the default-active one) lacks the class on load.
      visible = panels.reject { |panel| panel['class'].to_s.split.include?('hidden') }
      expect(visible.size).to eq(1)
    end
  end
end
