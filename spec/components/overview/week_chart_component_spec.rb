# frozen_string_literal: true

require 'rails_helper'

# What: Overview::WeekChartComponent — the period-aware tracked-hours bar chart.
# Type: Component spec (render_inline; DailyBriefing + the org permission primitive mocked).
# Why:  Same permission gate as WeekStats. The bars carry a label + the hours in the title (not
#       colour alone), an empty period must not divide by zero, and many-bucket periods thin labels.
RSpec.describe Overview::WeekChartComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:briefing) { instance_double(Dashboard::DailyBriefing) }

  def build_component(period: nil)
    described_class.new(organisation: organisation, user: user, briefing: briefing, period: period)
  end

  def stub_period(buckets:, period: 'this_week')
    allow(briefing).to receive(:period_hours).with(period).and_return(
      { period_key: period, title_key: "dashboard.briefing.period.title.#{period}",
        subtitle: 'KW 25', tracked: 8.0, unbilled: 3.0, buckets: buckets }
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

  it 'labels each bucket, marks the current one as "heute", and keeps the hours in the bar title' do
    stub_period(buckets: [
                  { label: 'Mo', hours: 2.0, current: false },
                  { label: 'Di', hours: 6.0, current: true }
                ])
    render_inline(build_component)

    expect(page).to have_text('Mo')
    expect(page).to have_text(I18n.t('dashboard.briefing.period.today')) # current bucket marked by label
    expect(page).to have_css("[title*='Di: 6.0']")                       # weekday still in the bar tooltip
    # "today" is a state, not money/interactive: it must NOT use the reserved cobalt accent.
    expect(page).to have_no_css('.bg-cobalt-500')
    expect(page).to have_no_css('.text-cobalt-700')
  end

  it 'survives an all-zero period without dividing by zero' do
    stub_period(buckets: Array.new(7) { { label: 'x', hours: 0.0, current: false } })
    expect { render_inline(build_component) }.not_to raise_error
  end

  it 'surfaces the busiest bucket as the chart scale peak (so a high day is not an unlabelled spike)' do
    stub_period(buckets: [
                  { label: 'Mo', hours: 2.0, current: false },
                  { label: 'Di', hours: 6.5, current: true }
                ])
    component = build_component
    expect(component.send(:max_hours)).to eq(6.5)
    render_inline(component)
    expect(page).to have_text(I18n.t('dashboard.briefing.period.peak', hours: 6.5))
  end

  it 'thins labels for a many-bucket month but always keeps first + last' do
    buckets = (1..31).map { |d| { label: d.to_s, hours: 0.0, current: false } }
    stub_period(period: 'this_month', buckets: buckets)
    render_inline(build_component(period: 'this_month'))

    expect(page).to have_text('1')
    expect(page).to have_text('31')
  end
end
