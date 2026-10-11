# frozen_string_literal: true

require 'rails_helper'

# What: Overview::UnreadSummaryComponent — compact unread-count card.
# Type: Component spec (logic only; the card is a full-card link, so its render is covered with real
#       routes by the briefings request spec, per the established render_inline-without-routes rule).
# Why:  Pins that the count delegates to the shared briefing (single source).
RSpec.describe Overview::UnreadSummaryComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  it 'delegates the unread count to the shared briefing' do
    briefing = instance_double(Dashboard::DailyBriefing, unread_notifications_count: 4)
    component = described_class.new(organisation: organisation, user: user, briefing: briefing)
    expect(component.send(:unread_count)).to eq(4)
  end
end
