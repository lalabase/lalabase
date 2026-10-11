# frozen_string_literal: true

require 'rails_helper'

# Pagination of the inbox master list (Pagy + endless-scroll backend).
# Regression guard for the limit:50 fix (previously the Pagy default
# limit:25 wrongly took effect, because items:50 is ignored in this Pagy
# version).
RSpec.describe 'Inbox pagination', type: :request do
  # MUST come before the let! blocks so that the 120 notification creates
  # (per-record organisation lookup = no real N+1) are not scanned by
  # Prosopite. before hooks run in definition order.
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let!(:notifications) do
    ActsAsTenant.with_tenant(organisation) do
      Array.new(120) do |i|
        create(:notification,
               recipient: user, organisation: organisation,
               channel: 'in_app', state: :delivered,
               created_at: (i + 1).minutes.ago)
      end
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  def presenter
    controller.instance_variable_get(:@presenter)
  end

  it 'rendert 50 Items auf Seite 1 (nicht den Pagy-Default 25)' do
    get organisation_notifications_path(organisation), params: { state_filters: ['unread'] }
    expect(presenter.notifications.size).to eq(50)
  end

  it 'meldet weitere Seiten (pagy.next present)' do
    get organisation_notifications_path(organisation), params: { state_filters: ['unread'] }
    expect(presenter.pagy.next).to be_present
    expect(response.body).to include('data-neo-endless-scroll-has-more-value="true"')
  end

  it 'liefert Seite 2 mit den nächsten 50 Items' do
    get organisation_notifications_path(organisation),
        params: { state_filters: ['unread'], page: 2 }
    expect(presenter.notifications.size).to eq(50)
    expect(presenter.pagy.page).to eq(2)
  end

  it 'letzte Seite hat has_more=false (Endless-Scroll stoppt)' do
    get organisation_notifications_path(organisation),
        params: { state_filters: ['unread'], page: 3 }
    expect(presenter.notifications.size).to eq(20) # 120 - 2*50
    expect(presenter.pagy.next).to be_nil
    expect(response.body).to include('data-neo-endless-scroll-has-more-value="false"')
  end

  it 'enthält das Sentinel-Element für den IntersectionObserver' do
    get organisation_notifications_path(organisation), params: { state_filters: ['unread'] }
    expect(response.body).to include('data-neo-endless-scroll-target="sentinel"')
  end
end
