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

  it 'zeigt den Ticket-Titel vorn und darunter wer, was und wo' do
    render_inline(described_class.new(notification: notification))
    expect(page).to have_css('.inbox-row__title', text: ticket.title)
    expect(page).to have_css('.inbox-row__meta-text', text: project.name)
  end

  it 'zeigt "N neu" ab zwei ungelesenen Meldungen eines gebündelten Tickets' do
    render_inline(described_class.new(notification: notification, group_count: 5, group_unread: 3))
    expect(page).to have_css('.inbox-row__new', text: I18n.t('views.organisations.notifications.item.new_count', count: 3))
  end

  it 'zeigt KEIN "neu" bei einer einzigen ungelesenen Meldung (Punkt und fetter Titel genuegen)' do
    render_inline(described_class.new(notification: notification, group_count: 5, group_unread: 1))
    expect(page).not_to have_css('.inbox-row__new')
    expect(page).to have_css('.inbox-row--unread')
  end

  it 'markiert die Zeile als ungelesen, wenn group_unread > 0' do
    notification.update!(state: 'read', read_at: 1.hour.ago)
    render_inline(described_class.new(notification: notification, group_count: 2, group_unread: 1))
    # The app-wide unread dot (Neo::UnreadMarkerComponent), the same as in the ticket rows
    expect(page).to have_css('[data-unread-marker="dot"]')
  end

  it 'markiert die Zeile als gelesen, wenn group_unread == 0, und behaelt das Auswahlkaestchen' do
    render_inline(described_class.new(notification: notification, group_count: 2, group_unread: 0))
    expect(page).to have_css('.inbox-row:not(.inbox-row--unread)')
    expect(page).not_to have_css('[data-unread-marker]')
    expect(page).to have_css('input.inbox-row__check[data-inbox-bulk-select-target="checkbox"]')
    expect(page).to have_no_css('input.inbox-row__check[data-organisation-id], input.inbox-row__check[data-organisation-name]')
  end

  # The inbox above the organisations (AllInboxesController).
  context 'with the name of its organisation' do
    before do
      allow_any_instance_of(ApplicationController).to receive(:current_organisation).and_return(nil)
      render_inline(described_class.new(notification: notification, organisation_name: 'Nordwind GmbH'))
    end

    it 'names the organisation first in the small line' do
      expect(page.find('.inbox-row__meta-text').text).to start_with('Nordwind GmbH · ')
    end

    it 'is a plain visit of the inbox of that organisation, the full view on a narrow screen' do
      link = page.find('a.inbox-row__link')
      expect(link[:href]).to start_with("/org/#{organisation.id}/inbox?")
      expect(link[:href]).to include("notification=#{notification.id}")
      expect(link['data-turbo-frame']).to eq('_top')
      expect(link['data-inbox-master-item-lane-value']).to eq('false')
      expect(link['data-inbox-master-item-fullview-url-value']).to be_present
    end

    it 'names its organisation at the bulk checkbox, for the question of the bulk bar' do
      box = page.find('input.inbox-row__check[data-inbox-bulk-select-target="checkbox"]', visible: :all)
      expect(box['data-organisation-id']).to eq(organisation.id)
      expect(box['data-organisation-name']).to eq('Nordwind GmbH')
    end

    it 'has the row menu on the addresses of that inbox' do
      actions = page.all('.inbox-row__menu form', visible: :all).pluck(:action)
      expect(actions).to eq(["/inbox/#{notification.id}/mark_read", "/inbox/#{notification.id}/archive"])
    end
  end
end
