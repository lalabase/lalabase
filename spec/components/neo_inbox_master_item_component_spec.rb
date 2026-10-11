# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoInboxMasterItemComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation,
                            project: project, notifiable: ticket, channel: 'in_app')
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    # link_url calls helpers.current_organisation (controller method) — stub it
    # in the isolated component test.
    allow_any_instance_of(ApplicationController).to receive(:current_organisation).and_return(organisation)
  end

  it 'zeigt den dezenten Bündel-Indikator (Stack-Icon + Zahl) ab 2 Notifications' do
    render_inline(described_class.new(notification: notification, group_count: 3, group_unread: 1))
    expect(page).to have_css('i.bi-layers')
    expect(page).to have_text('3')
  end

  it 'zeigt KEINEN Indikator bei nur einer Notification' do
    render_inline(described_class.new(notification: notification, group_count: 1, group_unread: 1))
    expect(page).not_to have_css('i.bi-layers')
  end

  it 'markiert die Zeile als ungelesen, wenn group_unread > 0' do
    notification.update!(state: 'read', read_at: 1.hour.ago)
    render_inline(described_class.new(notification: notification, group_count: 2, group_unread: 1))
    # The app-wide unread dot (Neo::UnreadMarkerComponent), the same as in the ticket rows
    expect(page).to have_css('[data-unread-marker="dot"]')
  end

  it 'markiert die Zeile als gelesen, wenn group_unread == 0' do
    render_inline(described_class.new(notification: notification, group_count: 2, group_unread: 0))
    expect(page).to have_css('div.flex-shrink-0.pt-1\\.5') # the dot's column is rendered, just empty
    expect(page).not_to have_css('[data-unread-marker]')
  end
end
