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
      allow_any_instance_of(ApplicationController).to receive_messages(current_organisation: nil,
                                                                       page_above_organisations?: true)
      render_inline(described_class.new(notification: notification, organisation_name: 'Nordwind GmbH'))
    end

    it 'names the organisation first in the small line' do
      expect(page.find('.inbox-row__meta-text').text).to start_with('Nordwind GmbH · ')
    end

    # S3: a ticket row opens in the lane of /inbox, as inside an organisation; below lg the
    # click controller still opens the full view in the row's organisation.
    it 'opens in the lane of this page, the full view on a narrow screen' do
      link = page.find('a.inbox-row__link')
      expect(link[:href]).to start_with('/inbox?')
      expect(link[:href]).to include("notification=#{notification.id}")
      expect(link['data-turbo-frame']).to eq('ticket_pane')
      expect(link['data-controller']).to eq('inbox-master-item')
      expect(link.native.attributes.keys).not_to include('data-inbox-master-item-lane-value')
      expect(link['data-inbox-master-item-fullview-url-value']).to start_with("/org/#{organisation.id}/inbox/")
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

  # S4: what a row opens is Inbox::LaneKind's answer, not "is it a ticket". A row about a
  # project reports one of its events and opens in the lane like a ticket row; a subject the
  # lane does not know keeps the plain visit.
  describe 'a row about an event on a project' do
    let(:colleague) { create(:user, first_name: 'Kai', last_name: 'Kollege') }

    def event_row(action, parameters: {}, **attributes)
      project_event_row(organisation, project, action, recipient: user, actor: colleague, parameters: parameters,
                                                       activity: false, **attributes)
    end

    let(:note_row) { event_row('note_created', parameters: { 'note_title' => 'Protokoll Kickoff' }) }

    it 'opens in the lane of the inbox, with the wiring of a ticket row' do
      render_inline(described_class.new(notification: note_row))

      link = page.find('a.inbox-row__link')
      expect(link[:href]).to start_with("/org/#{organisation.id}/inbox?")
      expect(link[:href]).to include("notification=#{note_row.id}")
      expect(link['data-turbo-frame']).to eq('ticket_pane')
      expect(link['data-controller']).to eq('inbox-master-item')
      expect(link['data-action']).to eq('click->inbox-master-item#handleClick')
      expect(link['data-inbox-master-item-fullview-url-value']).to start_with("/org/#{organisation.id}/inbox/#{note_row.id}/open")
    end

    it 'opens in the lane of the page above the organisations there' do
      allow_any_instance_of(ApplicationController).to receive_messages(current_organisation: nil,
                                                                       page_above_organisations?: true)
      render_inline(described_class.new(notification: note_row, organisation_name: 'Nordwind GmbH'))

      link = page.find('a.inbox-row__link')
      expect(link[:href]).to start_with('/inbox?')
      expect(link[:href]).to include("notification=#{note_row.id}")
      expect(link['data-turbo-frame']).to eq('ticket_pane')
      expect(link['data-controller']).to eq('inbox-master-item')
    end

    it 'opens a row about an event without a display in the lane too (its card)' do
      render_inline(described_class.new(notification: event_row('member_added', parameters: { 'user_name' => 'Mia Neu' })))

      expect(page.find('a.inbox-row__link')['data-turbo-frame']).to eq('ticket_pane')
    end

    it 'keeps the plain visit for a subject the lane has no kind for' do
      person = create(:person, organisation: organisation)
      row = create(:notification, recipient: user, organisation: organisation, notifiable: person, channel: 'in_app')
      render_inline(described_class.new(notification: row))

      link = page.find('a.inbox-row__link')
      expect(link[:href]).to start_with("/org/#{organisation.id}/inbox/#{row.id}/open")
      expect(link['data-turbo-frame']).to eq('_top')
      expect(link['data-controller']).to be_nil
    end

    it 'shows the title of the note on a row that stands for one event' do
      render_inline(described_class.new(notification: note_row))

      expect(page).to have_css('.inbox-row__title', text: 'Protokoll Kickoff', exact_text: true)
      expect(page).to have_css('.inbox-row__meta-text', text: project.name)
    end

    it 'shows the name of the project on a bundle of two events' do
      render_inline(described_class.new(notification: note_row, group_count: 2, group_unread: 2))

      expect(page).to have_css('.inbox-row__title', text: project.name, exact_text: true)
      expect(page).to have_no_css('.inbox-row__title', text: 'Protokoll Kickoff')
    end

    it 'shows the name of the project on a notification that groups several events itself' do
      note_row.update!(group_count: 2)
      render_inline(described_class.new(notification: note_row))

      expect(page).to have_css('.inbox-row__title', text: project.name, exact_text: true)
    end

    it 'shows the name of the project for an event whose object has no title (a new member)' do
      render_inline(described_class.new(notification: event_row('member_added', parameters: { 'user_name' => 'Mia Neu' })))

      expect(page).to have_css('.inbox-row__title', text: project.name, exact_text: true)
    end

    it 'never titles a ticket row from its payload' do
      notification.update!(payload: { 'action' => 'post_added', 'parameters' => { 'note_title' => 'Nicht der Titel' } })
      render_inline(described_class.new(notification: notification))

      expect(page).to have_css('.inbox-row__title', text: ticket.title, exact_text: true)
    end
  end
end
