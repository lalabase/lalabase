# frozen_string_literal: true

require 'rails_helper'

# The inbox above the organisations in a real browser: what the request spec
# (spec/requests/all_inboxes_spec.rb) cannot click. The sidebar narrows the list
# to an organisation, and a ticket row opens in the lane of this page, the lane
# of its organisation's inbox (the request: all_inboxes_lane_spec.rb).
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

  it 'narrows to an organisation from the sidebar and opens a row in the lane of this page' do
    visit all_inboxes_path

    expect(page).to have_css('.inbox-row', count: 2)
    expect(page).to have_css('.inbox-row__meta-text', text: 'Nordwind GmbH')
    expect(page).to have_css('.inbox-row__meta-text', text: 'Suedhang AG')

    within('[data-all-inboxes-nav]') { click_link 'Suedhang AG' }

    expect(page).to have_css('.inbox-row', count: 1)
    expect(page).to have_css('.inbox-row__title', text: 'Paket fehlt')

    find('.inbox-row__link', text: 'Paket fehlt').click

    expect(page).to have_css('.inbox-lane-content', text: 'Paket fehlt')
    expect(page).to have_current_path(%r{\A/inbox\?})
    expect(Rack::Utils.parse_nested_query(URI(page.current_url).query)).to include('org' => south.id, 'notification' => be_present)
    expect(page).to have_css('.inbox-row', count: 1)
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

  # The bulk bar (S2b): tick rows, mark them read or archive them, across
  # organisations. What the request spec cannot click: the question before an
  # action that crosses organisations, the selection that survives a "no", the
  # sentence that says how many rows changed, and the list state a submit takes
  # from the address of the page.
  describe 'the bulk bar' do
    let(:bar) { find('[data-inbox-bulk-select-target="bar"]', visible: :all) }

    def tick(title)
      row = find('.inbox-row', text: title)
      row.hover
      row.find('.inbox-row__check', visible: true).click
    end

    def north_row(title)
      ActsAsTenant.with_tenant(north) do
        project = Notification.find_by!(recipient: user, organisation: north).project
        ticket = create(:ticket, project: project, title: title)
        create(:notification, recipient: user, organisation: north, project: project, notifiable: ticket,
                              event_type: 'ticket_assigned', channel: 'in_app', state: :delivered)
      end
    end

    it 'asks before it archives rows of two organisations, and a "no" changes nothing' do
      visit all_inboxes_path
      tick('Regal wackelt')
      tick('Paket fehlt')
      expect(bar).to have_text('2 ausgewählt')

      question = dismiss_confirm { within(bar) { click_button I18n.t('views.organisations.notifications.bulk.archive') } }

      # The organisations in the order of their rows in the list.
      expect(question).to eq(
        I18n.t('views.all_inboxes.bulk.confirm_archive', number: 2, organisations: 'Suedhang AG und Nordwind GmbH')
      )
      expect(page).to have_css('.inbox-row', count: 2)
      expect(page).to have_checked_field(class: 'inbox-row__check', count: 2)
      expect(bar).to have_text('2 ausgewählt')
      expect(ActsAsTenant.without_tenant { Notification.where(recipient: user).pluck(:state) }).to all(eq('delivered'))

      accept_confirm { within(bar) { click_button I18n.t('views.organisations.notifications.bulk.archive') } }

      expect(page).to have_no_css('.inbox-row')
      expect(page).to have_css('#flash', text: I18n.t('flash.all_inboxes.archived', count: 2))
      expect(page).to have_css('[data-inbox-bulk-select-target="bar"]', visible: :hidden)
      expect(page).to have_current_path(all_inboxes_path)
      within('[data-all-inboxes-nav]') do
        expect(find('li', text: 'Nordwind GmbH')).to have_no_text(/\d/)
        expect(find('li', text: 'Suedhang AG')).to have_no_text(/\d/)
      end
      expect(ActsAsTenant.without_tenant { Notification.where(recipient: user).pluck(:state) }).to all(eq('archived'))
    end

    it 'acts at once inside one organisation and leaves the other rows alone' do
      north_row('Lampe flackert')
      visit all_inboxes_path
      tick('Regal wackelt')
      tick('Lampe flackert')

      # No question here: a dialog left open would fail the next step.
      within(bar) { click_button I18n.t('views.organisations.notifications.bulk.mark_read') }

      expect(page).to have_css('#flash', text: I18n.t('flash.all_inboxes.marked_read', count: 2))
      expect(page).to have_css('.inbox-row', count: 3)
      expect(page).to have_css('.inbox-row--unread', count: 1)
      expect(page).to have_css('.inbox-row--unread', text: 'Paket fehlt')
      expect(page).to have_css('#inbox_unread_count', text: '1', exact_text: true)
      expect(page).to have_no_checked_field(class: 'inbox-row__check')
    end

    # The bar lies outside the frame the search reloads: its forms were drawn
    # before the search. The submit takes the list state from the address.
    it 'keeps the search the list was narrowed by after its action' do
      north_row('Regal fehlt')
      visit all_inboxes_path
      find('[data-fb-search-open-button]').click
      find('#inbox-search').send_keys('Regal')
      expect(page).to have_css('.inbox-row', count: 2)
      expect(page).to have_no_css('.inbox-row__title', text: 'Paket fehlt')

      tick('Regal wackelt')
      within(bar) { click_button I18n.t('views.organisations.notifications.bulk.mark_read') }

      expect(page).to have_css('#flash', text: I18n.t('flash.all_inboxes.marked_read', count: 1))
      expect(page).to have_css('.inbox-row', count: 2)
      expect(page).to have_no_css('.inbox-row__title', text: 'Paket fehlt')
      expect(page).to have_css('.inbox-row--unread', count: 1)
    end

    it 'opens from "···" in the head without a hover, the way in on a phone' do
      visit all_inboxes_path
      expect(page).to have_no_css('.inbox-row__check', visible: true)

      find('.people-head summary.more-menu__trigger').click
      click_button I18n.t('views.organisations.notifications.index.select_rows')

      expect(page).to have_css('.inbox-row__check', visible: true, count: 2)
      expect(bar).to have_text('0 ausgewählt')
      within(bar) do
        expect(page).to have_button(I18n.t('views.organisations.notifications.bulk.archive'), disabled: true)
        click_button I18n.t('views.organisations.notifications.bulk.select_all')
      end
      expect(bar).to have_text('2 ausgewählt')
      expect(page).to have_checked_field(class: 'inbox-row__check', count: 2)
    end
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

      # A Turbo visit into an organisation's inbox (since S3 a ticket row opens the lane on
      # this page instead of leaving it).
      page.execute_script('window.Turbo.visit(arguments[0])',
                          organisation_notifications_path(north, state_filters: %w[read unread]))
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

    it "raises no banner for the echo of the reader's own bulk action, and keeps the ticks over a redraw" do
      visit all_inboxes_path
      [%w[Regal wackelt], %w[Paket fehlt]].each do |words|
        row = find('.inbox-row', text: words.join(' '))
        row.hover
        row.find('.inbox-row__check', visible: true).click
      end
      accept_confirm do
        within('[data-inbox-bulk-select-target="bar"]') { click_button I18n.t('views.organisations.notifications.bulk.mark_read') }
      end
      expect(page).to have_css('#flash', text: I18n.t('flash.all_inboxes.marked_read', count: 2))

      deliver_signal

      expect(page).to have_css('#all_inboxes_signal', visible: :all)
      expect(page).to have_no_css('#all_inboxes_banner', visible: :visible)

      # A change from elsewhere while a row is ticked: the banner's redraw keeps the tick.
      row = find('.inbox-row', text: 'Paket fehlt')
      row.hover
      row.find('.inbox-row__check', visible: true).click
      new_south_row
      deliver_signal
      expect(page).to have_css('#all_inboxes_banner', visible: :visible)
      within('#all_inboxes_banner') { click_button I18n.t('views.organisations.notifications.new_banner.refresh') }

      expect(page).to have_css('.inbox-row', count: 3)
      expect(page).to have_checked_field(class: 'inbox-row__check', count: 1)
      expect(find('.inbox-row', text: 'Paket fehlt')).to have_checked_field(class: 'inbox-row__check')
      expect(page).to have_css('[data-inbox-bulk-select-target="count"]', text: '1')
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

  # The lane on this page, clicked for real and in real time (plan §7, browser): the
  # session works in north, the ticket belongs to south. Reading, writing and closing
  # in the lane leave the list where it is and the session where it was.
  describe 'the lane' do
    before { allow(ChatPolicy).to receive(:assistant_gate_open?).and_return(true) }

    let(:png) { Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==') }

    let!(:south_ticket) do
      ActsAsTenant.with_tenant(south) do
        project = create(:project, organisation: south, name: 'Versand')
        create(:ticket_attribute_definition,
               project: project, name: 'status', field_type: 'select', system: true,
               options: { 'allowed_values' => [
                 { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
                 { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
               ] })
        ViewConfiguration.for_user_project(user, project).tap { |c| c.header_columns = %w[assignees status] }.save!
        ticket = create(:ticket, project: project, title: 'Karton leer', custom_attributes: { 'status' => 'Offen' })
        blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: 'karton.png', content_type: 'image/png')
        picture = Post.new(ticket: ticket, user: user, organisation: south)
        picture.content = %(<div>Foto vom Karton</div><action-text-attachment sgid="#{blob.attachable_sgid}" content-type="image/png" filename="karton.png" filesize="#{blob.byte_size}" width="1" height="1"></action-text-attachment>)
        picture.save!(validate: false)
        create(:notification, recipient: user, organisation: south, project: project, notifiable: ticket,
                              event_type: 'ticket_assigned', channel: 'in_app', state: :delivered)
        ticket
      end
    end

    def unread_count
      find('#inbox_unread_count').text.strip.to_i
    end

    it 'reads, writes and shuts in the lane, and the session stays in its organisation' do
      visit organisation_notifications_path(north, state_filters: %w[read unread])
      expect(page).to have_css('.inbox-row', text: 'Regal wackelt')

      visit all_inboxes_path(state_filters: %w[read unread])
      expect(page).to have_css('.inbox-row', count: 3)
      row = find('.inbox-row', text: 'Karton leer')
      expect(row).to have_css('[data-unread-marker]')
      before_count = unread_count

      row.find('a.inbox-row__link').click
      expect(page).to have_css('#ticket_pane .inbox-lane-content', text: 'Karton leer')
      expect(page).to have_css('.inbox-row', count: 3)
      expect(page).to have_current_path(/notification=/)
      expect(page).to have_css('#ticket_pane .lexxy-content img', wait: 10)

      # The 5 s read, in real time: the dot goes, the count drops, no banner rises.
      expect(find('.inbox-row', text: 'Karton leer')).to have_no_css('[data-unread-marker]', wait: 10)
      expect(page).to have_css('#inbox_unread_count', exact_text: (before_count - 1).to_s, wait: 10)
      expect(page).to have_css('#all_inboxes_banner', visible: :hidden)
      # The read redraws the whole list; the open row tints itself again from the address.
      expect(page).to have_css('.inbox-row.selected-row', count: 1)
      expect(page).to have_css('.inbox-row.selected-row', text: 'Karton leer')

      # A comment written in the lane shows in its timeline.
      composer = "#new-post-composer-#{south_ticket.id}"
      expect(page).to have_css("#{composer} [data-collapse-target='button']:not(.hidden)", wait: 10)
      within(composer) { click_on 'Kommentar' }
      editor = "#{composer} lexxy-editor[name='post[content]'] .lexxy-editor__content"
      expect(page).to have_css(editor, wait: 10)
      page.execute_script("document.querySelector(\"#{editor}\").focus()")
      find(editor).send_keys('Antwort von oben')
      within(composer) { find("button[type='submit']").click }
      expect(page).to have_css('#ticket_pane', text: 'Antwort von oben', wait: 10)

      expect(page).to have_no_css('#ticket_pane [data-controller~="assistant-trigger"]')

      # The status changes in the ticket's head.
      within('#ticket_pane [data-controller~="inline-status"]') do
        find('[data-action~="click->inline-status#toggle"]', match: :first).click
        find('[data-action~="click->inline-status#select"]', text: 'Erledigt').click
      end
      expect(page).to have_css('#ticket_pane [data-controller~="inline-status"]', text: 'Erledigt', wait: 10)

      # The edit surface opens on this page and its save shows in the lane.
      find('#ticket_pane a[href*="/edit"][data-turbo-frame="writing_surface"]', match: :first).click
      expect(page).to have_css('turbo-frame#writing_surface .writing-surface', wait: 10)
      find('.writing-surface input[name="ticket[title]"]').fill_in(with: 'Karton ganz leer')
      find('.writing-surface button[type="submit"]').click
      expect(page).to have_no_css('.writing-surface', wait: 10)
      expect(page).to have_css('#ticket_pane', text: 'Karton ganz leer', wait: 10)
      expect(page).to have_no_css('#ticket_pane [data-controller~="assistant-trigger"]')
      expect(page).to have_css('.inbox-row', count: 3)
      expect(page).to have_current_path(%r{\A/inbox\?})

      # The close button shuts the lane; Back opens it again.
      find('#ticket_pane [data-lane-close]').click
      expect(page).to have_css('.layout.hide-content')
      expect(page).to have_no_current_path(/notification=/)
      page.go_back
      expect(page).to have_current_path(/notification=/)
      expect(page).to have_css('#ticket_pane .inbox-lane-content', text: 'Karton ganz leer', wait: 10)

      # A reload with the lane open shows the ticket again.
      visit current_url
      expect(page).to have_css('#ticket_pane .inbox-lane-content', text: 'Karton ganz leer', wait: 10)
      expect(page).to have_css('.inbox-row', count: 3)

      # The "···" menu of the open row archives it: the head of the lane follows (review S3b round 1).
      open_row = find('.inbox-row.selected-row', text: 'Karton ganz leer')
      open_row.hover
      open_row.find('.inbox-row__menu summary').click
      open_row.click_button I18n.t('views.organisations.notifications.actions.archive')
      expect(page).to have_css('#inbox_pane_status_pills', text: I18n.t('views.organisations.notifications.actions.unarchive'),
                                                           wait: 10)
      expect(page).to have_css('#ticket_pane', text: 'Karton ganz leer')

      # The promise of plan §3.2, read where a person reads it.
      visit edit_user_preferences_path
      back = find('a', text: I18n.t('navigation.back_to_organisation'))
      expect(URI(back[:href]).path).to eq(organisation_projects_path(organisation_id: north.id))
    end

    # S4: a row about a new note of the second organisation opens beside the list of this page.
    # The note is drawn by its own controller under /org/<south>/, in a frame: the session
    # stays in the organisation it was in. Real clicks, real time for the 5 s read.
    it 'opens a note and a card of the second organisation in the lane, and the session stays in the first' do
      colleague = create(:user, first_name: 'Kai', last_name: 'Kollege')
      project = south_ticket.project
      note = ActsAsTenant.with_tenant(south) do
        create(:note, project: project, organisation: south, creator: colleague, title: 'Protokoll Versand').tap do |note|
          note.update!(content: '<div>Der Versand zieht um.</div>')
        end
      end
      note_row = project_event_row(south, project, 'note_created', recipient: user, actor: colleague, secondary: note,
                                                                   parameters: { 'note_title' => note.title }, created_at: 20.minutes.ago)
      member_row = project_event_row(south, project, 'member_added', recipient: user, actor: colleague,
                                                                     parameters: { 'user_name' => 'Mia Neu' }, created_at: 2.days.ago)

      visit organisation_notifications_path(north, state_filters: %w[read unread])
      expect(page).to have_css('.inbox-row', text: 'Regal wackelt')

      visit all_inboxes_path(state_filters: %w[read unread], view_mode: 'chronological')
      row = "[data-notification-item='#{note_row.id}']"
      expect(page).to have_css("#{row} .inbox-row__title", text: 'Protokoll Versand')
      expect(page).to have_css("#{row} [data-unread-marker]")
      rows = all('.inbox-row').size

      # A row about a new member shows its card in the lane.
      wait_for_stimulus("[data-notification-item='#{member_row.id}'] a.inbox-row__link", 'inbox-master-item')
      find("[data-notification-item='#{member_row.id}'] a.inbox-row__link").click
      card = '#ticket_pane [data-inbox-event-card="member_added"]'
      expect(page).to have_css(card, text: 'Mia Neu')
      expect(page).to have_no_css('#ticket_pane #ticket_display_frame')
      expect(page).to have_current_path(%r{\A/inbox\?.*notification=#{member_row.id}})

      # The row about the note opens the note in the same lane.
      find("#{row} a.inbox-row__link").click

      expect(page).to have_css('#ticket_pane #ticket_display_frame [data-lane-title]', text: 'Protokoll Versand')
      expect(page).to have_css('#ticket_pane #ticket_display_frame', text: 'Der Versand zieht um.')
      expect(page).to have_css('.inbox-row', count: rows)
      expect(page).to have_current_path(%r{\A/inbox\?.*notification=#{note_row.id}})
      expect(page).to have_css('#ticket_pane [data-lane-close]', count: 1)

      # The 5 s read, in real time: the dot goes and the note stays. The dot is asked for
      # in the markup (visible: :all): under the pointer the checkbox stands in its place.
      expect(page).to have_css("#{row} .inbox-row--unread [data-unread-marker]", visible: :all)
      expect(page).to have_no_css("#{row} .inbox-row--unread", wait: 10)
      expect(page).to have_no_css("#{row} [data-unread-marker]", visible: :all)
      expect(page).to have_css('#inbox_pane_status_pills', text: I18n.t('views.organisations.notifications.actions.mark_unread'))
      expect(page).to have_css('#ticket_pane #ticket_display_frame [data-lane-title]', text: 'Protokoll Versand')
      expect(page).to have_css('.inbox-row.selected-row', count: 1)

      # The lane's one close button shuts it; Back opens it again.
      find('#ticket_pane [data-lane-close]').click
      expect(page).to have_css('.layout.hide-content')
      expect(page).to have_no_current_path(/notification=/)
      page.go_back
      expect(page).to have_current_path(/notification=#{note_row.id}/)
      expect(page).to have_css('#ticket_pane #ticket_display_frame [data-lane-title]', text: 'Protokoll Versand', wait: 10)

      # The session never left the first organisation.
      visit edit_user_preferences_path
      back = find('a', text: I18n.t('navigation.back_to_organisation'))
      expect(URI(back[:href]).path).to eq(organisation_projects_path(organisation_id: north.id))
    end

    # S4b: a document of the second organisation in the lane of this page. Its preview and the
    # way back load into the lane's inner frame, under /org/<south>/, and the page stays /inbox.
    it 'opens a document of the second organisation; its preview and the way back stay in the lane' do
      colleague = create(:user, first_name: 'Kai', last_name: 'Kollege')
      project = south_ticket.project
      document = titled_document(south, project, 'Angebot Versand', creator: colleague, filename: 'angebot-versand.txt')
      document_row = project_event_row(south, project, 'document_created', recipient: user, actor: colleague, secondary: document,
                                                                           parameters: { 'document_title' => 'Angebot Versand' },
                                                                           created_at: 20.minutes.ago)
      version = ActsAsTenant.with_tenant(south) { document.current_version }

      visit organisation_notifications_path(north, state_filters: %w[read unread])
      expect(page).to have_css('.inbox-row', text: 'Regal wackelt')

      visit all_inboxes_path(state_filters: %w[read unread], view_mode: 'chronological')
      row = "[data-notification-item='#{document_row.id}']"
      expect(page).to have_css("#{row} .inbox-row__title", text: 'Angebot Versand')
      rows = all('.inbox-row').size
      wait_for_stimulus("#{row} a.inbox-row__link", 'inbox-master-item')
      find("#{row} a.inbox-row__link").click

      lane = '#ticket_pane #ticket_display_frame'
      expect(page).to have_css("#{lane} .document-content [data-lane-title]", text: 'Angebot Versand')
      expect(page).to have_current_path(%r{\A/inbox\?.*notification=#{document_row.id}})
      expect(page).to have_css('#ticket_pane [data-lane-close]', count: 1)

      find("#{lane} [data-preview-link-for='#{version.id}']").click
      expect(page).to have_css("#{lane} .document-preview [data-lane-title]", text: 'angebot-versand.txt')
      expect(page).to have_css('.inbox-row', count: rows)
      expect(URI(page.current_url).path).to eq('/inbox')
      expect(page).to have_current_path(/notification=#{document_row.id}/)

      find("#{lane} [data-lane-back-to-object]").click
      expect(page).to have_css("#{lane} .document-content [data-lane-title]", text: 'Angebot Versand')
      expect(page).to have_no_css("#{lane} .document-preview")
      expect(page).to have_css('.inbox-row', count: rows)
      expect(URI(page.current_url).path).to eq('/inbox')

      page.go_back
      expect(page).to have_current_path(/preview=#{version.id}/)
      expect(page).to have_css("#{lane} .document-preview [data-lane-title]", text: 'angebot-versand.txt')
      page.go_forward
      expect(page).to have_css("#{lane} .document-content [data-lane-title]", text: 'Angebot Versand')
      expect(page).to have_no_css("#{lane} .document-preview")
      find("#{lane} [data-preview-link-for='#{version.id}']").click
      expect(page).to have_css("#{lane} .document-preview")
      page.refresh
      expect(page).to have_css("#{lane} .document-preview [data-lane-title]", text: 'angebot-versand.txt')
      expect(page).to have_css('.inbox-row', count: rows)
      expect(URI(page.current_url).path).to eq('/inbox')

      # The session never left the first organisation.
      visit edit_user_preferences_path
      back = find('a', text: I18n.t('navigation.back_to_organisation'))
      expect(URI(back[:href]).path).to eq(organisation_projects_path(organisation_id: north.id))
    end

    # Review S3b round 2: the head and the 5 s timer of the lane redraw the list. They take the
    # list state the page's address names when they leave, as the bulk bar does, not the one
    # of the moment the lane opened.
    it 'updates the open head when the searched row is archived from its menu' do
      visit all_inboxes_path(state_filters: %w[read unread])
      find('.inbox-row', text: 'Karton leer').find('a.inbox-row__link').click
      expect(page).to have_css('#ticket_pane .inbox-lane-content', text: 'Karton leer')

      find('[data-fb-search-open-button]').click
      find('#inbox-search').send_keys('Karton')
      expect(page).to have_no_css('.inbox-row__title', text: 'Regal wackelt')
      expect(page).to have_current_path(/search=Karton/)

      # The 5 s read redraws the list in between; it keeps the search too and still names the
      # open row, so the head follows ("Als ungelesen"). Review S3b round 3; its quiet is pinned in
      # spec/javascript/controllers/pane_mark_read_delay_controller.test.js (the toast's target
      # does not exist in the layout, so a browser cannot see it either way).
      expect(find('.inbox-row', text: 'Karton leer')).to have_no_css('[data-unread-marker]', wait: 10)
      expect(page).to have_no_css('.inbox-row__title', text: 'Regal wackelt')
      expect(page).to have_css('#inbox_pane_status_pills', text: I18n.t('views.organisations.notifications.actions.mark_unread'),
                                                           wait: 10)

      searched_row = find('.inbox-row', text: 'Karton leer')
      searched_row.find('a.inbox-row__link').send_keys(:tab)
      searched_row.find('.inbox-row__menu summary').click
      searched_row.click_button I18n.t('views.organisations.notifications.actions.archive')
      expect(page).to have_css('#inbox_pane_status_pills', text: I18n.t('views.organisations.notifications.actions.unarchive'),
                                                           wait: 10)
      expect(page).to have_no_css('.inbox-row__title', text: 'Karton leer')
      expect(page).to have_no_css('.inbox-row__title', text: 'Regal wackelt')
      expect(page).to have_no_css('.inbox-row__title', text: 'Paket fehlt')
      expect(page).to have_current_path(/search=Karton/)
    end
  end
end
