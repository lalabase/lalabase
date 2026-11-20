# frozen_string_literal: true

require 'rails_helper'

# A row action of the inbox answers by redrawing the whole master list. Until
# 2026-11-20 an address with view_variant=grouped (or view_mode=grouped) got a
# different answer: the row replaced by NeoNotificationGroupedItemComponent, a
# legacy row no page rendered any more, with German texts written into the
# code. The component is gone; such an address is answered like every other.
RSpec.describe 'Notification row action: stream answer', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let!(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  def streams(action, target)
    Nokogiri::HTML5.fragment(response.body).css(%(turbo-stream[action="#{action}"][target="#{target}"]))
  end

  %w[view_variant view_mode].each do |param|
    it "redraws the master list for #{param}=grouped" do
      patch mark_read_organisation_notification_path(organisation, notification),
            params: { param => 'grouped' },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(notification.reload).to be_state_read
      expect(streams('replace', 'inbox_master_list').size).to eq(1)
      expect(streams('replace', ActionView::RecordIdentifier.dom_id(notification))).to be_empty
    end
  end

  it 'has no legacy grouped row component' do
    expect(Object.const_defined?(:NeoNotificationGroupedItemComponent)).to be(false)
  end
end
