# frozen_string_literal: true

require 'rails_helper'

# What: the bulk bar of the inbox above the organisations (PATCH
#       /inbox/selection/mark_read, /inbox/selection/archive): the ticked rows are
#       marked read or archived, in every organisation they belong to, each with the
#       other notifications about its subject.
# Why:  this write crosses tenants on ids a browser sends. Everything it must NOT
#       reach is pinned here: another person's row, a row in a left organisation or
#       a lost project, a mail row. An id like that changes nothing and says
#       nothing, and the rest of the selection is still changed. There is no
#       "everything" action: a request without ids is refused. And the session's
#       organisation stays where it is, which no address under /org/:id would allow.
#       The same bar inside an organisation: spec/requests/inbox_bulk_actions_spec.rb;
#       the write itself: spec/services/actors/change_notification_states_spec.rb.
RSpec.describe 'Bulk actions of the inbox above the organisations', :ci_guard, :real_transactions, type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }
  let(:turbo) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

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
  # A row nobody ticks.
  let!(:other_row) do
    Prosopite.pause { row(south, south_project, ticket_in(south, south_project, 'Karton nass'), created_at: 4.hours.ago) }
  end

  before { sign_in user }

  after { ActsAsTenant.current_tenant = nil }

  def act(action, ids, headers: turbo, **query)
    patch public_send(:"all_inboxes_selection_#{action}_path", **query), params: { ids: ids }, headers: headers
  end

  def state_of(notification)
    ActsAsTenant.without_tenant { Notification.find(notification.respond_to?(:id) ? notification.id : notification).state }
  end

  # The four rows of every example, in this order, read at once.
  def states
    rows = [north_row, north_sibling, south_row, other_row]
    found = ActsAsTenant.without_tenant { Notification.where(id: rows.map(&:id)).pluck(:id, :state).to_h }
    rows.map { |notification| found.fetch(notification.id) }
  end

  def stream(target)
    template = Nokogiri::HTML(response.body).at_css(%(turbo-stream[target="#{target}"] template))
    expect(template).to be_present, "no stream for #{target}"
    template
  end

  def listed_ids
    stream('inbox_master_list').css('.inbox-row').pluck('data-notification-id')
  end

  def said
    stream('flash').text.squish
  end

  # The sentence stands in the flash of the page as a success or as a refusal
  # (NeoFlashComponent: the sign and the ground of its type).
  def said_as
    flash = stream('flash')
    return :refusal if flash.at_css('.bi-exclamation-triangle-fill') && flash.at_css('.bg-red-100')
    return :success if flash.at_css('.bi-check-circle-fill') && flash.at_css('.bg-green-100')

    :neither
  end

  it 'has addresses of its own, which the address of a row does not take' do
    expect(Rails.application.routes.recognize_path('/inbox/selection/mark_read', method: :patch))
      .to include(controller: 'all_inboxes', action: 'mark_selection_read')
    expect(Rails.application.routes.recognize_path('/inbox/selection/archive', method: :patch))
      .to include(controller: 'all_inboxes', action: 'archive_selection')
    expect(Rails.application.routes.recognize_path("/inbox/#{north_row.id}/archive", method: :patch))
      .to include(controller: 'all_inboxes', action: 'archive', id: north_row.id)
  end

  describe 'the write' do
    it 'marks rows of two organisations read in one request, each with its whole ticket' do
      act(:mark_read, [north_row.id, south_row.id])

      expect(response).to have_http_status(:ok)
      expect(states).to eq(%w[read read read delivered])
    end

    it 'archives rows of two organisations in one request, each with its whole ticket' do
      act(:archive, [north_row.id, south_row.id])

      expect(response).to have_http_status(:ok)
      expect(states).to eq(%w[archived archived archived delivered])
    end

    it 'archives a row that is read already' do
      read = Prosopite.pause { row(south, south_project, ticket_in(south, south_project, 'Alt'), state: :read) }

      act(:archive, [read.id])

      expect(state_of(read)).to eq('archived')
    end

    it 'changes nothing more when the same request comes again' do
      act(:archive, [north_row.id, south_row.id])
      archived_at = ActsAsTenant.without_tenant { Notification.find(north_row.id).archived_at }

      act(:archive, [north_row.id, south_row.id])

      expect(response).to have_http_status(:ok)
      expect(ActsAsTenant.without_tenant { Notification.find(north_row.id).archived_at }).to eq(archived_at)
      expect(states).to eq(%w[archived archived archived delivered])
    end

    it 'does not take along the notification of another person about the same ticket' do
      colleague = create(:user)
      theirs = Prosopite.pause do
        make_token_owner_a_member(colleague, north, projects: [north_project])
        row(north, north_project, north_ticket, recipient: colleague)
      end

      act(:archive, [north_row.id])

      expect(state_of(theirs)).to eq('delivered')
    end
  end

  # Each of these ids is dropped without a word, and the row ticked beside it is
  # still changed: the answer must not tell a foreign id from one that is gone.
  describe 'what it does not reach' do
    def expect_dropped(notification, action: :archive)
      before = state_of(notification)

      act(action, [notification.id, south_row.id])

      expect(response).to have_http_status(:ok)
      expect(state_of(notification)).to eq(before)
      expect(state_of(south_row)).not_to eq('delivered')
      expect(said).to eq(I18n.t("flash.all_inboxes.#{action == :archive ? 'archived' : 'marked_read'}", count: 1))
    end

    %i[mark_read archive].each do |action|
      it "leaves the row of another person (#{action})" do
        colleague = create(:user)
        theirs = Prosopite.pause do
          make_token_owner_a_member(colleague, north, projects: [north_project])
          row(north, north_project, ticket_in(north, north_project, 'Fremd'), recipient: colleague)
        end

        expect_dropped(theirs, action: action)
      end
    end

    it 'leaves a row in an organisation the person has left' do
      Membership.find_by(user_id: user.id, organisation_id: north.id).update!(active: false)

      expect_dropped(north_row)
      expect(state_of(north_sibling)).to eq('delivered')
    end

    # A row without a project passes the rule of what a person may see whatever
    # their rights, so here only the membership stands between it and the write.
    it 'leaves a row without a project in an organisation the person has left' do
      system_message = Prosopite.pause do
        ActsAsTenant.with_tenant(north) do
          create(:notification, recipient: user, organisation: north, project: nil, channel: 'in_app', state: :delivered)
        end
      end
      Membership.find_by(user_id: user.id, organisation_id: north.id).update!(active: false)

      expect_dropped(system_message)
    end

    it 'leaves a row in a project the person has lost' do
      hidden_project = project_in(north, name: 'Geheim')
      hidden = Prosopite.pause { row(north, hidden_project, ticket_in(north, hidden_project, 'Verborgen')) }

      expect_dropped(hidden, action: :mark_read)
    end

    it 'leaves a mail row, and does not reach the ticket through it' do
      mail = Prosopite.pause { row(north, north_project, north_ticket, channel: 'email') }

      expect_dropped(mail, action: :mark_read)
      expect(state_of(north_row)).to eq('delivered')
    end

    it 'answers an id that is none and one that does not exist like the others' do
      act(:archive, ['not-an-id', SecureRandom.uuid, south_row.id])

      expect(response).to have_http_status(:ok)
      expect(states).to eq(%w[delivered delivered archived delivered])
      expect(said).to eq(I18n.t('flash.all_inboxes.archived', count: 1))
    end

    it 'says that nothing is left when no id of the selection is a row of this inbox' do
      act(:archive, ['not-an-id', SecureRandom.uuid])

      expect(response).to have_http_status(:ok)
      expect(states).to all(eq('delivered'))
      expect(said).to eq(I18n.t('flash.all_inboxes.none_changed'))
    end

    it 'sends a visitor without a session to the sign-in page and changes nothing' do
      sign_out user

      act(:archive, [north_row.id, south_row.id])

      expect(response).to have_http_status(:unauthorized).or redirect_to(new_user_session_path)
      expect(states).to all(eq('delivered'))
    end
  end

  # The page has no "everything" action. Inside an organisation the same routes
  # without ids act on the whole inbox; here they never do.
  describe 'a request without a selection' do
    def expect_refused
      expect(response).to have_http_status(:unprocessable_content)
      expect(said).to eq(I18n.t('flash.notifications.nothing_selected'))
      expect(said_as).to eq(:refusal)
      expect(states).to all(eq('delivered'))
    end

    %i[mark_read archive].each do |action|
      it "refuses #{action} without ids and changes nothing" do
        patch public_send(:"all_inboxes_selection_#{action}_path"), headers: turbo

        expect_refused
      end
    end

    it 'refuses blank ids' do
      act(:mark_read, ['', ''])

      expect_refused
    end

    it 'refuses ids that are no list' do
      patch all_inboxes_selection_archive_path, params: { ids: { north_row.id => '1' } }, headers: turbo
      expect_refused

      patch all_inboxes_selection_archive_path, params: { ids: north_row.id }, headers: turbo
      expect_refused
    end

    it 'answers the plain form with the list and the reason' do
      patch all_inboxes_selection_archive_path(org: north.id)

      expect(response).to redirect_to(all_inboxes_path(org: north.id))
      expect(flash[:alert]).to eq(I18n.t('flash.notifications.nothing_selected'))
    end
  end

  describe 'a selection that is too large' do
    let(:limit) { AllInboxesController::MAX_SELECTION }

    it 'takes as many rows as the limit says' do
      expect(limit).to eq(500)

      act(:archive, Array.new(limit - 1) { SecureRandom.uuid } + [south_row.id])

      expect(response).to have_http_status(:ok)
      expect(state_of(south_row)).to eq('archived')
    end

    it 'refuses one more and changes nothing' do
      act(:archive, Array.new(limit) { SecureRandom.uuid } + [south_row.id])

      expect(response).to have_http_status(:unprocessable_content)
      expect(said).to eq(I18n.t('flash.all_inboxes.too_many_selected', count: limit))
      expect(states).to all(eq('delivered'))
    end

    it 'counts an id once, however often it is sent' do
      act(:archive, Array.new(limit + 1) { south_row.id })

      expect(response).to have_http_status(:ok)
      expect(state_of(south_row)).to eq('archived')
    end
  end

  # The lookup already leaves out what the person may not see. The policy is asked
  # all the same, under the tenant of each organisation the selection touches.
  describe 'the policy' do
    { mark_read: :mark_all_read?, archive: :archive_all? }.each do |action, query|
      it "asks #{query} in every organisation before #{action} and writes nothing on a no" do
        asked_under = []
        allow_any_instance_of(NotificationsPolicy).to receive(query) do
          asked_under << ActsAsTenant.current_tenant
          asked_under.size < 2
        end

        act(action, [north_row.id, south_row.id])

        expect(asked_under).to contain_exactly(north, south)
        expect(response).not_to have_http_status(:ok)
        expect(states).to all(eq('delivered'))
      end
    end
  end

  it 'changes nothing in the first organisation when the second fails' do
    second = [north, south].max_by(&:id)
    allow(Notifications::SubjectBundle).to receive(:lock).and_wrap_original do |original, **kwargs|
      raise 'the second organisation fails' if ActsAsTenant.current_tenant == second

      original.call(**kwargs)
    end

    expect { act(:archive, [north_row.id, south_row.id]) }.to raise_error(/the second organisation fails/)

    expect(states).to all(eq('delivered'))
  end

  describe 'the session' do
    it 'keeps its organisation when rows of other organisations are acted on' do
      get organisation_notifications_path(north)
      expect(session[:current_organisation_id]).to eq(north.id)

      act(:archive, [north_row.id, south_row.id])

      expect(response).to have_http_status(:ok)
      expect(session[:current_organisation_id]).to eq(north.id)
    end
  end

  describe 'the answer' do
    it 'redraws the list without the archived rows and keeps the others' do
      act(:archive, [north_row.id, south_row.id])

      expect(listed_ids).to eq([other_row.id])
    end

    it 'keeps read rows in the list of all and drops them from the unread view' do
      act(:mark_read, [north_row.id, south_row.id])
      expect(listed_ids).to include(north_row.id, south_row.id, other_row.id)

      act(:mark_read, [other_row.id], state_filters: %w[unread])
      expect(listed_ids).to be_empty
    end

    it 'keeps the organisation the list was narrowed to, and still acts on a row outside it' do
      act(:mark_read, [north_row.id, south_row.id], org: north.id)

      expect(listed_ids).to eq([north_row.id])
      expect(state_of(south_row)).to eq('read')
    end

    it 'counts again: the pill, the select and the sidebar' do
      act(:mark_read, [north_row.id])

      expect(stream('inbox_unread_count').text.strip).to eq('2')
      nav = stream('all_inboxes_nav')
      north_item = nav.css('li').find { |li| li.text.include?('Nordwind GmbH') }
      south_item = nav.css('li').find { |li| li.text.include?('Suedhang AG') }
      expect(north_item.text).not_to match(/\d/)
      expect(south_item.text).to include('2')
      expect(stream('inbox_list_tools').css('#inbox-organisation option').map(&:text))
        .to include('Nordwind GmbH', 'Suedhang AG (2)')
    end

    it 'says how many rows it changed, counting a ticket once' do
      act(:mark_read, [north_row.id, south_row.id])
      expect(said).to eq(I18n.t('flash.all_inboxes.marked_read', count: 2))
      expect(said_as).to eq(:success)

      act(:archive, [north_row.id, south_row.id, other_row.id])
      expect(said).to eq(I18n.t('flash.all_inboxes.archived', count: 3))
    end

    # The echo rule of the live update (all_inboxes_live_spec): the signal that
    # follows this write carries the stamp the answer has drawn, so the reader's
    # own action raises no banner.
    it 'draws the list with the stamp of the state after the write' do
      act(:archive, [north_row.id, south_row.id])

      drawn = stream('all_inboxes_drawn_stamp').at_css('#all_inboxes_drawn_stamp')['data-stamp']
      expect(drawn).to eq(Notifications::InboxQuery.stamp(user: user, reach: PersonalAccessToken::Reach.for_person(user)))
    end

    it 'leads back to the list with its state without a stream, and says the same' do
      act(:archive, [north_row.id], headers: {}, org: north.id, state_filters: %w[unread])

      expect(response).to redirect_to(all_inboxes_path(state_filters: %w[unread], org: north.id))
      expect(flash[:notice]).to eq(I18n.t('flash.all_inboxes.archived', count: 1))
      expect(state_of(north_row)).to eq('archived')
    end

    it 'answers 404 for an organisation of the list the person cannot reach, after nothing' do
      act(:archive, [north_row.id], org: create(:organisation).id)

      expect(response).to have_http_status(:not_found)
      expect(states).to all(eq('delivered'))
    end

    it 'refuses a malformed organisation filter before changing anything' do
      act(:archive, [north_row.id], org: 'not-an-id')

      expect(response).to have_http_status(:not_found)
      expect(states).to all(eq('delivered'))
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

    it 'redraws the accumulated pages and resumes scrolling at the next unseen page' do
      shown = page_rows(1) + page_rows(2)

      act(:mark_read, [shown.first, shown.last], page: 1, through_page: 2)

      expect(listed_ids).to eq(shown)
      scroller = stream('inbox_master_list').at_css('#inbox_master_list')
      expect(scroller['data-neo-endless-scroll-first-page-value']).to eq('1')
      expect(scroller['data-neo-endless-scroll-page-value']).to eq('2')
      expect(scroller['data-neo-endless-scroll-has-more-value']).to eq('true')
      changed = ActsAsTenant.without_tenant { Notification.where(id: [shown.first, shown.last]).pluck(:state) }
      expect(changed).to eq(%w[read read])
    end

    it 'keeps the search the list was narrowed by' do
      act(:mark_read, [north_row.id], search: 'Page ticket 7')

      expect(listed_ids).not_to be_empty
      titles = stream('inbox_master_list').css('.inbox-row__title').map(&:text)
      expect(titles).to all(include('Page ticket 7'))
    end
  end
end
