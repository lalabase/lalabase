# frozen_string_literal: true

require 'rails_helper'

# What: Overview::OrgStatsCardsComponent — the configurable org key-figures grid.
# Type: Component spec (render_inline; route-free, so PortfolioStats + briefing + the org primitive are stubbed).
# Why:  Pins (1) the value wiring (3 from PortfolioStats, "new activity" from the briefing); (2) the
#       card picker (only selected cards render); and (3) per-card permission — the time/tickets cards
#       are hidden from a viewer without that access, not shown as a meaningless 0.
RSpec.describe Overview::OrgStatsCardsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:briefing) { instance_double(Dashboard::DailyBriefing, new_activities_count: 7) }
  let(:portfolio) do
    instance_double(Overview::PortfolioStats,
                    active_projects_count: 4, open_tickets_count: 12, unbilled_hours: 4.5)
  end

  before do
    allow(Overview::PortfolioStats).to receive(:new).and_return(portfolio)
    allow(Current).to receive(:area_access_anywhere?).and_return(true) # all cards permitted by default
  end

  def component(card_keys: nil)
    described_class.new(organisation: organisation, user: user, briefing: briefing, card_keys: card_keys)
  end

  it 'renders all four cards by default (no selection stored)' do
    render_inline(component)
    expect(page).to have_text(I18n.t('overview.cards.active_projects'))
    expect(page).to have_text(I18n.t('overview.cards.open_tickets'))
    expect(page).to have_text(I18n.t('overview.cards.new_activities'))
    expect(page).to have_text(I18n.t('overview.cards.unbilled_hours'))
  end

  it 'shows the figures from PortfolioStats and the briefing' do
    render_inline(component)
    expect(page).to have_text('12')  # open tickets (PortfolioStats)
    expect(page).to have_text('4.5') # unbilled hours (PortfolioStats)
    expect(page).to have_text('7')   # new activity (briefing, not PortfolioStats)
  end

  it 'renders only the selected cards' do
    render_inline(component(card_keys: %w[active_projects new_activities]))
    expect(page).to have_text(I18n.t('overview.cards.active_projects'))
    expect(page).to have_text(I18n.t('overview.cards.new_activities'))
    expect(page).not_to have_text(I18n.t('overview.cards.open_tickets'))
    expect(page).not_to have_text(I18n.t('overview.cards.unbilled_hours'))
  end

  it 'does NOT show the overdue card by default (opt-in)' do
    render_inline(component)
    expect(page).not_to have_text(I18n.t('overview.cards.overdue_tickets'))
  end

  it 'renders the opt-in overdue card with its figure when selected' do
    allow(portfolio).to receive(:overdue_tickets_count).and_return(3)
    render_inline(component(card_keys: %w[overdue_tickets]))
    expect(page).to have_text(I18n.t('overview.cards.overdue_tickets'))
    expect(page).to have_text('3')
  end

  it 'does not render at all when the selection is empty' do
    expect(component(card_keys: []).should_render?).to be false
  end

  describe 'drill-down link' do
    it 'links ONLY the unbilled-hours card (exactly one), pinned all-time to its two statuses' do
      render_inline(component)
      time_links = page.all(:link).select { |a| a[:href]&.include?('time-tracking') }
      # The other figures live on other surfaces (tickets / projects / activity), so exactly one
      # time-tracking link exists — and it is the unbilled card.
      expect(time_links.size).to eq(1)
      link = time_links.first
      expect(link).to have_text(I18n.t('overview.cards.unbilled_hours'))
      # Pinned all-time (the figure is an org all-time total; the page defaults to this_month) and
      # filtered to exactly the statuses the figure sums (loose + in-billing).
      expect(link[:href]).to include('date_range=all')
      expect(link[:href]).to include('status_filters%5B%5D=without_billing')
      expect(link[:href]).to include('status_filters%5B%5D=in_billing')
    end

    it 'leaves the non-hours figures non-clickable' do
      render_inline(component(card_keys: %w[active_projects open_tickets new_activities]))
      expect(page).to have_no_link(href: /time-tracking/)
    end
  end

  describe 'card whitelist + ordering' do
    # Defense in depth: the registry parse whitelists on SAVE, but the component must ALSO drop a
    # forged key on render (a stale config, or a hand-edited payload).
    it 'drops a forged/bogus card_key (component-level whitelist)' do
      render_inline(component(card_keys: %w[bogus active_projects]))
      expect(page).to have_text(I18n.t('overview.cards.active_projects'))
      expect(page.all('.grid.grid-cols-2 > *').size).to eq(1) # only the valid card; bogus produced no tile
    end

    it 'renders cards in canonical order, not the stored order' do
      render_inline(component(card_keys: %w[unbilled_hours active_projects]))
      body = page.text
      expect(body.index(I18n.t('overview.cards.active_projects')))
        .to be < body.index(I18n.t('overview.cards.unbilled_hours'))
    end
  end

  describe 'per-card permission' do
    it 'hides the unbilled-hours card from a viewer without time access' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :time_sessions, :read).and_return(false)
      render_inline(component)
      expect(page).not_to have_text(I18n.t('overview.cards.unbilled_hours'))
      expect(page).to have_text(I18n.t('overview.cards.active_projects')) # ungated card still shows
    end

    it 'hides the open-tickets card from a viewer without tickets access' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :tickets, :read).and_return(false)
      render_inline(component)
      expect(page).not_to have_text(I18n.t('overview.cards.open_tickets'))
    end
  end
end
