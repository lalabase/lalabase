# frozen_string_literal: true

require 'rails_helper'

# What: Overview::MyMentionsComponent — the viewer's recent unread @-mentions.
# Type: Component spec (route-free empty state + limit logic; populated list -> request spec).
# Why:  Pins the configurable limit and that no mentions show the in-card empty state (always renders,
#       no permission gate — mentions are recipient-scoped).
RSpec.describe Overview::MyMentionsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def component(limit: nil)
    described_class.new(organisation: organisation, user: user,
                        briefing: instance_double(Dashboard::DailyBriefing), limit: limit)
  end

  it 'shows the empty state when there are no unread mentions' do
    render_inline(component)
    expect(page).to have_text(I18n.t('overview.mentions.empty'))
  end

  it 'honours a whitelisted item limit' do
    expect(component(limit: '20').send(:effective_limit)).to eq(20)
  end
end
