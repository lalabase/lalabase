# frozen_string_literal: true

require 'rails_helper'

# What: Overview::PeriodHeaderComponent — the shared header + period switcher for both week widgets.
# Type: Component spec (render_inline).
# Why:  Both week widgets delegate their identical chrome here, so the tab set, the active marker,
#       the per-period refresh links and the unknown-period normalisation are tested once, here.
RSpec.describe Overview::PeriodHeaderComponent, type: :component do
  let(:organisation) { create(:organisation) }

  def render_header(period: 'this_week')
    render_inline(described_class.new(
                    organisation: organisation,
                    widget_key: 'my_week_stats',
                    period: period,
                    title_key: 'dashboard.briefing.period.title.this_week',
                    subtitle: 'KW 26',
                    frame_id: 'overview_widget_my_week_stats'
                  ))
  end

  it 'renders the title and the period subtitle' do
    render_header
    expect(page).to have_text(I18n.t('dashboard.briefing.period.title.this_week'))
    expect(page).to have_text('KW 26')
  end

  it 'renders one tab per period and marks exactly the active one' do
    render_header(period: 'this_quarter')

    Overview::TimePeriod::KEYS.each do |key|
      expect(page).to have_link(I18n.t("dashboard.briefing.period.tab.#{key}"))
    end
    expect(page).to have_css("a[aria-selected='true']", count: 1)
    expect(page).to have_css("a[aria-selected='true']", text: I18n.t('dashboard.briefing.period.tab.this_quarter'))
  end

  it 'links each tab to the widget refresh endpoint, targeting the widget frame' do
    render_header
    expect(page).to have_css(
      "a[data-turbo-frame='overview_widget_my_week_stats'][href*='period=this_month']"
    )
  end

  it 'normalises an unknown period to the default (this_week) for the active marker' do
    render_header(period: 'bogus')
    expect(page).to have_css("a[aria-selected='true']", text: I18n.t('dashboard.briefing.period.tab.this_week'))
  end
end
