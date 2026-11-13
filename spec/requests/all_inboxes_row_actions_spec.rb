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
RSpec.describe 'Row actions of the inbox above the organisations', :ci_guard, type: :request do
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
    end
  end
end
