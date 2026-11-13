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

  it 'keeps the rows loaded by endless scroll after repeated row actions', :inbox_e2e do
    ActsAsTenant.with_tenant(north) do
      project = Notification.find_by!(recipient: user).project
      51.times do |i|
        ticket = create(:ticket, project: project, title: "Older ticket #{i}")
        create(:notification, recipient: user, organisation: north, project: project, notifiable: ticket,
                              event_type: 'ticket_assigned', channel: 'in_app', state: :delivered,
                              created_at: (i + 1).hours.ago)
      end
    end
    visit all_inboxes_path
    expect(page).to have_css('.inbox-row', count: 50)
    sentinel = find('[data-neo-endless-scroll-target="sentinel"]')
    page.execute_script('arguments[0].scrollIntoView()', sentinel)
    expect(page).to have_css('.inbox-row', count: 53)

    row = find('.inbox-row', text: 'Older ticket 50')
    row.hover
    row.find('.inbox-row__menu summary').click
    row.click_button I18n.t('views.organisations.notifications.actions.mark_read')

    expect(page).to have_css('.inbox-row', count: 53)
    expect(page).to have_css('.inbox-row:not(.inbox-row--unread)', text: 'Older ticket 50')
    expect(page).to have_css('#inbox_master_list[data-neo-endless-scroll-page-value="2"]')
    expect(page).to have_css('.inbox-row__title', text: 'Paket fehlt')

    row = find('.inbox-row', text: 'Older ticket 50')
    row.hover
    row.find('.inbox-row__menu summary').click
    row.click_button I18n.t('views.organisations.notifications.actions.archive')

    expect(page).to have_css('.inbox-row', count: 52)
    expect(page).to have_no_css('.inbox-row__title', text: 'Older ticket 50')
    expect(page).to have_css('.inbox-row__title', text: 'Older ticket 49')
    expect(page).to have_current_path(all_inboxes_path)
  end

  # Live (S2a). The test adapter of Action Cable reaches no browser, so the
  # signal the real sender broadcast is handed to the page as the cable source
  # would: Turbo renders the stream message.
  describe 'while the page is open' do
    def deliver_signal
      stream = Notifications::Streams.all_inboxes(user)
      Notifications::UnreadSignals.call(user: user)
      payload = ActiveSupport::JSON.decode(ActionCable.server.pubsub.broadcasts(stream).last)
      page.execute_script('window.Turbo.renderStreamMessage(arguments[0])', payload)
    end

    def banner = find_by_id('all_inboxes_banner', visible: :all)

    # Read the response fully, then hold its delivery even if the request is
    # aborted. This exercises the context guard as well as cancellation.
    def hold_counts_response
      page.execute_script <<~JS
        const original = window.fetch;
        let holdNext = true;
        window.fetch = async (...args) => {
          const hold = holdNext && String(args[0]).includes('part=counts');
          if (hold) holdNext = false;
          const response = await original(...args);
          if (!hold) return response;
          const body = await response.text();
          return new Promise(resolve => {
            window.releaseInboxResponse = () => resolve(new Response(body, {
              status: response.status, headers: response.headers
            }));
            document.body.setAttribute('data-inbox-response-held', 'true');
          });
        };
        const element = document.querySelector('[data-controller="all-inboxes-live"]');
        window.Stimulus.getControllerForElementAndIdentifier(element, 'all-inboxes-live').redraw('counts');
      JS
      expect(page).to have_css('body[data-inbox-response-held="true"]')
    end

    def release_counts_response
      page.evaluate_async_script <<~JS
        const done = arguments[arguments.length - 1];
        window.releaseInboxResponse();
        requestAnimationFrame(() => requestAnimationFrame(done));
      JS
    end

    def new_south_row
      ActsAsTenant.with_tenant(south) do
        project = Notification.find_by!(recipient: user, organisation: south).project
        ticket = create(:ticket, project: project, title: 'Nach der Unterbrechung')
        create(:notification, recipient: user, organisation: south, project: project, notifiable: ticket,
                              event_type: 'ticket_assigned', channel: 'in_app', state: :delivered)
      end
    end

    it 'keeps organisation controls when an old counts response arrives after navigation' do
      visit all_inboxes_path
      expect(page).to have_css('.inbox-row', count: 2)
      hold_counts_response

      find('.inbox-row__link', text: 'Regal wackelt').click
      expect(page).to have_current_path(%r{\A/org/#{north.id}/inbox\?})
      expect(page).to have_css('[data-inbox-tool="project"]')
      release_counts_response

      expect(page).to have_css('[data-inbox-tool="project"]')
      expect(page).to have_no_css('[data-inbox-tool="organisation"]')
    end

    it 'does not restore old counts after archiving a row' do
      visit all_inboxes_path
      expect(page).to have_css('#inbox_unread_count', text: '2', exact_text: true)
      hold_counts_response

      row = find('.inbox-row', text: 'Paket fehlt')
      row.hover
      row.find('.inbox-row__menu summary').click
      row.click_button I18n.t('views.organisations.notifications.actions.archive')
      expect(page).to have_css('.inbox-row', count: 1)
      expect(page).to have_css('#inbox_unread_count', text: '1', exact_text: true)
      release_counts_response

      expect(page).to have_css('#inbox_unread_count', text: '1', exact_text: true)
    end

    it 'checks the server after cable reconnect even when no signal was received' do
      visit all_inboxes_path
      expect(page).to have_css('.inbox-row', count: 2)
      page.execute_script("document.querySelector('turbo-cable-stream-source').removeAttribute('connected')")
      new_south_row

      # The test adapter cannot replay a missed broadcast, just like the real
      # Redis adapter. Change only the connection state, not the signal target.
      page.execute_script("document.querySelector('turbo-cable-stream-source').setAttribute('connected', '')")
      expect(page).to have_css('#all_inboxes_banner', visible: :visible)
      expect(page).to have_css('#inbox_unread_count', text: '3', exact_text: true)
      expect(page).to have_css('.inbox-row', count: 2)
      within('#all_inboxes_banner') { click_button I18n.t('views.organisations.notifications.new_banner.refresh') }
      expect(page).to have_css('.inbox-row', count: 3)
      expect(page).to have_no_css('#all_inboxes_banner', visible: :visible)
    end

    it 'catches up on visibility return with equal but stale local stamps' do
      visit all_inboxes_path
      expect(page).to have_css('.inbox-row', count: 2)
      page.execute_script <<~JS
        window.inboxHidden = true;
        Object.defineProperty(document, 'hidden', { configurable: true, get: () => window.inboxHidden });
        document.dispatchEvent(new Event('visibilitychange'));
      JS
      new_south_row
      page.execute_script <<~JS
        window.inboxHidden = false;
        document.dispatchEvent(new Event('visibilitychange'));
      JS

      expect(page).to have_css('.inbox-row', count: 3)
      expect(page).to have_css('#inbox_unread_count', text: '3', exact_text: true)
      expect(page).to have_no_css('#all_inboxes_banner', visible: :visible)
    end

    it 'reads the stamp and rows from one snapshot when another connection deletes a row' do
      south_row_id = ActsAsTenant.with_tenant(south) { Notification.find_by!(recipient: user).id }
      changed = false
      allow(Notifications::InboxQuery).to receive(:stamp).and_wrap_original do |original, **arguments|
        value = original.call(**arguments)
        unless changed
          changed = true
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              ActsAsTenant.with_tenant(south) { Notification.find(south_row_id).destroy! }
            end
          end.value
        end
        value
      end

      visit all_inboxes_path

      # The deletion committed between the stamp and the list read. The initial
      # list must still match its stamp; reconciliation advertises the new state.
      expect(page).to have_css('.inbox-row', count: 2)
      expect(page).to have_css('#all_inboxes_banner', visible: :visible)
      within('#all_inboxes_banner') { click_button I18n.t('views.organisations.notifications.new_banner.refresh') }
      expect(page).to have_css('.inbox-row', count: 1)
      expect(page).to have_no_css('.inbox-row__title', text: 'Paket fehlt')
    end

    it 'counts a new notification at once and moves the list only on the banner' do
      visit all_inboxes_path
      expect(page).to have_css('.inbox-row', count: 2)
      expect(banner).not_to be_visible

      ActsAsTenant.with_tenant(south) do
        project = Notification.find_by!(recipient: user, organisation: south).project
        ticket = create(:ticket, project: project, title: 'Neu angekommen')
        create(:notification, recipient: user, organisation: south, project: project, notifiable: ticket,
                              event_type: 'ticket_assigned', channel: 'in_app', state: :delivered)
      end
      deliver_signal

      expect(page).to have_css('#all_inboxes_banner', visible: :visible)
      within('[data-all-inboxes-nav]') { expect(find('li', text: 'Suedhang AG')).to have_text('2') }
      expect(page).to have_css('.inbox-row', count: 2)
      expect(page).to have_no_css('.inbox-row__title', text: 'Neu angekommen')

      within('#all_inboxes_banner') { click_button I18n.t('views.organisations.notifications.new_banner.refresh') }

      expect(page).to have_css('.inbox-row', count: 3)
      expect(page).to have_css('.inbox-row__title', text: 'Neu angekommen')
      expect(page).to have_no_css('#all_inboxes_banner', visible: :visible)
      expect(page).to have_current_path(all_inboxes_path)
    end

    it "raises no banner for the echo of the reader's own action" do
      visit all_inboxes_path

      row = find('.inbox-row', text: 'Paket fehlt')
      row.hover
      row.find('.inbox-row__menu summary').click
      row.click_button I18n.t('views.organisations.notifications.actions.archive')
      expect(page).to have_css('.inbox-row', count: 1)

      deliver_signal

      expect(page).to have_css('#all_inboxes_signal', visible: :all)
      expect(page).to have_no_css('#all_inboxes_banner', visible: :visible)
      expect(page).to have_css('.inbox-row', count: 1)
    end
  end
end
