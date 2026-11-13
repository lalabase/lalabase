# frozen_string_literal: true

require 'rails_helper'

# What: the live side of the inbox above the organisations (GET /inbox). The page
#       subscribes to one stream per person (Notifications::Streams.all_inboxes),
#       draws the stamp of its list (Notifications::InboxQuery.stamp) and redraws
#       itself through GET /inbox as turbo_stream: the list and every count, or the
#       counts alone (part=counts).
# Why:  the stream is the one place where something reaches the page without a
#       request of its own, so it must stay the person's, without an organisation,
#       and never subscribed by an organisation's page. The redraw is the page's
#       own reader again: what the rule per organisation hides stays hidden.
RSpec.describe 'Live inbox above the organisations', :ci_guard, type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }

  def project_in(org, **attributes)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org, **attributes) }
  end

  def ticket_row(org, project, title, recipient: user, state: :delivered, created_at: Time.current)
    ActsAsTenant.with_tenant(org) do
      ticket = create(:ticket, project: project, title: title)
      create(:notification, recipient: recipient, organisation: org, project: project, notifiable: ticket,
                            event_type: 'ticket_commented', channel: 'in_app', state: state, created_at: created_at,
                            read_at: %i[read archived].include?(state) ? 1.hour.ago : nil)
    end
  end

  let(:north_project) { project_in(north, name: 'Lager') }
  let(:south_project) { project_in(south, name: 'Versand') }

  let!(:north_row) do
    Prosopite.pause do
      make_token_owner_a_member(user, north, projects: [north_project])
      ticket_row(north, north_project, 'Regal wackelt', created_at: 2.hours.ago)
    end
  end
  let!(:south_row) do
    Prosopite.pause do
      make_token_owner_a_member(user, south, projects: [south_project])
      ticket_row(south, south_project, 'Paket fehlt', created_at: 1.hour.ago)
    end
  end

  before { sign_in user }

  after { ActsAsTenant.current_tenant = nil }

  def stamp
    Notifications::InboxQuery.stamp(user: user, reach: PersonalAccessToken::Reach.for_person(user))
  end

  def streams_of(body)
    Nokogiri::HTML(body).css('turbo-cable-stream-source').map do |source|
      Turbo::StreamsChannel.verified_stream_name(source['signed-stream-name'])
    end
  end

  def redraw(**params)
    get all_inboxes_path(**params), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('text/vnd.turbo-stream.html')
    Nokogiri::HTML(response.body)
  end

  def targets(doc)
    doc.css('turbo-stream').pluck('target')
  end

  def listed_ids(doc)
    template = doc.at_css('turbo-stream[target="inbox_master_list"] template')
    expect(template).to be_present
    template.css('.inbox-row').pluck('data-notification-id')
  end

  describe 'the stream' do
    it 'is the person\'s own, without an organisation, and the only one of the page' do
      get all_inboxes_path

      expect(streams_of(response.body)).to eq([Notifications::Streams.all_inboxes(user)])
      expect(Notifications::Streams.all_inboxes(user)).not_to include(north.id, south.id)
    end

    it 'is never subscribed by the inbox of an organisation' do
      get organisation_notifications_path(north, state_filters: %w[read unread])
      expect(response).to have_http_status(:ok)

      names = streams_of(response.body)
      expect(names).to include(Notifications::Streams.notifications(user, north))
      expect(names).not_to include(Notifications::Streams.all_inboxes(user))
    end
  end

  describe 'the page' do
    it 'draws the signal and the list with the same stamp, the banner hidden' do
      get all_inboxes_path
      doc = Nokogiri::HTML(response.body)

      expect(doc.at_css('#all_inboxes_signal')['data-stamp']).to eq(stamp)
      expect(doc.at_css('#notifications_list_frame #all_inboxes_drawn_stamp')['data-stamp']).to eq(stamp)
      banner = doc.at_css('#all_inboxes_banner')
      expect(banner['class'].split).to include('hidden')
      expect(banner.text).to include(I18n.t('views.organisations.notifications.new_banner.text'))
      expect(doc.at_css('[data-controller~="all-inboxes-live"]')['data-all-inboxes-live-url-value']).to eq(all_inboxes_path)
    end

    it 'is not kept for Back: Turbo fetches it again' do
      get all_inboxes_path

      expect(Nokogiri::HTML(response.body).at_css('meta[name="turbo-cache-control"]')['content']).to eq('no-cache')
    end
  end

  describe 'the redraw' do
    it 'redraws the list, the stamp and every count' do
      doc = redraw

      expect(targets(doc)).to contain_exactly('inbox_master_list', 'all_inboxes_drawn_stamp', 'inbox_unread_count',
                                              'inbox_list_tools', 'all_inboxes_nav')
      expect(listed_ids(doc)).to eq([south_row.id, north_row.id])
      expect(doc.at_css('turbo-stream[target="all_inboxes_drawn_stamp"] template [data-stamp]')['data-stamp']).to eq(stamp)
      expect(doc.at_css('turbo-stream[target="all_inboxes_nav"]').inner_html).to include('Nordwind GmbH', 'Suedhang AG')
    end

    it 'redraws the counts alone with part=counts: no list, no stamp' do
      doc = redraw(part: 'counts')

      expect(targets(doc)).to contain_exactly('inbox_unread_count', 'inbox_list_tools', 'all_inboxes_nav')
    end

    it 'shows a row that arrived after the page was drawn' do
      get all_inboxes_path
      drawn = stamp
      newer = Prosopite.pause { ticket_row(south, south_project, 'Neu da') }

      doc = redraw
      expect(listed_ids(doc).first).to eq(newer.id)
      expect(stamp).not_to eq(drawn)
    end

    it 'keeps the filter of the page: one organisation, one status view' do
      Prosopite.pause { ticket_row(north, north_project, 'Gelesen', state: :read) }

      doc = redraw(org: north.id, state_filters: ['unread'])
      expect(listed_ids(doc)).to eq([north_row.id])
    end

    it 'keeps the pages the endless scroll has loaded' do
      size = Inbox::MasterListPresenter::PAGE_SIZE
      Prosopite.pause do
        size.times { |i| ticket_row(north, north_project, "Mehr #{i}", created_at: (3 + i).hours.ago) }
      end

      expect(listed_ids(redraw(page: 1)).size).to eq(size)
      expect(listed_ids(redraw(page: 1, through_page: 2)).size).to eq(size + 2)
    end

    it 'leaves out a row of a project the person may not read' do
      hidden_project = project_in(south, name: 'Geheim')
      Prosopite.pause { ticket_row(south, hidden_project, 'Hinter der Tuer') }

      doc = redraw
      expect(listed_ids(doc)).to contain_exactly(north_row.id, south_row.id)
      expect(response.body).not_to include('Hinter der Tuer')
    end

    it 'leaves out an organisation the person was deactivated in, rows and name' do
      third = create(:organisation, name: 'Dritte KG')
      Prosopite.pause do
        project = project_in(third)
        make_token_owner_a_member(user, third, projects: [project])
        ticket_row(third, project, 'Aus alter Zeit')
        Membership.find_by(user: user, organisation: third).update!(active: false)
      end

      doc = redraw
      expect(listed_ids(doc)).to contain_exactly(north_row.id, south_row.id)
      expect(response.body).not_to include('Dritte KG', 'Aus alter Zeit')
    end

    it 'answers an organisation outside the reach like a missing one' do
      elsewhere = create(:organisation, name: 'Fremd KG')

      get all_inboxes_path(org: elsewhere.id), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:not_found)
    end

    it 'does not move the organisation of the session' do
      get organisation_notifications_path(north)
      expect(session[:current_organisation_id]).to eq(north.id)

      redraw(org: south.id)
      expect(session[:current_organisation_id]).to eq(north.id)
    end
  end

  describe 'the answer of a row action' do
    it 'carries the new stamp with the redrawn list, and a toast' do
      patch all_inbox_mark_read_path(south_row), headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      doc = Nokogiri::HTML(response.body)

      expect(doc.at_css('turbo-stream[target="all_inboxes_drawn_stamp"] template [data-stamp]')['data-stamp']).to eq(stamp)
      expect(targets(doc)).to include('flash_messages')
    end
  end
end
