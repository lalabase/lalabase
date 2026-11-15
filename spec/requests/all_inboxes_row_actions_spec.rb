# frozen_string_literal: true

require 'rails_helper'

# What: the actions on a row of the inbox above the organisations (PATCH
#       /inbox/:id/mark_read, mark_unread, archive, unarchive): the "···" menu of a
#       row acts in place, on the row and the other notifications about the same
#       subject, and the list stays the one the reader was looking at.
# Why:  the page reads across tenants, and so does this write. Everything it must
#       NOT reach is pinned here: another person's row, a row in a lost project or
#       a left organisation, a mail row, the same subject in another organisation.
#       And an action on a row of organisation B must not move the organisation
#       the session works in, which every address under /org/:id would.
#       The same menu inside an organisation: spec/requests/inbox_row_actions_spec.rb.
RSpec.describe 'Row actions of the inbox above the organisations', :ci_guard, :real_transactions, type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }

  def project_in(org, **attributes)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org, **attributes) }
  end

  def ticket_in(org, project, title)
    ActsAsTenant.with_tenant(org) { create(:ticket, project: project, title: title) }
  end

  def row(org, project, ticket, recipient: user, state: :delivered, channel: 'in_app', created_at: Time.current)
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: recipient, organisation: org, project: project, notifiable: ticket,
                            event_type: 'ticket_commented', channel: channel, state: state, created_at: created_at,
                            read_at: %i[read archived].include?(state) ? 1.hour.ago : nil,
                            archived_at: state == :archived ? 1.hour.ago : nil)
    end
  end

  let(:north_project) { project_in(north, name: 'Lager') }
  let(:south_project) { project_in(south, name: 'Versand') }
  let(:north_ticket) { ticket_in(north, north_project, 'Regal wackelt') }
  let(:south_ticket) { ticket_in(south, south_project, 'Paket fehlt') }

  let!(:north_row) do
    Prosopite.pause do
      make_token_owner_a_member(user, north, projects: [north_project])
      row(north, north_project, north_ticket, created_at: 2.hours.ago)
    end
  end
  # A second notification about the same ticket: one ticket is one row.
  let!(:north_sibling) { Prosopite.pause { row(north, north_project, north_ticket, created_at: 3.hours.ago) } }
  let!(:south_row) do
    Prosopite.pause do
      make_token_owner_a_member(user, south, projects: [south_project])
      row(south, south_project, south_ticket, created_at: 1.hour.ago)
    end
  end

  before { sign_in user }

  after { ActsAsTenant.current_tenant = nil }

  def act(action, notification, **query)
    patch public_send(:"all_inbox_#{action}_path", notification, **query),
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
  end

  def state_of(notification)
    ActsAsTenant.without_tenant { Notification.find(notification.id).state }
  end

  # The list the stream redraws.
  def redrawn_list
    doc = Nokogiri::HTML(response.body)
    template = doc.at_css('turbo-stream[target="inbox_master_list"] template')
    expect(template).to be_present
    template
  end

  def listed_ids
    redrawn_list.css('.inbox-row').pluck('data-notification-id')
  end

  describe 'the menu of a row' do
    it 'offers the actions on the addresses of this page, with the list state' do
      get all_inboxes_path(org: north.id, state_filters: %w[unread])
      row = Nokogiri::HTML(response.body).at_css(%(.inbox-row[data-notification-id="#{north_row.id}"]))

      actions = row.css('.inbox-row__menu form').pluck('action')
      expect(actions.map { |a| URI(a).path }).to eq(["/inbox/#{north_row.id}/mark_read", "/inbox/#{north_row.id}/archive"])
      actions.each do |action|
        query = Rack::Utils.parse_nested_query(URI(action).query)
        expect(query).to eq('org' => north.id, 'state_filters' => %w[unread])
      end
    end

    it 'offers "mark unread" on a read row, on its own address' do
      read = Prosopite.pause { row(south, south_project, ticket_in(south, south_project, 'Gelesen'), state: :read) }
      get all_inboxes_path(state_filters: %w[unread read])
      row = Nokogiri::HTML(response.body).at_css(%(.inbox-row[data-notification-id="#{read.id}"]))

      expect(row.css('.inbox-row__menu form').pluck('action').map { |a| URI(a).path })
        .to eq(["/inbox/#{read.id}/mark_unread", "/inbox/#{read.id}/archive"])
    end

    it 'offers the way back on an archived row' do
      archived = Prosopite.pause { row(south, south_project, ticket_in(south, south_project, 'Alt'), state: :archived) }
      get all_inboxes_path(state_filters: %w[archived])
      row = Nokogiri::HTML(response.body).at_css(%(.inbox-row[data-notification-id="#{archived.id}"]))

      expect(row.css('.inbox-row__menu form').pluck('action').map { |a| URI(a).path })
        .to eq(["/inbox/#{archived.id}/unarchive"])
    end
  end

  describe 'the write' do
    it 'marks the row and the other notifications about its ticket read, and nothing else' do
      act(:mark_read, north_row)

      expect(response).to have_http_status(:ok)
      expect(state_of(north_row)).to eq('read')
      expect(state_of(north_sibling)).to eq('read')
      expect(state_of(south_row)).to eq('delivered')
    end

    it 'archives the row with the other notifications about its ticket' do
      act(:archive, north_row)

      expect(state_of(north_row)).to eq('archived')
      expect(state_of(north_sibling)).to eq('archived')
      expect(state_of(south_row)).to eq('delivered')
    end

    it 'flips only the one row back to unread' do
      act(:mark_read, north_row)
      act(:mark_unread, north_row)

      expect(state_of(north_row)).to eq('queued')
      expect(state_of(north_sibling)).to eq('read')
    end

    it 'brings an archived ticket back as read, every notification of it' do
      act(:archive, north_row)
      act(:unarchive, north_row)

      expect(state_of(north_row)).to eq('read')
      expect(state_of(north_sibling)).to eq('read')
    end

    it 'brings an archived row back unread with "mark unread"' do
      act(:archive, north_row)
      act(:mark_unread, north_row)

      expect(state_of(north_row)).to eq('queued')
      expect(state_of(north_sibling)).to eq('archived')
    end

    it 'does not take along the notification of another person about the same ticket' do
      colleague = create(:user)
      theirs = Prosopite.pause do
        make_token_owner_a_member(colleague, north, projects: [north_project])
        row(north, north_project, north_ticket, recipient: colleague)
      end

      act(:archive, north_row)

      expect(state_of(theirs)).to eq('delivered')
    end

    it 'does not take along the mail row about the same ticket' do
      mail = Prosopite.pause { row(north, north_project, north_ticket, channel: 'email') }

      act(:mark_read, north_row)

      expect(state_of(mail)).to eq('delivered')
    end
  end

  describe 'what it does not reach' do
    def expect_untouched(notification, action: :archive)
      before = state_of(notification)
      act(action, notification)

      expect(response).to have_http_status(:not_found)
      expect(state_of(notification)).to eq(before)
    end

    %i[mark_read mark_unread archive unarchive].each do |action|
      it "answers 404 for the row of another person (#{action})" do
        colleague = create(:user)
        theirs = Prosopite.pause do
          make_token_owner_a_member(colleague, north, projects: [north_project])
          row(north, north_project, north_ticket, recipient: colleague)
        end

        expect_untouched(theirs, action: action)
      end
    end

    it 'answers 404 for a row in an organisation the person has left' do
      Membership.find_by(user_id: user.id, organisation_id: south.id).update!(active: false)

      expect_untouched(south_row)
    end

    it 'answers 404 for a row in a project the person has lost' do
      hidden_project = project_in(north, name: 'Geheim')
      hidden = Prosopite.pause { row(north, hidden_project, ticket_in(north, hidden_project, 'Verborgen')) }

      expect_untouched(hidden, action: :mark_read)
    end

    it 'answers 404 for a mail row' do
      mail = Prosopite.pause { row(north, north_project, north_ticket, channel: 'email') }

      expect_untouched(mail, action: :mark_read)
    end

    it 'answers 404 for an id that is none and for one that does not exist' do
      patch '/inbox/not-an-id/archive'
      expect(response).to have_http_status(:not_found)

      patch "/inbox/#{SecureRandom.uuid}/archive"
      expect(response).to have_http_status(:not_found)
    end

    it 'sends a visitor without a session to the sign-in page and changes nothing' do
      sign_out user
      act(:archive, north_row)

      expect(response).to have_http_status(:unauthorized).or redirect_to(new_user_session_path)
      expect(state_of(north_row)).to eq('delivered')
    end
  end

  # The reader's lookup already leaves out what the person may not see. The
  # policy is asked all the same, under the tenant of the row: a rule added to
  # it later holds here without anybody remembering this page.
  describe 'the policy' do
    { mark_read: :mark_read?, mark_unread: :mark_unread?, archive: :archive?, unarchive: :archive? }.each do |action, query|
      it "asks #{query} before #{action} and writes nothing on a no" do
        asked_under = nil
        allow_any_instance_of(NotificationPolicy).to receive(query) do
          asked_under = ActsAsTenant.current_tenant
          false
        end
        before = state_of(south_row)

        act(action, south_row)

        expect(asked_under).to eq(south)
        expect(response).not_to have_http_status(:ok)
        expect(state_of(south_row)).to eq(before)
      end
    end
  end

  describe 'the session' do
    it 'keeps its organisation when a row of another organisation is acted on' do
      get organisation_notifications_path(north)
      expect(session[:current_organisation_id]).to eq(north.id)

      act(:archive, south_row)

      expect(response).to have_http_status(:ok)
      expect(session[:current_organisation_id]).to eq(north.id)
    end
  end

  describe 'the answer' do
    it 'redraws the list without the archived row and keeps the others' do
      act(:archive, north_row)

      expect(listed_ids).to eq([south_row.id])
    end

    it 'keeps a read row in the list of all, without its dot' do
      act(:mark_read, south_row, state_filters: %w[unread read])

      expect(listed_ids).to eq([south_row.id, north_row.id])
      row = redrawn_list.at_css(%(.inbox-row[data-notification-id="#{south_row.id}"]))
      expect(row.at_css('.inbox-row__dot')).to be_nil
    end

    it 'drops a read row from the unread view' do
      act(:mark_read, south_row, state_filters: %w[unread])

      expect(listed_ids).to eq([north_row.id])
    end

    it 'keeps the organisation the list was narrowed to, in the rows and in their next actions' do
      act(:mark_read, north_row, org: north.id, state_filters: %w[unread read])

      expect(listed_ids).to eq([north_row.id])
      action = redrawn_list.at_css('.inbox-row__menu form')['action']
      expect(Rack::Utils.parse_nested_query(URI(action).query))
        .to eq('org' => north.id, 'state_filters' => %w[unread read])
    end

    it 'names the organisation on the redrawn rows' do
      act(:mark_read, north_row, state_filters: %w[unread read])

      row = redrawn_list.at_css(%(.inbox-row[data-notification-id="#{north_row.id}"]))
      expect(row.at_css('.inbox-row__meta-text').text).to start_with('Nordwind GmbH')
    end

    it 'counts again: the pill, the select and the sidebar' do
      act(:mark_read, north_row)
      doc = Nokogiri::HTML(response.body)

      pill = doc.at_css('turbo-stream[target="inbox_unread_count"] template')
      expect(pill.text.strip).to eq('1')

      nav = doc.at_css('turbo-stream[target="all_inboxes_nav"] template')
      expect(nav.at_css('#all_inboxes_nav')).to be_present
      # The level's sidebar, with "Gesamt-Inbox" marked although the request is a row action.
      current = nav.css('a[aria-current="page"]')
      expect(current.map { |a| a.text.squish }).to eq([I18n.t('navigation.all_inboxes')])
      expect(current.first['class']).to include('sidebar-row--active')
      expect(nav.css('a').map { |a| a.text.squish }).to include(I18n.t('navigation.overview'))
      north_item = nav.css('li').find { |li| li.text.include?('Nordwind GmbH') }
      south_item = nav.css('li').find { |li| li.text.include?('Suedhang AG') }
      expect(north_item.text).not_to match(/\d/)
      expect(south_item.text).to include('1')

      tools = doc.at_css('turbo-stream[target="inbox_list_tools"] template')
      expect(tools.css('#inbox-organisation option').map(&:text)).to include('Nordwind GmbH', 'Suedhang AG (1)')
    end

    it 'counts at the pill only the organisation the list is narrowed to' do
      act(:mark_read, south_row, org: north.id)

      pill = Nokogiri::HTML(response.body).at_css('turbo-stream[target="inbox_unread_count"] template')
      expect(pill.text.strip).to eq('2')
    end

    it 'says what happened' do
      act(:archive, north_row)

      toast = Nokogiri::HTML(response.body).at_css('turbo-stream[target="flash_messages"] template')
      expect(toast.text).to include(I18n.t('views.organisations.notifications.update.notification_archived'))
    end

    it 'says "read" after reading and nothing about the archive after the way back' do
      act(:mark_read, north_row)
      toast = Nokogiri::HTML(response.body).at_css('turbo-stream[target="flash_messages"] template')
      expect(toast.text.squish).to eq(I18n.t('views.organisations.notifications.update.marked_as_read'))
    end

    it 'does not say "archived" after the way back out of the archive' do
      archived = Prosopite.pause { row(south, south_project, ticket_in(south, south_project, 'Alt'), state: :archived) }
      act(:unarchive, archived, state_filters: %w[archived])

      toast = Nokogiri::HTML(response.body).at_css('turbo-stream[target="flash_messages"] template')
      expect(toast.text.squish).to eq(I18n.t('views.organisations.notifications.update.notification_updated'))
    end

    it 'leads back to the list with its state without a stream' do
      patch all_inbox_archive_path(north_row, org: north.id, state_filters: %w[unread])

      expect(response).to redirect_to(all_inboxes_path(state_filters: %w[unread], org: north.id))
    end

    it 'answers 404 for an organisation of the list the person cannot reach, after nothing' do
      act(:archive, north_row, org: create(:organisation).id)

      expect(response).to have_http_status(:not_found)
      expect(state_of(north_row)).to eq('delivered')
      expect(state_of(north_sibling)).to eq('delivered')
    end

    it 'refuses a malformed organisation filter before changing the row or its siblings' do
      act(:mark_read, north_row, org: 'not-an-id')

      expect(response).to have_http_status(:not_found)
      expect(state_of(north_row)).to eq('delivered')
      expect(state_of(north_sibling)).to eq('delivered')
    end
  end

  describe 'pages already on screen' do
    before do
      Prosopite.pause do
        101.times do |i|
          ticket = ticket_in(north, north_project, "Page ticket #{i}")
          row(north, north_project, ticket, created_at: (i + 1).minutes.ago)
        end
      end
    end

    def page_rows(number, **query)
      get all_inboxes_path(page: number, **query)
      Nokogiri::HTML(response.body).css('.inbox-row').pluck('data-notification-id')
    end

    %w[grouped chronological].each do |mode|
      it "keeps a directly opened second page in #{mode} mode" do
        shown = page_rows(2, view_mode: mode)
        form = Nokogiri::HTML(response.body).at_css('.inbox-row__menu form')
        patch form['action'], headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

        expect(response).to have_http_status(:ok)
        expect(listed_ids).to eq(shown)
        scroller = redrawn_list.at_css('#inbox_master_list')
        expect(scroller['data-neo-endless-scroll-first-page-value']).to eq('2')
        expect(scroller['data-neo-endless-scroll-page-value']).to eq('2')
        next_action = redrawn_list.at_css('.inbox-row__menu form')['action']
        expect(Rack::Utils.parse_nested_query(URI(next_action).query)['page']).to eq('2')
      end
    end

    it 'redraws the accumulated pages and resumes scrolling at the next unseen page' do
      shown = page_rows(1) + page_rows(2)
      notification = ActsAsTenant.without_tenant { Notification.find(shown.last) }

      act(:mark_read, notification, page: 1, through_page: 2)

      expect(listed_ids).to eq(shown)
      scroller = redrawn_list.at_css('#inbox_master_list')
      expect(scroller['data-neo-endless-scroll-first-page-value']).to eq('1')
      expect(scroller['data-neo-endless-scroll-page-value']).to eq('2')
      expect(scroller['data-neo-endless-scroll-has-more-value']).to eq('true')
      expect(state_of(notification)).to eq('read')
      expect(page_rows(3) & shown).to be_empty
    end

    it 'clamps the window when archiving removes the final page' do
      shown = page_rows(3)
      Prosopite.pause { shown.drop(1).each { |id| act(:archive, id) } }
      notification = ActsAsTenant.without_tenant { Notification.find(shown.first) }

      act(:archive, notification, page: 2, through_page: 3)

      expect(listed_ids.size).to eq(50)
      scroller = redrawn_list.at_css('#inbox_master_list')
      expect(scroller['data-neo-endless-scroll-first-page-value']).to eq('2')
      expect(scroller['data-neo-endless-scroll-page-value']).to eq('2')
      expect(scroller['data-neo-endless-scroll-has-more-value']).to eq('false')
    end

    it 'keeps the page on an HTML redirect too' do
      shown = page_rows(2)
      patch all_inbox_mark_read_path(shown.first, page: 2)

      expect(response).to redirect_to(all_inboxes_path(page: 2))
    end
  end
  # The head of the lane on this page (S3, plan §5.5): its actions and its 5 s timer are
  # the row actions. The answer targets only the matching notification head, even after
  # search or a lane switch, and nothing else of the lane, so an open reply form
  # survives. The timer reads quietly.
  describe 'the head of the open lane' do
    let(:stream_targets) { ->(body) { Nokogiri::HTML(body).css('turbo-stream').map { |n| [n['action'], n['target']] } } }

    def pills(body)
      Nokogiri::HTML(body).at_css('turbo-stream[action="replace"][targets^="#inbox_pane_status_pills["] template')
    end

    it 'swaps the head of the lane when the row acted on is the open one, and nothing else of the lane' do
      act(:archive, south_row, state_filters: %w[read unread], notification: south_row.id)

      expect(response).to have_http_status(:ok)
      head = pills(response.body)
      expect(head).to be_present
      expect(head.css('form').pluck('action')).to eq(["/inbox/#{south_row.id}/unarchive?#{{ notification: south_row.id, state_filters: %w[read unread] }.to_query}"])
      expect(head.at_css('a.inbox-lane-actions__open')['href']).to eq("/org/#{south.id}/projects/#{south_project.id}/tickets/#{south_ticket.id}")
      expect(stream_targets.call(response.body)).not_to include(%w[replace ticket_pane])
      expect(response.body).not_to include('id="ticket_pane"')
      expect(response.body).to include('all_inboxes_drawn_stamp')
    end

    # A menu action updates the matching head whether the page still names the
    # open row in its referrer or a search has removed it.
    it 'swaps the head too when the menu of the open row acts, named by the page it came from' do
      lane_page = "http://www.example.com#{all_inboxes_path(state_filters: %w[read unread], notification: south_row.id)}"
      patch all_inbox_archive_path(south_row, state_filters: %w[read unread]),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html', 'Referer' => lane_page }

      expect(response).to have_http_status(:ok)
      expect(pills(response.body)).to be_present
      expect(pills(response.body).at_css('form')['action']).to start_with("/inbox/#{south_row.id}/unarchive?")
      expect(response.body).to include('notification-toast')
    end

    it 'updates the matching head after search removed the open notification from the address' do
      searched_page = "http://www.example.com#{all_inboxes_path(search: 'Paket', state_filters: %w[read unread])}"
      patch all_inbox_archive_path(south_row, search: 'Paket', state_filters: %w[read unread]),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html', 'Referer' => searched_page }

      expect(response).to have_http_status(:ok)
      expect(state_of(south_row)).to eq('archived')
      expect(pills(response.body).at_css('form')['action']).to include("/inbox/#{south_row.id}/unarchive?")
      expect(pills(response.body).at_css('[data-notification-id]')['data-notification-id']).to eq(south_row.id)
    end

    it 'cannot replace another notification head even when the request named it as open' do
      act(:archive, north_row, state_filters: %w[read unread], notification: south_row.id)

      expect(response).to have_http_status(:ok)
      expect(redrawn_list).to be_present
      stream = Nokogiri::HTML(response.body).at_css('turbo-stream[targets^="#inbox_pane_status_pills["]')
      expect(stream['target']).to be_nil
      # Apply the response selector to the head that could now be on screen.
      current = Nokogiri::HTML.fragment(%(<div id="inbox_pane_status_pills" data-notification-id="#{south_row.id}"></div>))
      expect(current.css(stream['targets'])).to be_empty
      current.at_css('div')['data-notification-id'] = north_row.id
      expect(current.css(stream['targets']).size).to eq(1)
    end

    # Every action of a row answers the head of its own notification, whether the address
    # names an open row or not. The selector is the id whole: a prefix or a bare id would
    # reach the head of a neighbour.
    AllInboxesController::ROW_ACTIONS.each_key do |action|
      it "addresses the head of the acted row alone after #{action}, without the address naming it" do
        before_it = { 'mark_unread' => :mark_read, 'unarchive' => :archive }[action]
        act(before_it, south_row, state_filters: %w[read unread]) if before_it
        act(action, south_row, state_filters: %w[read unread])

        expect(response).to have_http_status(:ok)
        heads = Nokogiri::HTML(response.body).css('turbo-stream').select { |n| "#{n['target']}#{n['targets']}".include?('inbox_pane_status_pills') }
        expect(heads.map { |n| [n['action'], n['target'], n['targets']] })
          .to eq([['replace', nil, "#inbox_pane_status_pills[data-notification-id='#{south_row.id}']"]])
        expect(heads.first.at_css('template > #inbox_pane_status_pills')['data-notification-id']).to eq(south_row.id)
      end
    end

    # The two halves of the contract meet here: the head the lane draws and the selector
    # an action answers with. Each alone can look right and still miss the other.
    it 'sends a selector that finds the head the lane drew, and not the head of another lane' do
      lane_of = lambda do |notification|
        get all_inboxes_path(state_filters: %w[read unread], notification: notification.id), headers: { 'Turbo-Frame' => 'ticket_pane' }
        expect(response).to have_http_status(:ok)
        Nokogiri::HTML(response.body)
      end
      south_lane = lane_of.call(south_row)
      north_lane = lane_of.call(north_row)
      expect(north_lane.css('#inbox_pane_status_pills').size).to eq(1)

      act(:archive, south_row, state_filters: %w[read unread])
      selector = Nokogiri::HTML(response.body).at_css('turbo-stream[targets^="#inbox_pane_status_pills["]')['targets']

      expect(south_lane.css(selector).pluck('id')).to eq(['inbox_pane_status_pills'])
      expect(north_lane.css(selector)).to be_empty
    end

    # Since the head no longer waits for the address to name the row, every row action
    # asks for one. A row the lane has no kind for (here an old row filed under a note:
    # no event names it, Inbox::LaneKind answers nil) has no lane and gets none.
    it 'sends no head for a row without a lane kind' do
      note_row = Prosopite.pause do
        ActsAsTenant.with_tenant(south) do
          ProjectPermission.find_by!(user: user, project: south_project).update!(notes_access: 'read_write')
          create(:notification, recipient: user, organisation: south, project: south_project,
                                notifiable: create(:note, project: south_project), event_type: 'system_message',
                                channel: 'in_app', state: :delivered)
        end
      end
      act(:mark_read, note_row, state_filters: %w[read unread], view_mode: 'chronological')

      expect(response).to have_http_status(:ok)
      expect(state_of(note_row)).to eq('read')
      expect(redrawn_list).to be_present
      expect(response.body).not_to include('inbox_pane_status_pills')
    end

    # S4: a row about a project's event has a lane too (a note in a frame, a card), and its
    # head gets the new buttons like a ticket's: the head alone, never the lane, so the
    # frame of the note does not load again.
    describe 'for a row about a project event' do
      let(:colleague) { create(:user, first_name: 'Kai', last_name: 'Kollege') }
      let(:south_note) do
        ActsAsTenant.with_tenant(south) { create(:note, project: south_project, organisation: south, creator: colleague, title: 'Protokoll Versand') }
      end
      let(:note_event_row) do
        Prosopite.pause do
          ActsAsTenant.with_tenant(south) do
            ProjectPermission.find_by!(user: user, project: south_project).update!(notes_access: 'read_write', members_access: 'read_only')
          end
          project_event_row(south, south_project, 'note_created', recipient: user, actor: colleague, secondary: south_note,
                                                                  parameters: { 'note_title' => south_note.title })
        end
      end
      let(:member_event_row) do
        note_event_row
        Prosopite.pause do
          project_event_row(south, south_project, 'member_added', recipient: user, actor: colleague,
                                                                  parameters: { 'user_name' => 'Mia Neu' })
        end
      end

      it 'swaps the head of an open note row to its new state and does not replace the lane' do
        act(:mark_read, note_event_row, state_filters: %w[read unread], view_mode: 'chronological', notification: note_event_row.id)

        expect(response).to have_http_status(:ok)
        expect(state_of(note_event_row)).to eq('read')
        head = pills(response.body)
        expect(head.css('button').map { |button| button.text.squish })
          .to eq([I18n.t('views.organisations.notifications.actions.mark_unread'), I18n.t('views.organisations.notifications.actions.archive')])
        expect(head.at_css('a.inbox-lane-actions__open')['href'])
          .to eq("/org/#{south.id}/projects/#{south_project.id}/notes/#{south_note.id}")
        expect(stream_targets.call(response.body)).not_to include(%w[replace ticket_pane], %w[replace ticket_display_frame])
        expect(response.body).not_to include('id="ticket_pane"')
      end

      it 'answers the timer of an open note row without a toast' do
        act(:mark_read, note_event_row, state_filters: %w[read unread], view_mode: 'chronological', notification: note_event_row.id, quiet: '1')

        expect(response).to have_http_status(:ok)
        expect(pills(response.body)).to be_present
        expect(redrawn_list).to be_present
        expect(Nokogiri::HTML(response.body).css('turbo-stream').pluck('action').uniq).to eq(['replace'])
        expect(response.body).not_to include('notification-toast')
      end

      it 'swaps the head of an open card row, which has no link of its own' do
        act(:mark_read, member_event_row, state_filters: %w[read unread], view_mode: 'chronological', notification: member_event_row.id)

        expect(response).to have_http_status(:ok)
        head = pills(response.body)
        expect(head.at_css('#inbox_pane_status_pills')['data-notification-id']).to eq(member_event_row.id)
        expect(head.css('button').size).to eq(2)
        expect(head.at_css('a')).to be_nil
        expect(stream_targets.call(response.body)).not_to include(%w[replace ticket_pane])
      end
    end

    # The timer applies its answer by hand and knows "replace" alone: an answer that
    # carries any other action is dropped whole, list and head with it
    # (pane_mark_read_delay_controller.js and its test).
    it 'answers the timer with replace alone' do
      act(:mark_read, south_row, state_filters: %w[read unread], notification: south_row.id, quiet: '1')

      expect(response).to have_http_status(:ok)
      expect(pills(response.body)).to be_present
      expect(redrawn_list).to be_present
      expect(Nokogiri::HTML(response.body).css('turbo-stream').pluck('action').uniq).to eq(['replace'])
    end

    it 'reads quietly for the timer, while the menu says what it did' do
      act(:mark_read, south_row, state_filters: %w[read unread], notification: south_row.id, quiet: '1')
      expect(response).to have_http_status(:ok)
      expect(state_of(south_row)).to eq('read')
      expect(pills(response.body)).to be_present
      expect(response.body).to include('all_inboxes_drawn_stamp')
      expect(response.body).not_to include('notification-toast')

      act(:mark_unread, south_row, state_filters: %w[read unread], notification: south_row.id)
      expect(response.body).to include('notification-toast')
    end

    it 'keeps the organisation of the session' do
      get organisation_notifications_path(north, state_filters: %w[read unread])
      act(:mark_read, south_row, state_filters: %w[read unread], notification: south_row.id, quiet: '1')
      expect(response).to have_http_status(:ok)
      expect(session[:current_organisation_id]).to eq(north.id)
    end
  end
end
