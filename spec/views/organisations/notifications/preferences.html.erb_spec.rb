# frozen_string_literal: true

require 'rails_helper'

# Connected-block: the configurability promise must actually reach the RENDERED
# page. The notifier-gate is tested elsewhere; this proves the preferences view
# surfaces a "Code-Index" section with per-channel toggles for the index events.
RSpec.describe 'organisations/notifications/preferences', type: :view do
  let(:organisation) { create(:organisation) }

  before do
    assign(:ticket_settings, { on_status_change: true, on_priority_change: true,
                               on_comment: true, auto_follow_created: true })
    assign(:preferences, {})
    # Drive the section off the REAL enum, so dropping index_completed/index_failed
    # from VALID_EVENT_TYPES (→ not in event_types) also turns this red.
    assign(:available_event_types, NotificationPreference.event_types.keys)
    assign(:available_channels, %w[in_app email])
    # current_organisation is a controller helper_method, not present on the bare
    # view object — bypass partial-double verification to stub it.
    without_partial_double_verification do
      allow(view).to receive(:current_organisation).and_return(organisation)
    end
    render
  end

  it 'renders the Code-Index section heading' do
    expect(rendered).to include(I18n.t('views.organisations.notifications.preferences.code_index'))
  end

  it 'renders per-channel toggles for index_completed AND index_failed' do
    %w[index_completed index_failed].each do |event|
      %w[in_app email].each do |channel|
        expect(rendered).to include("preferences[#{event}][#{channel}][enabled]")
      end
    end
  end

  it 'shows the localized event titles for the index events' do
    expect(rendered).to include(I18n.t('notifications.titles.index_completed'))
    expect(rendered).to include(I18n.t('notifications.titles.index_failed'))
  end
end
