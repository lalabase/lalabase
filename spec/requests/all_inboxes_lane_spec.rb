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

      # They take the page's list state when they leave (review S3b round 2): the head through
      # inbox-lane-head, the timer through followAddress. Inside an organisation neither.
      head = doc(body).at_css('#inbox_pane_status_pills')
      expect(head['data-controller']).to eq('inbox-lane-head')
      expect(head.css('form').pluck('data-action')).to all(eq('submit->inbox-lane-head#carry'))
      expect(doc(body).at_css('[data-pane-mark-read-delay-follow-address-value="true"]')).to be_present
      get organisation_notifications_path(south, state_filters: %w[read unread], notification: south_row.id), headers: frame
      inside = doc(response.body)
      expect(inside.at_css('#inbox_pane_status_pills')).to be_present
      expect(inside.at_css('#inbox_pane_status_pills')['data-controller']).to be_nil
      expect(inside.at_css('[data-pane-mark-read-delay-follow-address-value]')).to be_nil

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

  describe 'assistant context after lane writes' do
    let(:lane_referrer) { "http://www.example.com#{all_inboxes_path(notification: south_row.id)}" }
    let(:write_headers) do
      { 'Turbo-Frame' => 'writing_surface', 'Accept' => 'text/vnd.turbo-stream.html', 'Referer' => lane_referrer }
    end

    before { allow(ChatPolicy).to receive(:assistant_gate_open?).and_return(true) }

    it 'keeps assistant controls absent after editing the ticket' do
      expect(lane(south_row.id)).not_to include('data-controller="assistant-trigger"')
      patch organisation_project_ticket_path(south, south_project, south_ticket),
            params: { ticket: { title: 'Paket wiedergefunden' } }, headers: write_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('target="ticket_display_frame"', 'Paket wiedergefunden')
      expect(response.body).not_to include('data-controller="assistant-trigger"', 'data-assistant-context')
    end

    it 'keeps assistant controls absent after posting a comment' do
      action = doc(lane(south_row.id)).at_css(%(form[action$="/tickets/#{south_ticket.id}/posts"]))['action']
      post action, params: { post: { content: '<div>Paket ist da</div>' } },
                   headers: write_headers.merge('Turbo-Frame' => 'ticket_display_frame')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Paket ist da')
      expect(response.body).not_to include('data-controller="assistant-trigger"', 'data-assistant-context')
    end

    it 'enables the assistant when visiting the full ticket page from the inbox' do
      get organisation_project_ticket_path(south, south_project, south_ticket), headers: { 'Referer' => lane_referrer }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="assistant-trigger"', 'data-assistant-context')
    end

    # A frame the lane loads is a GET and still no page: it keeps the page it is drawn on.
    # The same frame from the organisation's own page draws the trigger, so its absence
    # is the rule's answer and not the fragment's.
    it 'keeps assistant controls absent in a frame loaded from this page' do
      in_frame = { 'Turbo-Frame' => 'ticket_display_frame' }
      own_page = "http://www.example.com#{organisation_project_tickets_path(south, south_project)}"
      get organisation_project_ticket_path(south, south_project, south_ticket), headers: in_frame.merge('Referer' => own_page)
      expect(response.body).to include('Paket fehlt', 'data-controller="assistant-trigger"')

      get organisation_project_ticket_path(south, south_project, south_ticket), headers: in_frame.merge('Referer' => lane_referrer)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Paket fehlt')
      expect(response.body).not_to include('data-controller="assistant-trigger"', 'data-assistant-context')
    end

    # Only this page counts as the page above: the same host, the same port, the path of
    # /inbox itself. Each line is one near miss, and each leaves the fragment the context
    # of its ticket (the trigger is drawn). The lines are also the proof that the absent
    # trigger in the examples above is the rule's answer.
    {
      'no referrer' => nil,
      'another host' => 'http://elsewhere.example/inbox',
      'another port of this host' => 'http://www.example.com:8080/inbox',
      'the inbox of an organisation' => -> { "http://www.example.com#{organisation_notifications_path(south, notification: south_row.id)}" },
      'a path that only begins like this page' => 'http://www.example.com/inboxes',
      'a path below this page' => 'http://www.example.com/inbox/archive',
      'a referrer that is no address' => 'http://www.example.com/in box'
    }.each do |from, referrer|
      it "leaves a fragment its own context when it comes from #{from}" do
        referrer = instance_exec(&referrer) if referrer.respond_to?(:call)
        headers = write_headers.except('Referer')
        headers['Referer'] = referrer if referrer
        patch organisation_project_ticket_path(south, south_project, south_ticket),
              params: { ticket: { title: 'Paket da' } }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Paket da', 'data-controller="assistant-trigger"')
      end
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

  # Audit of the lane's writes on /inbox (plan §5.6), finding F1: a summary the instance cannot
  # make (:not_configured) answered with redirect_back, which from the lane above is the whole
  # page /inbox. Turbo follows it for the timeline frame, which that page does not draw (its
  # lane loads by a request of its own), and the timeline showed "Content missing". It now
  # answers in the stream, as every other refused summary does.
  it 'keeps the timeline of the lane when the summary cannot be made' do
    body = lane(south_row.id)
    timeline = doc(body).at_css('turbo-frame[id^="ticket-timeline-"]')
    allow_any_instance_of(TicketSummaryService).to receive(:call)
      .and_return(TicketSummaryService::Result.new(status: :not_configured))

    post create_summary_organisation_project_ticket_path(south, south_project, south_ticket),
         headers: { 'Turbo-Frame' => timeline['id'], 'Accept' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml',
                    'Referer' => "http://www.example.com#{all_inboxes_path(**list_state, notification: south_row.id)}" }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('text/vnd.turbo-stream.html')
    expect(response.body).to include('turbo-stream action="prepend" target="flash"')
    expect(session[:current_organisation_id]).to eq(north.id)
  end

  # Mutation probes of S3b (round 1) that no example caught, each pinned here.
  describe 'what the probes asked for' do
    # The notification stays readable (its project is), the ticket moved into a project the
    # person cannot read: only `authorize @ticket, :show?` stands between them.
    it 'refuses a ticket that moved into a project the person cannot read, and the organisation keeps its notice' do
      hidden_project = project_in(south, name: 'Geheim')
      ActsAsTenant.with_tenant(south) { south_ticket.update_column(:project_id, hidden_project.id) }

      expect(lane(north_row.id)).to include('Regal wackelt')
      expected = missing_body
      body = lane(south_row.id)
      expect(body).to eq(expected)
      expect(body).not_to include('Paket fehlt', 'Karton leer')

      get organisation_notifications_path(south, state_filters: %w[read unread], notification: south_row.id), headers: frame
      expect(response.body).to include(I18n.t('views.organisations.notifications.pane.unauthorized_title'))
      expect(response.body).not_to include('Karton leer')
    end

    # Review S3b round 2: the shared loader finds the row through the policy scope, so the
    # organisation's own lane answers a row of an area the person lost as missing, not as
    # "not allowed" (which would say the row exists).
    it 'answers a row of a lost area in the lane of the organisation as missing' do
      get organisation_notifications_path(south, state_filters: %w[read unread], notification: south_row.id), headers: frame
      expect(response.body).to include('Paket fehlt')
      ActsAsTenant.with_tenant(south) do
        ProjectPermission.find_by!(user: user, project: south_project).update!(tickets_access: 'no_access')
      end
      get organisation_notifications_path(south, state_filters: %w[read unread], notification: south_row.id), headers: frame
      expect(response.body).to include(I18n.t('views.organisations.notifications.pane.missing_title'))
      expect(response.body).not_to include(I18n.t('views.organisations.notifications.pane.unauthorized_title'))
    end

    it 'lists in-app rows only under "what was new", not their mail twins' do
      Prosopite.pause do
        row(south, south_project, south_ticket, created_at: 30.minutes.ago)
        row(south, south_project, south_ticket, channel: 'email', created_at: 20.minutes.ago)
      end
      body = lane(south_row.id)
      expect(doc(body).css('.inbox-new-activity__item').size).to eq(2)
    end

    it 'draws the page without ?notification= with the lane shut and its empty frame' do
      get all_inboxes_path(**list_state)
      page = doc
      expect(page.at_css('[data-controller~="layout-toggle"]')['class']).not_to include('show-content')
      expect(page.at_css('turbo-frame#ticket_pane')['src']).to be_nil
      expect(page.at_css('.layout')['class']).to include('hide-content')
    end

    it 'draws the lane of an organisation open on a full load with ?notification=, on the shared frame' do
      get organisation_notifications_path(south, state_filters: %w[read unread], notification: south_row.id)
      page = doc
      expect(page.at_css('[data-controller="layout-toggle index-page"]')['class']).to include('show-content')
      expect(page.at_css('.layout')['class']).to include('show-content')
      expect(page.at_css('turbo-frame#ticket_pane')).to be_present
    end

    # in_lane_organisation itself: inside the block the request has the lane's organisation
    # (tenant, the instance variables the partials read, Current), afterwards what it had,
    # also when the block raises. A request spec cannot see the restore: nothing renders
    # after the block, and Rails resets the tenant after every request.
    it 'gives the block the organisation of the lane and puts the request back afterwards, also after a raise' do
      controller = AllInboxesController.new
      allow(controller).to receive(:current_user).and_return(user)
      controller.instance_variable_set(:@current_organisation, nil)
      Current.organisation = nil
      ActsAsTenant.current_tenant = nil

      seen = nil
      controller.send(:in_lane_organisation, south) do
        seen = [ActsAsTenant.current_tenant, controller.instance_variable_get(:@current_organisation),
                controller.instance_variable_get(:@current_membership)&.organisation_id, Current.organisation]
      end
      expect(seen).to eq([south, south, south.id, south])
      expect([ActsAsTenant.current_tenant, controller.instance_variable_get(:@current_organisation),
              controller.instance_variable_get(:@current_membership), Current.organisation]).to eq([nil, nil, nil, nil])

      expect { controller.send(:in_lane_organisation, south) { raise ArgumentError, 'pane broke' } }
        .to raise_error(ArgumentError)
      expect([ActsAsTenant.current_tenant, controller.instance_variable_get(:@current_organisation),
              Current.organisation]).to eq([nil, nil, nil])
    end
  end

  # S4: a row that is not about a ticket. A row about a project reports one of its events;
  # Inbox::LaneKind says what the lane shows for it. Above the organisations the lane's chrome
  # is this page's, and the body of a note is a frame the NOTE's controller draws under
  # /org/<the organisation of the row>/: a frame load, which does not move the session.
  describe 'a row that is not about a ticket' do
    let(:colleague) { create(:user, first_name: 'Kai', last_name: 'Kollege') }

    def note_in(org, project, title)
      ActsAsTenant.with_tenant(org) { create(:note, project: project, organisation: org, creator: colleague, title: title) }
    end

    def allow_areas(org, project, **areas)
      ActsAsTenant.with_tenant(org) { ProjectPermission.find_by!(user: user, project: project).update!(**areas) }
    end

    def note_row_in(org, project, note, **options)
      Prosopite.pause do
        project_event_row(org, project, 'note_created', recipient: user, actor: colleague, secondary: note,
                                                        parameters: { 'note_title' => note.title }, **options)
      end
    end

    let(:south_note) { note_in(south, south_project, 'Protokoll Versand') }
    let(:north_note) { note_in(north, north_project, 'Protokoll Lager') }
    let!(:south_note_row) do
      allow_areas(south, south_project, notes_access: 'read_write', members_access: 'read_only')
      note_row_in(south, south_project, south_note, created_at: 30.minutes.ago)
    end
    let!(:north_note_row) do
      allow_areas(north, north_project, notes_access: 'read_write')
      note_row_in(north, north_project, north_note, created_at: 40.minutes.ago)
    end

    def note_frame_of(body)
      doc(body).at_css('turbo-frame#ticket_pane turbo-frame#ticket_display_frame')
    end

    it 'answers the chrome of this page and a frame that loads the note under its organisation' do
      body = lane(south_note_row.id, org: south.id)

      expect(body).not_to include('<html', 'id="inbox_master_list"')
      inner = note_frame_of(body)
      path, query = inner['src'].split('?')
      expect(path).to eq("/org/#{south.id}/projects/#{south_project.id}/notes/#{south_note.id}")
      expect(Rack::Utils.parse_query(query)).to eq('frame' => 'content', 'frame_id' => 'ticket_display_frame')
      expect(doc(body).at_css('.inbox-lane-head__project').text).to eq('Versand')

      # The head's actions and the timer are this page's, with the list state and the open row.
      forms = doc(body).css('#inbox_pane_status_pills form').pluck('action')
      expect(forms).not_to be_empty
      forms.each do |action|
        uri = URI(action)
        expect(uri.path).to match(%r{\A/inbox/#{south_note_row.id}/(mark_read|mark_unread|archive)\z})
        expect(Rack::Utils.parse_nested_query(uri.query))
          .to include('state_filters' => %w[read unread], 'org' => south.id, 'notification' => south_note_row.id)
      end
      timer = URI(doc(body).at_css('[data-pane-mark-read-delay-url-value]')['data-pane-mark-read-delay-url-value'])
      expect(timer.path).to eq("/inbox/#{south_note_row.id}/mark_read")
      expect(Rack::Utils.parse_nested_query(timer.query))
        .to include('state_filters' => %w[read unread], 'notification' => south_note_row.id, 'quiet' => '1')
      expect(doc(body).at_css('#inbox_pane_status_pills a.inbox-lane-actions__open')['href'])
        .to eq("/org/#{south.id}/projects/#{south_project.id}/notes/#{south_note.id}")

      # No inbox address under /org/ but the full view of the redrawn row (a tap below lg).
      inbox_addresses = addresses(body).grep(%r{/org/[^/]+/inbox/})
      expect(inbox_addresses).to eq(doc(body).css('[data-inbox-master-item-fullview-url-value]')
                                             .map { |node| node['data-inbox-master-item-fullview-url-value'] })
      expect(inbox_addresses).to all(end_with('/open?source=inbox'))
      # The redrawn row names its organisation and keeps the title of the note.
      template = doc(body).at_css(%(turbo-stream[action="replace"][target="notification_#{south_note_row.id}"] template))
      expect(template.at_css('.inbox-row__meta-text').text).to start_with('Suedhang AG · ')
      expect(template.at_css('.inbox-row__title').text).to eq('Protokoll Versand')
    end

    it 'keeps the session in the organisation it was in and leaves no tenant on the thread' do
      lane(south_note_row.id)
      expect(session[:current_organisation_id]).to eq(north.id)
      expect(ActsAsTenant.current_tenant).to be_nil
    end

    it 'leaves no tenant on the thread when the pane of a note row raises' do
      allow_any_instance_of(Inbox::LaneKind).to receive(:frame_path).and_raise(ArgumentError, 'pane broke')
      expect { get all_inboxes_path(**list_state, notification: south_note_row.id), headers: frame }
        .to raise_error(ActionView::Template::Error, /pane broke/)
      expect(ActsAsTenant.current_tenant).to be_nil
      expect(session[:current_organisation_id]).to eq(north.id)
    end

    it 'loads the note through its own controller, which leaves the session where it is' do
      address = note_frame_of(lane(south_note_row.id))['src']

      get address, headers: { 'Turbo-Frame' => 'ticket_display_frame', 'Referer' => "http://www.example.com#{all_inboxes_path}" }

      expect(response).to have_http_status(:ok)
      answer = doc(response.body)
      expect(answer.at_css('turbo-frame#ticket_display_frame [data-lane-title]').text).to eq('Protokoll Versand')
      expect(response.body).not_to include('<html')
      expect(session[:current_organisation_id]).to eq(north.id)
    end

    # The page above has no assistant panel. The note's frame is drawn by the note's own
    # controller, which learns the page it is drawn on from the referrer (S3): the same frame
    # from the organisation's own page draws the trigger, so its absence here is the rule's
    # answer and not the fragment's.
    it 'draws no assistant in the frame of the note although the gate of the organisation is open' do
      allow(ChatPolicy).to receive(:assistant_gate_open?).and_return(true)
      address = note_frame_of(lane(south_note_row.id))['src']
      in_frame = { 'Turbo-Frame' => 'ticket_display_frame' }

      get address, headers: in_frame.merge('Referer' => "http://www.example.com#{organisation_notifications_path(south)}")
      expect(response.body).to include('Protokoll Versand', 'data-controller="assistant-trigger"', 'data-assistant-context')

      get address, headers: in_frame.merge('Referer' => "http://www.example.com#{all_inboxes_path(notification: south_note_row.id)}")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Protokoll Versand')
      expect(response.body).not_to include('data-controller="assistant-trigger"', 'data-assistant-context')
      expect(session[:current_organisation_id]).to eq(north.id)
    end

    it 'answers the card of a new member of another organisation' do
      member_row = Prosopite.pause do
        project_event_row(south, south_project, 'member_added', recipient: user, actor: colleague,
                                                                parameters: { 'user_name' => 'Mia Neu' })
      end

      body = lane(member_row.id)

      card = doc(body).at_css('turbo-frame#ticket_pane [data-inbox-event-card="member_added"]')
      expect(card.at_css('.inbox-lane-notice__body').text).to include('Kai Kollege', 'Mia Neu')
      expect(card.css('a').map { |a| a['href'] }).to eq(["/org/#{south.id}/projects/#{south_project.id}"])
      expect(doc(body).css('#inbox_pane_status_pills form').pluck('action')).to all(start_with("/inbox/#{member_row.id}/"))
      expect(note_frame_of(body)).to be_nil
      expect(session[:current_organisation_id]).to eq(north.id)
    end

    # Each rule on the lane request for a NOTE row, each its own example: every refused row
    # answers what a row that does not exist answers. Before each refusal the same example
    # sees the lane of a readable note row.
    describe 'that the person may not open' do
      def expect_readable_note_row_opens
        expect(note_frame_of(lane(north_note_row.id))['src']).to include("/notes/#{north_note.id}")
      end

      def expect_refused(notification_id)
        expect_readable_note_row_opens
        expected = missing_body
        expect(expected).to include('id="ticket_pane"')
        expect(lane(notification_id)).to eq(expected)
      end

      it 'refuses a note row of a project the person lost' do
        hidden_project = project_in(south, name: 'Geheim')
        hidden = note_row_in(south, hidden_project, note_in(south, hidden_project, 'Geheimes Protokoll'))
        expect_refused(hidden.id)
      end

      it 'refuses a note row once the person lost the notes area' do
        allow_areas(south, south_project, notes_access: 'no_access')
        expect_refused(south_note_row.id)
      end

      it 'refuses a note row of an archived project' do
        ActsAsTenant.with_tenant(south) { south_project.update!(archived_at: 1.day.ago) }
        expect_refused(south_note_row.id)
      end

      it 'refuses a note row of an organisation the person was deactivated in' do
        Membership.find_by(user: user, organisation: south).update!(active: false)
        expect_refused(south_note_row.id)
      end

      it 'refuses a note row of an organisation the person was removed from' do
        Membership.find_by(user: user, organisation: south).destroy!
        expect_refused(south_note_row.id)
      end

      it "refuses another person's note row" do
        other = create(:user)
        theirs = Prosopite.pause do
          make_token_owner_a_member(other, south, projects: [south_project], area: :notes)
          project_event_row(south, south_project, 'note_created', recipient: other, actor: colleague, secondary: south_note,
                                                                  parameters: { 'note_title' => south_note.title })
        end
        expect_refused(theirs.id)
      end

      it 'refuses the mail twin of a note row' do
        mail = note_row_in(south, south_project, south_note, channel: 'email')
        expect_refused(mail.id)
      end

      it 'refuses a malformed id' do
        expect_refused('not-a-note-row')
      end

      # No real state reaches this (the row and the note ask the same area of the same
      # project), so the note's policy is stubbed: the loader asks it, and above the answer
      # is the one body of every refusal, not "not allowed" (which says the row exists).
      it 'refuses a note row whose note the policy refuses' do
        expect_readable_note_row_opens
        expected = missing_body
        allow_any_instance_of(NotePolicy).to receive(:show?).and_return(false)

        expect(lane(south_note_row.id)).to eq(expected)
      end

      it 'refuses a row about a subject without an entry' do
        person_row = Prosopite.pause do
          ActsAsTenant.with_tenant(south) do
            create(:notification, recipient: user, organisation: south, notifiable: create(:person, organisation: south),
                                  channel: 'in_app', state: :delivered)
          end
        end
        get organisation_notifications_path(south, state_filters: %w[read unread], notification: person_row.id), headers: frame
        expect(response.body).to include(I18n.t('views.organisations.notifications.pane.non_ticket_title'))
        get organisation_notifications_path(north, state_filters: %w[read unread])

        expect_refused(person_row.id)
      end
    end

    # No read with the tenant lifted, for the tables a note row touches: the notification,
    # the activity its payload names, the project and the note.
    it 'reads notifications, activities, projects and notes only under the tenant of an organisation of the person' do
      reads = []
      sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        table = payload[:sql][/FROM "(notifications|activities|projects|notes)"/, 1]
        reads << [table, ActsAsTenant.current_tenant] if table
      end
      allow(ActsAsTenant).to receive(:without_tenant).and_call_original

      lane(south_note_row.id)

      expect(reads.map(&:first)).to include('notifications', 'activities', 'projects', 'notes')
      expect(reads.map(&:last)).to all(be_present)
      expect(reads.map(&:last).uniq - [north, south, west]).to eq([])
      expect(reads.select { |table, _| %w[activities projects notes].include?(table) }.map(&:last).uniq).to eq([south])
      expect(ActsAsTenant).not_to have_received(:without_tenant)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end
end
