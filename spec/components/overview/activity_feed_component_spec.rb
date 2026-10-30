# frozen_string_literal: true

require 'rails_helper'

# What: Overview::ActivityFeedComponent — the converted "activity of others" overview widget.
# Type: Component spec (render_inline; the data source DailyBriefing is mocked so the test pins the
#       PRESENTATION + the limit wiring, not the aggregation, which DailyBriefing specs already own).
# Why:  The widget must (1) always render (permission-only) and show its OWN empty state on no data,
#       so an owned-layout slot never collapses to a placeholder for a merely-empty feed; (2) only
#       override the briefing's default row count for an explicit, whitelisted configured limit.
RSpec.describe Overview::ActivityFeedComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:briefing) { instance_double(Dashboard::DailyBriefing) }

  def build_component(limit: nil)
    described_class.new(organisation: organisation, user: user, briefing: briefing, limit: limit)
  end

  describe '#should_render?' do
    it 'always renders (permission-only)' do
      expect(build_component.should_render?).to be true
    end
  end

  it 'renders the in-component empty state when there is no activity' do
    allow(briefing).to receive(:recent_activities_others).and_return([])
    render_inline(build_component)
    expect(page).to have_text(I18n.t('dashboard.briefing.sections.activity.empty'))
  end

  it 'renders a non-ticket activity row from the shared briefing' do
    group = instance_double(Dashboard::BriefingActivityGroup,
                            icon: 'pencil', css_class: 'text-cobalt-600', trackable: nil,
                            trackable_display_name: 'Some note', headline_action: 'updated',
                            secondary_count: 0, actor: nil, latest_at: 1.hour.ago)
    allow(briefing).to receive(:recent_activities_others).and_return([group])

    render_inline(build_component)
    expect(page).to have_text('Some note')
    expect(page).to have_text(I18n.t('dashboard.briefing.sections.activity.title'))
  end

  # A nameless actor is named like everywhere else, never by the part before the
  # @ of a hidden login address (User::EmailDisplay).
  it 'never names a nameless actor by a hidden login address' do
    ghost = build(:user, first_name: nil, last_name: nil, email: 'ghost-login@example.com', email_visibility: 'none')
    group = instance_double(Dashboard::BriefingActivityGroup,
                            icon: 'pencil', css_class: 'text-cobalt-600', trackable: nil,
                            trackable_display_name: 'Some note', headline_action: 'updated',
                            secondary_count: 0, actor: ghost, latest_at: 1.hour.ago)
    allow(briefing).to receive(:recent_activities_others).and_return([group])

    render_inline(build_component)

    expect(page).to have_text('Some note')
    expect(page).to have_text(I18n.t('users.unnamed'))
    expect(page).to have_no_text('ghost-login')
  end

  it 'passes an explicit whitelisted limit through to the briefing' do
    expect(briefing).to receive(:recent_activities_others).with(limit: 10).and_return([])
    render_inline(build_component(limit: 10))
  end

  it 'falls back to the briefing default when the configured limit is not whitelisted' do
    expect(briefing).to receive(:recent_activities_others).with(no_args).and_return([])
    render_inline(build_component(limit: 999))
  end
end
