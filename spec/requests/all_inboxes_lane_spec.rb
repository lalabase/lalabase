# frozen_string_literal: true

require 'rails_helper'

# What: the lane of the inbox above the organisations (GET /inbox?...&notification=<id>
#       with the header Turbo-Frame: ticket_pane). It answers the pane of the organisation's
#       inbox, whole, for the organisation of the row, found through
#       Notifications::Selection and rendered inside ActsAsTenant.with_tenant of that
#       organisation. The same address without the header is the page with the lane open.
# Why:  this request reads a ticket of organisation B on a page that has no organisation,
#       while the session works in A. Everything it must not do is pinned here: answer a row
#       the person may not see (each rule its own example, one body for all), read a table
#       outside the tenant of an organisation the person belongs to, leave a tenant on the
#       thread, move the session, offer the head's actions under /org/ (their answer would
#       draw one organisation's list over this one), or draw the assistant on a page
#       without its panel. Plan: cross_org_inbox_s3_plan.md §5.2 to §5.5.
RSpec.describe 'The lane of the inbox above the organisations', :ci_guard, :real_transactions, type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }
  let(:west) { create(:organisation, name: 'Westwind KG') }

  def project_in(org, **attributes)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org, **attributes) }
  end

  def ticket_in(org, project, title, **attributes)
    ActsAsTenant.with_tenant(org) { create(:ticket, project: project, title: title, **attributes) }
  end

  def row(org, project, ticket, recipient: user, channel: 'in_app', state: :delivered, created_at: Time.current)
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: recipient, organisation: org, project: project, notifiable: ticket,
                            event_type: 'ticket_commented', channel: channel, state: state, created_at: created_at,
                            read_at: %i[read archived].include?(state) ? 1.hour.ago : nil)
    end
  end

  let(:north_project) { project_in(north, name: 'Lager') }
  let(:south_project) { project_in(south, name: 'Versand') }
  let(:west_project) { project_in(west, name: 'Hafen') }
  let(:south_ticket) { ticket_in(south, south_project, 'Paket fehlt', content: '<div>Karton leer angekommen</div>') }

  let!(:north_row) do
    Prosopite.pause do
      make_token_owner_a_member(user, north, projects: [north_project])
      row(north, north_project, ticket_in(north, north_project, 'Regal wackelt'), created_at: 2.hours.ago)
    end
  end
  let!(:south_row) do
    Prosopite.pause do
      make_token_owner_a_member(user, south, projects: [south_project])
      row(south, south_project, south_ticket, created_at: 1.hour.ago)
    end
  end
  # A third organisation, so that losing south still leaves a page above the organisations
  # (with one organisation /inbox redirects into it).
  let!(:west_row) do
    Prosopite.pause do
      make_token_owner_a_member(user, west, projects: [west_project])
      row(west, west_project, ticket_in(west, west_project, 'Kran steht'), created_at: 3.hours.ago)
    end
  end

  let(:list_state) { { state_filters: %w[read unread] } }
  let(:frame) { { 'Turbo-Frame' => 'ticket_pane' } }

  before do
    sign_in user
    # The session in north, set the way a person sets it: by opening a page of north.
    get organisation_notifications_path(north, state_filters: %w[read unread])
    expect(session[:current_organisation_id]).to eq(north.id)
  end

  after { ActsAsTenant.current_tenant = nil }

  def lane(notification_id, headers: frame, **query)
    get all_inboxes_path(**list_state, **query, notification: notification_id), headers: headers
    expect(response).to have_http_status(:ok)
    response.body
  end

  def doc(body = response.body)
    Nokogiri::HTML(body)
  end

  # The answer for a row that does not exist: the body every refused row must equal.
  def missing_body
    lane(SecureRandom.uuid)
  end

  def addresses(body)
    selector = '[href], [src], form[action], [data-pane-mark-read-delay-url-value], [data-inbox-master-item-fullview-url-value]'
    doc(body).css(selector).flat_map do |node|
      [node['href'], node['src'], (node['action'] if node.name == 'form'),
       node['data-pane-mark-read-delay-url-value'], node['data-inbox-master-item-fullview-url-value']].compact
    end
  end

  describe 'a ticket row of another organisation' do
    it 'answers the pane of that ticket alone, with the timeline under the organisation of the ticket' do
      body = lane(south_row.id)

      expect(body).not_to include('<html', 'id="inbox_master_list"')
      pane = doc(body).at_css('turbo-frame#ticket_pane')
      expect(pane).to be_present
      expect(pane.text).to include('Paket fehlt')
      timeline = doc(body).at_css('turbo-frame[id^="ticket-timeline-"]')
      expect(timeline['src']).to start_with("/org/#{south.id}/")
    end

    it 'keeps the session in the organisation it was in and leaves no tenant on the thread' do
      lane(south_row.id)
      expect(session[:current_organisation_id]).to eq(north.id)
      expect(ActsAsTenant.current_tenant).to be_nil
    end

    it 'leaves no tenant on the thread when the pane raises' do
      allow_any_instance_of(Ticket).to receive(:title).and_raise(ArgumentError, 'pane broke')
      expect { get all_inboxes_path(**list_state, notification: south_row.id), headers: frame }
        .to raise_error(ActionView::Template::Error, /pane broke/)
      expect(ActsAsTenant.current_tenant).to be_nil
      expect(session[:current_organisation_id]).to eq(north.id)
    end

    it 'draws the page with the lane open when the header is missing, the frame loading the same address' do
      sql_on_tickets = lambda do |&block|
        count = 0
        sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
          count += 1 if payload[:sql].include?('FROM "tickets"')
        end
        block.call
        count
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end

      without_lane = sql_on_tickets.call { get all_inboxes_path(**list_state) }
      with_lane = sql_on_tickets.call { get all_inboxes_path(**list_state, notification: south_row.id) }

      expect(response).to have_http_status(:ok)
      page = doc
      expect(page.at_css('[data-controller~="layout-toggle"][data-controller~="index-page"]')['class']).to include('show-content')
      pane = page.at_css('turbo-frame#ticket_pane')
      expect(pane['src']).to eq(request.fullpath)
      expect(response.body).not_to include('Karton leer angekommen')
      expect(page.css('.inbox-row').size).to eq(3)
      # The page reads the tickets its list shows and nothing for the lane.
      expect(with_lane).to eq(without_lane)
      expect(session[:current_organisation_id]).to eq(north.id)
    end
  end

  # Each rule of the organisation's inbox on the lane request, each its own example. Every
  # refused row answers what a row that does not exist answers, so no answer tells one from
  # the other. Before each refusal, the same example sees the pane of a readable row.
  describe 'a row the person may not open' do
    def expect_readable_row_opens
      expect(lane(north_row.id)).to include('Regal wackelt')
    end

    def expect_refused(notification_id)
      expect_readable_row_opens
      expected = missing_body
      expect(expected).to include('id="ticket_pane"')
      expect(lane(notification_id)).to eq(expected)
    end

    it 'refuses a row of a project the person lost' do
      hidden_project = project_in(south, name: 'Geheim')
      hidden = Prosopite.pause { row(south, hidden_project, ticket_in(south, hidden_project, 'Hinter der Tuer')) }
      expect_refused(hidden.id)
    end

    it 'refuses a row of an area the person lost' do
      ActsAsTenant.with_tenant(south) do
        ProjectPermission.find_by!(user: user, project: south_project).update!(tickets_access: 'no_access')
      end
      expect_refused(south_row.id)
    end

    it 'refuses a row of an archived project' do
      ActsAsTenant.with_tenant(south) { south_project.update!(archived_at: 1.day.ago) }
      expect_refused(south_row.id)
    end

    it 'refuses a row of an organisation the person was deactivated in' do
      Membership.find_by(user: user, organisation: south).update!(active: false)
      expect_refused(south_row.id)
    end

    it 'refuses a row of an organisation the person was removed from' do
      Membership.find_by(user: user, organisation: south).destroy!
      expect_refused(south_row.id)
    end

    it "refuses another person's row" do
      colleague = create(:user)
      theirs = Prosopite.pause do
        make_token_owner_a_member(colleague, south, projects: [south_project])
        row(south, south_project, south_ticket, recipient: colleague)
      end
      expect_refused(theirs.id)
    end

    it 'refuses the mail twin of a row' do
      mail = Prosopite.pause { row(south, south_project, south_ticket, channel: 'email') }
      expect_refused(mail.id)
    end

    it 'refuses a malformed id' do
      expect_refused('not-an-id')
    end
  end

  # The rule this lane exists under: no read with the tenant lifted. Every statement on the
  # tenanted tables runs under the tenant of an organisation the person is an active member of:
  # Selection asks each of them under its own tenant, the pane reads under the row's.
  it 'reads notifications, projects, tickets and posts only under the tenant of an organisation of the person' do
    reads = []
    sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      table = payload[:sql][/FROM "(notifications|projects|tickets|posts)"/, 1]
      reads << [table, ActsAsTenant.current_tenant] if table
    end
    allow(ActsAsTenant).to receive(:without_tenant).and_call_original

    lane(south_row.id)

    expect(reads.map(&:first)).to include('notifications', 'projects', 'tickets')
    expect(reads.map(&:last)).to all(be_present)
    expect(reads.map(&:last).uniq - [north, south, west]).to eq([])
    # The ticket and its project are read under south, the organisation of the row, only.
    expect(reads.select { |table, _| %w[projects tickets posts].include?(table) }.map(&:last).uniq).to eq([south])
    expect(ActsAsTenant).not_to have_received(:without_tenant)
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  describe 'the head of the lane' do
    it 'leads its actions and its timer to the addresses of this page, with the list state and the open row' do
      body = lane(south_row.id, org: south.id)
      forms = doc(body).css('#inbox_pane_status_pills form').pluck('action')
      expect(forms).not_to be_empty
      forms.each do |action|
        uri = URI(action)
        expect(uri.path).to match(%r{\A/inbox/#{south_row.id}/(mark_read|mark_unread|archive)\z})
        expect(Rack::Utils.parse_nested_query(uri.query))
          .to include('state_filters' => %w[read unread], 'org' => south.id, 'notification' => south_row.id)
      end

      timer = URI(doc(body).at_css('[data-pane-mark-read-delay-url-value]')['data-pane-mark-read-delay-url-value'])
      expect(timer.path).to eq("/inbox/#{south_row.id}/mark_read")
      expect(Rack::Utils.parse_nested_query(timer.query))
        .to include('state_filters' => %w[read unread], 'notification' => south_row.id, 'quiet' => '1')

      # No inbox address under /org/ but the full view of the redrawn row, which a tap below lg
      # opens in its organisation, as on every row of this page (plan §5.4).
      inbox_addresses = addresses(body).grep(%r{/org/[^/]+/inbox/})
      expect(inbox_addresses).to eq(doc(body).css('[data-inbox-master-item-fullview-url-value]')
                                             .map { |node| node['data-inbox-master-item-fullview-url-value'] })
      expect(inbox_addresses).to all(end_with('/open?source=inbox'))
    end

    it 'redraws the open row with the name of its organisation and the list state' do
      body = lane(south_row.id)
      template = doc(body).at_css(%(turbo-stream[action="replace"][target="notification_#{south_row.id}"] template))
      expect(template.at_css('.inbox-row__meta-text').text).to start_with('Suedhang AG · ')
      link = URI(template.at_css('a.inbox-row__link')['href'])
      expect(link.path).to eq(all_inboxes_path)
      expect(Rack::Utils.parse_nested_query(link.query)).to include('state_filters' => %w[read unread])
    end

    it 'draws no assistant although the gate of the organisation is open' do
      allow(ChatPolicy).to receive(:assistant_gate_open?).and_return(true)

      # The same gate opens the trigger in the organisation's own lane.
      get organisation_notifications_path(south, state_filters: %w[read unread], notification: south_row.id), headers: frame
      expect(response.body).to include('data-assistant-context')

      body = lane(south_row.id)
      expect(body).to include('Paket fehlt')
      expect(body).not_to include('data-assistant-context', 'assistant-trigger')
    end
  end

  describe 'a ticket with everything on it' do
    let(:colleague) { create(:user, first_name: 'Kai', last_name: 'Kollege') }
    let(:png) { Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==') }

    let!(:rich) do
      Prosopite.pause do
        make_token_owner_a_member(colleague, south, projects: [south_project])
        ActsAsTenant.with_tenant(south) do
          other = create(:ticket, project: south_project, title: 'Lieferschein pruefen')
          create(:ticket, project: south_project, title: 'Karton nachmessen', parent: south_ticket)
          TicketRelation.create!(source_ticket: south_ticket, target_ticket: other, relation_type: 'relates_to')
          create(:ticket_document, ticket: south_ticket, organisation: south)
          meeting = create(:meeting, project: south_project, organisation: south, title: 'Lagerrunde')
          Reference.create!(source: meeting, target: south_ticket, target_title_snapshot: south_ticket.title)
          NotificationSubscription.create!(user: colleague, subscribable: south_ticket, mode: 'follow')
          blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(png), filename: 'karton.png',
                                                        content_type: 'image/png')
          picture = Post.new(ticket: south_ticket, user: colleague, organisation: south)
          picture.content = %(<div>Foto vom Karton</div><action-text-attachment sgid="#{blob.attachable_sgid}" content-type="image/png" filename="karton.png" filesize="#{blob.byte_size}" width="1" height="1"></action-text-attachment>)
          picture.save!(validate: false)
          third = create(:user)
          make_token_owner_a_member(third, south, projects: [south_project])
          create(:post, ticket: south_ticket, user: colleague, organisation: south, is_private: true,
                        visible_to_user_id: third.id, content: '<div>Nur fuer Dritte</div>')
        end
      end
    end

    it 'renders in the lane above with every address under its organisation or this page' do
      body = lane(south_row.id)
      expect(body).to include('Paket fehlt', 'Lieferschein pruefen', 'test_document.txt')

      foreign = addresses(body).reject do |address|
        address.start_with?("/org/#{south.id}/", '/inbox', '#') || address.empty?
      end
      expect(foreign).to eq([])
      expect(body).not_to include('Nur fuer Dritte')

      timeline = doc(body).at_css('turbo-frame[id^="ticket-timeline-"]')
      get timeline['src'], headers: { 'Turbo-Frame' => timeline['id'] }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Foto vom Karton')
      expect(response.body).not_to include('Nur fuer Dritte')
      expect(session[:current_organisation_id]).to eq(north.id)
    end
  end

  describe 'a comment written in the lane' do
    let(:colleague) { create(:user) }
    let(:twin_ticket) { ticket_in(south, south_project, 'Paket doppelt') }
    let!(:twin_row) { Prosopite.pause { row(south, south_project, twin_ticket, created_at: 4.hours.ago) } }

    before do
      Prosopite.pause do
        make_token_owner_a_member(colleague, south, projects: [south_project])
        ActsAsTenant.with_tenant(south) do
          [south_ticket, twin_ticket].each do |ticket|
            NotificationSubscription.create!(user: colleague, subscribable: ticket, mode: 'follow')
          end
        end
      end
    end

    def reply_action(body, ticket)
      doc(body).at_css(%(form[action$="/tickets/#{ticket.id}/posts"]))['action']
    end

    def counts(ticket)
      ActsAsTenant.with_tenant(south) do
        { posts: Post.where(ticket_id: ticket.id).count,
          activities: Activity.where(organisation_id: south.id).count,
          notifications: Notification.where(notifiable: ticket).where.not(recipient_id: user.id).pluck(:event_type).tally }
      end
    end

    # The comment as the reply form sends it, then its fanout, which the OutboxConsumeJob runs
    # in production (the pattern of spec/requests/api/v1/post_comment_format_spec.rb).
    def comment(action, ticket, text)
      post action, params: { post: { content: "<div>#{text}</div>" } },
                   headers: { 'Turbo-Frame' => 'ticket_display_frame',
                              'Accept' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' }
      expect(response).to have_http_status(:ok)
      Prosopite.pause do
        ActsAsTenant.with_tenant(south) do
          written = Post.where(ticket_id: ticket.id).order(:created_at).last
          activity = Activity.find_by!(action: 'post_added', secondary: written)
          Notifications::FanoutService.new(OutboxEvent.find_by!(activity: activity)).call
        end
      end
    end

    it 'lands in the ticket of its organisation with the trail the organisation page leaves, once' do
      lane_action = reply_action(lane(south_row.id), south_ticket)
      expect(lane_action).to start_with("/org/#{south.id}/")

      get organisation_notifications_path(south, state_filters: %w[read unread], notification: twin_row.id), headers: frame
      page_action = reply_action(response.body, twin_ticket)
      get organisation_notifications_path(north, state_filters: %w[read unread]) # back in north before writing

      before_lane = counts(south_ticket)
      activities_before = before_lane[:activities]
      comment(lane_action, south_ticket, 'Aus der Bahn oben')
      after_lane = counts(south_ticket)
      lane_activities = after_lane[:activities] - activities_before
      expect(session[:current_organisation_id]).to eq(north.id)

      before_page = counts(twin_ticket)
      comment(page_action, twin_ticket, 'Aus der Organisation')
      after_page = counts(twin_ticket)
      page_activities = after_page[:activities] - before_page[:activities]

      expect(after_lane[:posts] - before_lane[:posts]).to eq(1)
      created_project = ActsAsTenant.with_tenant(south) do
        created = Post.where(ticket_id: south_ticket.id).order(:created_at).last
        expect(created.organisation_id).to eq(south.id)
        created.ticket.project_id
      end
      expect(created_project).to eq(south_project.id)
      expect(lane_activities).to eq(1)
      expect(page_activities).to eq(lane_activities)
      lane_notes = after_lane[:notifications].to_h { |kind, n| [kind, n - before_lane[:notifications].fetch(kind, 0)] }
      page_notes = after_page[:notifications].to_h { |kind, n| [kind, n - before_page[:notifications].fetch(kind, 0)] }
      expect(lane_notes.values.sum).to be_positive
      expect(lane_notes).to eq(page_notes)
    end
  end
end
