# frozen_string_literal: true

require 'rails_helper'

# The inbox above the organisations in a real browser: what the request spec
# (spec/requests/all_inboxes_spec.rb) cannot click. The sidebar narrows the list
# to an organisation, and a row leaves for the inbox of ITS organisation, where
# the ticket stands open in the lane.
RSpec.describe 'Inbox above the organisations (System)', type: :system do
  # The full-page renders repeat lookups per row; not the scope of this spec.
  before { Prosopite.pause }
  after  { Prosopite.resume }

  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }

  def row_in(org, title)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, role: create(:admin_role, organisation: org), active: true)
      project = create(:project, organisation: org)
      ticket = create(:ticket, project: project, title: title)
      create(:notification, recipient: user, organisation: org, project: project, notifiable: ticket,
                            event_type: 'ticket_assigned', channel: 'in_app', state: :delivered)
    end
  end

  before do
    row_in(north, 'Regal wackelt')
    row_in(south, 'Paket fehlt')
    login_as(user, scope: :user)
    page.current_window.resize_to(1440, 1000)
  end

  it 'narrows to an organisation from the sidebar and opens a row in the inbox of its organisation' do
    visit all_inboxes_path

    expect(page).to have_css('.inbox-row', count: 2)
    expect(page).to have_css('.inbox-row__meta-text', text: 'Nordwind GmbH')
    expect(page).to have_css('.inbox-row__meta-text', text: 'Suedhang AG')

    within('[data-all-inboxes-nav]') { click_link 'Suedhang AG' }

    expect(page).to have_css('.inbox-row', count: 1)
    expect(page).to have_css('.inbox-row__title', text: 'Paket fehlt')

    find('.inbox-row__link', text: 'Paket fehlt').click

    expect(page).to have_current_path(%r{\A/org/#{south.id}/inbox\?})
    expect(page).to have_css('.inbox-lane-content', text: 'Paket fehlt')
  end

  # The "···" of a row acts in place: the row leaves the unread view, the counts
  # follow, and the reader is still on the page above the organisations.
  it 'archives a row from its menu and stays on the page' do
    visit all_inboxes_path

    row = find('.inbox-row', text: 'Paket fehlt')
    row.hover
    row.find('.inbox-row__menu summary').click
    row.click_button I18n.t('views.organisations.notifications.actions.archive')

    expect(page).to have_css('.inbox-row', count: 1)
    expect(page).to have_no_css('.inbox-row__title', text: 'Paket fehlt')
    expect(page).to have_current_path(all_inboxes_path)
    within('[data-all-inboxes-nav]') do
      expect(find('li', text: 'Suedhang AG')).to have_no_css('[class*="unread"]', text: '1')
      expect(find('li', text: 'Nordwind GmbH')).to have_text('1')
    end

    visit all_inboxes_path(state_filters: %w[archived])
    expect(page).to have_css('.inbox-row__title', text: 'Paket fehlt')
  end
end
