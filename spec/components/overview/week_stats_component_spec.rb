# frozen_string_literal: true

require 'rails_helper'

# What: Overview::WeekStatsComponent — the period-aware tracked/unbilled hours widget.
# Type: Component spec (render_inline; DailyBriefing + the org permission primitive mocked).
# Why:  It IS permission-gated (time tracking). On top of the figures it now renders the period
#       switcher tabs and links the card into "Zeiten" for the SAME period + only my sessions.
RSpec.describe Overview::WeekStatsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:briefing) { instance_double(Dashboard::DailyBriefing) }

  def build_component(period: nil)
    described_class.new(organisation: organisation, user: user, briefing: briefing, period: period)
  end

  def stub_period(period: 'this_week', tracked: 8.0, unbilled: 3.0)
    allow(briefing).to receive(:period_hours).with(period).and_return(
      { period_key: period, title_key: "dashboard.briefing.period.title.#{period}",
        subtitle: 'KW 25', tracked: tracked, unbilled: unbilled, buckets: [] }
    )
  end

  before { allow(Current).to receive(:area_access_anywhere?).and_return(true) }

  describe '#should_render?' do
    it 'renders when the viewer has time access in any project' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :time_sessions, :read).and_return(true)
      expect(build_component.should_render?).to be true
    end

    it 'is hidden when the viewer has no time access anywhere' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :time_sessions, :read).and_return(false)
      expect(build_component.should_render?).to be false
    end
  end

  it 'renders the tracked + unbilled hours from the shared briefing' do
    stub_period(tracked: 8.0, unbilled: 3.0)
    render_inline(build_component)

    expect(page).to have_text('8.0')
    expect(page).to have_text(I18n.t('dashboard.briefing.week.tracked_label'))
    expect(page).to have_text('38%') # 3.0 / 8.0
  end

  it 'renders a tab for every period, the active one marked' do
    stub_period(period: 'this_week')
    render_inline(build_component(period: 'this_week'))

    Overview::TimePeriod::KEYS.each do |key|
      expect(page).to have_link(I18n.t("dashboard.briefing.period.tab.#{key}"))
    end
    expect(page).to have_css("a[aria-selected='true']", text: I18n.t('dashboard.briefing.period.tab.this_week'))
  end

  it 'links the card into the time-sessions drill-down for the period + me + sum' do
    stub_period(period: 'this_month')
    render_inline(build_component(period: 'this_month'))

    expect(page).to have_css("a[href*='date_range=this_month']")
    expect(page).to have_css("a[href*='creator_id=#{user.id}']")
  end

  it 'falls back to the per-user stored period when none is passed' do
    user.preference_store.set_overview_widget_period('my_week_stats', 'this_quarter')
    stub_period(period: 'this_quarter')

    render_inline(build_component) # no explicit period

    expect(page).to have_css("a[aria-selected='true']", text: I18n.t('dashboard.briefing.period.tab.this_quarter'))
  end
end
