# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Notifications', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user)
    end
  end

  let(:pat) do
    pat = build(:personal_access_token, user: user, organisations: [organisation], read_only: false)
    pat.token_hash = nil
    pat.token_prefix = nil
    pat.generate_token!
    pat
  end

  # The membership above says the person is in the organisation; this says which of its
  # projects they may still see. InboxQuery narrows the token's reach by both.
  before { make_token_owner_a_member(user, organisation, projects: [project]) }

  def auth_headers
    { 'Authorization' => "Bearer #{pat.token}" }
  end

  describe 'GET /api/v1/notifications' do
    let!(:unread_notif) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation,
                              notifiable: ticket, state: 'queued')
      end
    end

    let!(:read_notif) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation,
                              notifiable: ticket, state: 'read', read_at: 1.hour.ago)
      end
    end

    it 'defaults to unread notifications' do
      get '/api/v1/notifications', headers: auth_headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      ids = body['data'].map { |n| n['id'] }
      expect(ids).to include(unread_notif.id)
      expect(ids).not_to include(read_notif.id)
      expect(body['meta']['unread_total']).to eq(1)
      expect(body['meta']['by_organisation'])
        .to eq([{ 'id' => organisation.id, 'name' => organisation.name, 'unread' => 1 }])
    end

    it 'supports status=read' do
      get '/api/v1/notifications', params: { status: 'read' }, headers: auth_headers
      ids = JSON.parse(response.body)['data'].map { |n| n['id'] }
      expect(ids).to include(read_notif.id)
      expect(ids).not_to include(unread_notif.id)
    end

    it 'supports status=all' do
      get '/api/v1/notifications', params: { status: 'all' }, headers: auth_headers
      ids = JSON.parse(response.body)['data'].map { |n| n['id'] }
      expect(ids).to include(unread_notif.id, read_notif.id)
    end

    it 'excludes notifications from organisations outside the token scope' do
      foreign = ActsAsTenant.with_tenant(other_organisation) do
        create(:notification, recipient: user, organisation: other_organisation, state: 'queued')
      end
      get '/api/v1/notifications', headers: auth_headers
      ids = JSON.parse(response.body)['data'].map { |n| n['id'] }
      expect(ids).not_to include(foreign.id)
    end

    it 'excludes notifications of other users' do
      stranger = create(:user)
      stranger_notif = ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: stranger, organisation: organisation, state: 'queued')
      end
      get '/api/v1/notifications', headers: auth_headers
      ids = JSON.parse(response.body)['data'].map { |n| n['id'] }
      expect(ids).not_to include(stranger_notif.id)
    end

    it 'paginates' do
      get '/api/v1/notifications',
          params: { status: 'all', per_page: 1, page: 1 },
          headers: auth_headers
      body = JSON.parse(response.body)
      expect(body['data'].size).to eq(1)
      expect(body['meta']['total']).to eq(2)
    end

    it 'serializes the notifiable with a title when available' do
      get '/api/v1/notifications', headers: auth_headers
      first = JSON.parse(response.body)['data'].first
      expect(first.dig('notifiable', 'type')).to eq('Ticket')
      expect(first.dig('notifiable', 'id')).to eq(ticket.id)
      expect(first.dig('notifiable', 'title')).to eq(ticket.title)
    end

    # Golden response (D4): the row and meta shape this endpoint answers with is
    # a wire contract for pinned clients. Pinned BEFORE the serializer moved into
    # Notifications::Serializer, so the move can only ADD keys, never drop or
    # rename one. Values are checked where they are deterministic.
    it 'answers with the pinned row and meta shape' do
      get '/api/v1/notifications', headers: auth_headers
      body = JSON.parse(response.body)
      row = body['data'].first

      # `since` joined the meta with the shared query (inbox workflow S1), nil when no bound was given.
      expect(body['meta'].keys).to contain_exactly('page', 'per_page', 'total', 'unread_total', 'since', 'by_organisation')
      expect(body['meta']['since']).to be_nil
      expect(row.keys).to include(
        'id', 'event_type', 'state', 'priority', 'read', 'read_at', 'group_count', 'actor',
        'organisation', 'project', 'notifiable', 'payload', 'first_event_at', 'last_event_at', 'created_at',
        # added with the shared serializer (inbox workflow S1): the readable sentence
        # and, on ticket rows, the address get_ticket takes
        'message', 'ticket'
      )
      expect(row['message']).to be_a(String)
      expect(row['ticket']).to include('id' => ticket.id, 'number' => ticket.number, 'project_id' => project.id)
      expect(row['id']).to eq(unread_notif.id)
      expect(row['state']).to eq('queued')
      expect(row['read']).to be false
      expect(row['read_at']).to be_nil
      expect(row['group_count']).to eq(1)
      expect(row['actor']).to eq('id' => unread_notif.actor_id, 'name' => unread_notif.actor.display_name)
      expect(row['organisation']).to eq('id' => organisation.id, 'name' => organisation.name)
      expect(row['project']).to be_nil # the factory row carries no project
      expect(row['payload']).to eq(unread_notif.payload)
      expect(row['created_at']).to eq(unread_notif.created_at.iso8601)
    end

    # One request per example: Prosopite reads a second identical token lookup
    # as an N+1, and the filters are shared with the MCP tool anyway.
    it 'narrows with since (optional, shared with the MCP tool): activity after the bound' do
      get '/api/v1/notifications', params: { status: 'all', since: 1.minute.from_now.iso8601 }, headers: auth_headers
      body = JSON.parse(response.body)
      expect(body['data']).to be_empty # no activity lies ahead of the bound
      expect(body['meta']['since']).to be_present
    end

    it 'narrows with project_id (optional, shared with the MCP tool): keeps the row of that project, drops the rest' do
      in_project = ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: ticket,
                              project: project, state: 'queued')
      end
      get '/api/v1/notifications', params: { status: 'all', project_id: project.id }, headers: auth_headers
      expect(JSON.parse(response.body)['data'].map { |n| n['id'] }).to eq([in_project.id])
    end

    it 'answers 404 for a project_id outside the token reach, exactly like a missing project' do
      foreign_project = ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
      get '/api/v1/notifications', params: { project_id: foreign_project.id }, headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end

    { status: 'unseen', since: 'gestern', project_id: 'abc', per_page: 'abc' }.each do |key, bad|
      it "answers 400 for an unusable #{key} instead of guessing" do
        get '/api/v1/notifications', params: { key => bad }, headers: auth_headers
        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)['message']).to include(key.to_s)
      end
    end

    # `?page[]=1` arrives as an Array, `?per_page[a]=1` as a nested hash; `.to_i`
    # on either raised NoMethodError into a 500 before the query owned the parsing.
    it 'answers 400, not 500, for page or per_page of the wrong shape' do
      get '/api/v1/notifications', params: { page: ['1'] }, headers: auth_headers
      expect(response).to have_http_status(:bad_request)
      get '/api/v1/notifications', params: { per_page: { a: '1' } }, headers: auth_headers
      expect(response).to have_http_status(:bad_request)
    end

    # The documented query-string gotcha: an unencoded + in the offset decodes to
    # a space and is refused; encoded, the same bound is read as the same instant.
    it 'refuses an unencoded + in the offset of since (400) and reads the encoded form' do
      get '/api/v1/notifications?since=2026-08-26T10:00:00+02:00', headers: auth_headers
      expect(response).to have_http_status(:bad_request)
      get '/api/v1/notifications?since=2026-08-26T10%3A00%3A00%2B02%3A00', headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig('meta', 'since')).to eq('2026-08-26T08:00:00Z')
    end

    # The token's PROJECT scope is part of its contract (PersonalAccessToken#accessible_project?):
    # a token linked to one project of the organisation must not list the inbox rows
    # of its other projects. Rows without a project (system messages) stay visible.
    context 'with a token restricted to one project of the organisation' do
      let(:other_project) do
        ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      end

      # Access granted on purpose: the examples below are about what the TOKEN links, so the
      # unlinked project must be refused for that reason and not for a missing right.
      before { make_token_owner_a_member(user, organisation, projects: [other_project]) }
      let(:pat) do
        pat = build(:personal_access_token, user: user, organisations: [organisation],
                                            project_scopes: { organisation => [project] }, read_only: false)
        pat.token_hash = nil
        pat.token_prefix = nil
        pat.generate_token!
        pat
      end
      let!(:linked_row) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification, recipient: user, organisation: organisation, notifiable: ticket,
                                project: project, state: 'queued')
        end
      end
      let!(:unlinked_row) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification, recipient: user, organisation: organisation, notifiable: ticket,
                                project: other_project, state: 'queued')
        end
      end

      it 'lists rows of the linked project and project-less rows, never the unlinked project' do
        get '/api/v1/notifications', headers: auth_headers
        ids = JSON.parse(response.body)['data'].map { |n| n['id'] }
        expect(ids).to include(linked_row.id, unread_notif.id)
        expect(ids).not_to include(unlinked_row.id)
        expect(JSON.parse(response.body).dig('meta', 'unread_total')).to eq(2)
      end

      it "answers 404 for mark_as_read on the unlinked project's row and leaves it untouched" do
        post "/api/v1/notifications/#{unlinked_row.id}/mark_as_read", headers: auth_headers
        expect(response).to have_http_status(:not_found)
        expect(unlinked_row.reload.state).to eq('queued')
      end

      it 'mark_all_as_read touches only the linked and the project-less rows, and names exactly them' do
        post '/api/v1/notifications/mark_all_as_read', headers: auth_headers
        body = JSON.parse(response.body)['data']
        expect(body['marked_read_ids']).to contain_exactly(linked_row.id, unread_notif.id)
        expect(body['marked_read_count']).to eq(2)
        expect(linked_row.reload.state).to eq('read')
        expect(unlinked_row.reload.state).to eq('queued')
      end
    end
  end

  # The member actions look the row up through the inbox query: only in_app rows
  # (the inbox), not the email-channel twin the fanout creates for the same event.
  it 'answers 404 for mark_as_read on an email-channel row of the owner, leaving it untouched' do
    email_row = ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: user, organisation: organisation, notifiable: ticket,
                            channel: 'email', state: 'queued')
    end
    post "/api/v1/notifications/#{email_row.id}/mark_as_read", headers: auth_headers
    expect(response).to have_http_status(:not_found)
    expect(email_row.reload.state).to eq('queued')
  end

  # The row belongs to the owner; the token reach is the ONLY reason for the 404.
  # Before the shared query the member actions looked the row up by owner alone.
  describe 'member actions on a row of the owner outside the token reach' do
    let!(:outside) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:notification, recipient: user, organisation: other_organisation, state: 'queued')
      end
    end

    %w[mark_as_read archive].each do |action|
      it "answers 404 for #{action} and leaves the row untouched" do
        post "/api/v1/notifications/#{outside.id}/#{action}", headers: auth_headers
        expect(response).to have_http_status(:not_found)
        expect(outside.reload.state).to eq('queued')
      end
    end
  end

  describe 'POST /api/v1/notifications/:id/mark_as_read' do
    let!(:n) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: ticket, state: 'queued')
      end
    end

    it 'marks the notification as read' do
      post "/api/v1/notifications/#{n.id}/mark_as_read", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(n.reload.state).to eq('read')
      expect(n.read_at).to be_present
    end

    it 'returns 404 for another user’s notification' do
      stranger = create(:user)
      foreign = ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: stranger, organisation: organisation, notifiable: ticket, state: 'queued')
      end
      post "/api/v1/notifications/#{foreign.id}/mark_as_read", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/notifications/:id/archive' do
    let!(:n) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: ticket, state: 'queued')
      end
    end

    it 'archives the notification' do
      post "/api/v1/notifications/#{n.id}/archive", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(n.reload.state).to eq('archived')
    end
  end

  describe 'POST /api/v1/notifications/mark_all_as_read' do
    let!(:unread_a) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: ticket, state: 'queued')
      end
    end
    let!(:unread_b) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: ticket, state: 'queued')
      end
    end

    it 'marks all unread notifications as read' do
      post '/api/v1/notifications/mark_all_as_read', headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig('data', 'marked_read_count')).to eq(2)
      expect(unread_a.reload.state).to eq('read')
      expect(unread_b.reload.state).to eq('read')
    end

    # The bulk update goes through Notification.bulk_transition!, which refreshes
    # the org switcher signal (Notifications::UnreadSignals) for a touched mention.
    it 'refreshes the org switcher signal of the owner' do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: ticket,
                              event_type: 'mention', state: 'queued')
      end
      ActiveJob::Base.queue_adapter = :test
      expect { post '/api/v1/notifications/mark_all_as_read', headers: auth_headers }
        .to have_enqueued_job(Notifications::UnreadSignalsJob).with(user_id: user.id)
    end

    it 'does not touch notifications outside the token scope' do
      other_org = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other_org) do
        create(:notification, recipient: user, organisation: other_org, state: 'queued')
      end
      post '/api/v1/notifications/mark_all_as_read', headers: auth_headers
      expect(foreign.reload.state).to eq('queued')
    end
  end
end
