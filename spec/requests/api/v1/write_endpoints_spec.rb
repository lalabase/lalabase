# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Write Endpoints', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
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

  let!(:project_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: project, tickets_access: :read_write)
    end
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user)
    end
  end

  # Writable on purpose: the default token is read-only, and the examples below are about
  # what the user's rights allow. The read-only refusal has its own block at the end.
  let(:pat) do
    pat = build(:personal_access_token, user: user, organisations: [organisation], read_only: false)
    pat.token_hash = nil
    pat.token_prefix = nil
    pat.generate_token!
    pat
  end

  def auth_headers
    { 'Authorization' => "Bearer #{pat.token}" }
  end

  # Set the tenant via thread-local so it survives request callbacks
  # (Post/TimeSession in the change-matcher need tenant set).
  before { ActsAsTenant.current_tenant = organisation }

  # ------------------------------------------------------------------
  # POST /api/v1/tickets/:id/posts
  # ------------------------------------------------------------------
  describe 'POST /api/v1/tickets/:ticket_id/posts' do
    it 'creates a public post' do
      expect do
        post "/api/v1/tickets/#{ticket.id}/posts",
             params: { post: { body: 'Mein neuer Kommentar' } },
             headers: auth_headers
      end.to change { ActsAsTenant.with_tenant(organisation) { Post.count } }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig('data', 'is_private')).to be false
      expect(body.dig('data', 'body_text')).to include('Mein neuer Kommentar')
      expect(body.dig('data', 'author', 'id')).to eq(user.id)
    end

    it 'creates a private post visible to a specific user' do
      other_user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: other_user, organisation: organisation, role: role, active: true)
        create(:project_permission, user: other_user, project: project, tickets_access: :read_only)
      end

      post "/api/v1/tickets/#{ticket.id}/posts",
           params: {
             post: {
               body: 'Geheim',
               is_private: true,
               visible_to_user_id: other_user.id
             }
           },
           headers: auth_headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig('data', 'is_private')).to be true
      expect(body.dig('data', 'visible_to_user_id')).to eq(other_user.id)
    end

    # The addressee comes from the request. Without a rule it took any account of the
    # instance, and the answer told an existing id (201) from a missing one (422).
    { 'from another organisation' => -> { create(:user, organisation: create(:organisation)).id },
      'that does not exist' => -> { SecureRandom.uuid } }.each do |label, addressee|
      it "refuses an addressee #{label}, with the same answer" do
        addressee_id = instance_exec(&addressee)

        expect do
          post "/api/v1/tickets/#{ticket.id}/posts",
               params: { post: { body: 'Geheim', is_private: true, visible_to_user_id: addressee_id } },
               headers: auth_headers
        end.not_to(change { ActsAsTenant.with_tenant(organisation) { Post.count } })

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)['error']).to eq('validation_failed')
      end
    end

    it 'returns 422 when body is missing' do
      post "/api/v1/tickets/#{ticket.id}/posts",
           params: { post: { body: '' } },
           headers: auth_headers
      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body['error']).to eq('validation_failed')
    end

    it 'returns 403 when the user has only read access on tickets' do
      ActsAsTenant.with_tenant(organisation) do
        project_permission.update!(tickets_access: :read_only)
      end

      post "/api/v1/tickets/#{ticket.id}/posts",
           params: { post: { body: 'Nope' } },
           headers: auth_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'returns 404 for a ticket outside the token scope' do
      other_org = create(:organisation)
      foreign_project = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
      foreign_ticket = ActsAsTenant.with_tenant(other_org) do
        create(:ticket, project: foreign_project, organisation: other_org, creator: create(:user))
      end

      post "/api/v1/tickets/#{foreign_ticket.id}/posts",
           params: { post: { body: 'Nope' } },
           headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # ------------------------------------------------------------------
  # POST /api/v1/tickets/:id/time_sessions
  # ------------------------------------------------------------------
  describe 'POST /api/v1/tickets/:ticket_id/time_sessions' do
    let!(:time_session_permission) do
      ActsAsTenant.with_tenant(organisation) do
        TimeSessionPermission.create!(user: user, project: project, can_create_own: true)
      end
    end

    it 'creates a completed time session via duration_minutes' do
      expect do
        post "/api/v1/tickets/#{ticket.id}/time_sessions",
             params: {
               time_session: {
                 occurred_on: '2026-05-20T10:00:00Z',
                 duration_minutes: 90,
                 description: 'Refactored login form'
               }
             },
             headers: auth_headers
      end.to change { ActsAsTenant.with_tenant(organisation) { TimeSession.count } }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig('data', 'duration_minutes')).to eq(90)
      expect(body.dig('data', 'creator', 'id')).to eq(user.id)
      expect(body.dig('data', 'description')).to eq('Refactored login form')
      # The row shape is shared with the MCP tool create_time_session
      # (TimeSessions::Serializer, D4): pinned, so neither surface drifts.
      expect(body['data'].keys).to contain_exactly(
        'id', 'ticket_id', 'creator', 'occurred_on', 'duration_minutes', 'description',
        'customer_description', 'billed', 'billed_at', 'created_at'
      )
    end

    it 'accepts duration_string in HH:MM format' do
      post "/api/v1/tickets/#{ticket.id}/time_sessions",
           params: {
             time_session: {
               occurred_on: '2026-05-20T10:00:00Z',
               duration_string: '1:30'
             }
           },
           headers: auth_headers
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body).dig('data', 'duration_minutes')).to eq(90)
    end

    it 'returns 422 when duration is missing' do
      post "/api/v1/tickets/#{ticket.id}/time_sessions",
           params: { time_session: { occurred_on: '2026-05-20T10:00:00Z' } },
           headers: auth_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    # I18n.locale is thread state the web layer assigns without restoring; a
    # token request answers in the OWNER's language whatever the thread carries
    # (Api::TokenAuthenticatable#with_token_owner_locale), and leaves the thread
    # as it found it.
    it "answers validation messages in the token owner's language, whatever locale the thread carries" do
      user.update!(language_preference: 'de')
      I18n.locale = :en
      post "/api/v1/tickets/#{ticket.id}/time_sessions",
           params: { time_session: { occurred_on: '2026-05-20T10:00:00Z', duration_minutes: 0 } },
           headers: auth_headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)['errors'].join).to include('muss größer als 0 sein')
      expect(I18n.locale).to eq(:en)
    ensure
      I18n.locale = I18n.default_locale
    end

    it 'returns 403 when the user lacks can_create_own' do
      time_session_permission.update!(can_create_own: false)

      post "/api/v1/tickets/#{ticket.id}/time_sessions",
           params: {
             time_session: {
               occurred_on: '2026-05-20T10:00:00Z',
               duration_minutes: 60
             }
           },
           headers: auth_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'returns 403 when no TimeSessionPermission exists' do
      time_session_permission.destroy

      post "/api/v1/tickets/#{ticket.id}/time_sessions",
           params: {
             time_session: {
               occurred_on: '2026-05-20T10:00:00Z',
               duration_minutes: 60
             }
           },
           headers: auth_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  # ------------------------------------------------------------------
  # POST /api/v1/projects/:project_id/tickets
  # ------------------------------------------------------------------
  describe 'POST /api/v1/projects/:project_id/tickets' do
    it 'creates a ticket with title only' do
      expect do
        post "/api/v1/projects/#{project.id}/tickets",
             params: { ticket: { title: 'API-created ticket' } },
             headers: auth_headers
      end.to change { ActsAsTenant.with_tenant(organisation) { Ticket.count } }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig('data', 'title')).to eq('API-created ticket')
      expect(body.dig('data', 'creator', 'id')).to eq(user.id)
    end

    it 'sets ticket_type, summary, description and custom_attributes' do
      post "/api/v1/projects/#{project.id}/tickets",
           params: {
             ticket: {
               title: 'Bug found',
               ticket_type: 'bug',
               summary: 'short summary',
               description: 'Long bug description with steps to reproduce.',
               custom_attributes: { status: 'open', priority: 'high' }
             }
           },
           headers: auth_headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig('data', 'ticket_type')).to eq('bug')
      expect(body.dig('data', 'summary')).to eq('short summary')
      expect(body.dig('data', 'description_text')).to include('Long bug description')
      expect(body.dig('data', 'custom_attributes', 'status')).to eq('open')
    end

    it 'assigns users from assignee_ids' do
      other = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: other, organisation: organisation, role: role, active: true)
        create(:project_permission, user: other, project: project, tickets_access: :read_write)
      end

      post "/api/v1/projects/#{project.id}/tickets",
           params: { ticket: { title: 'With assignees', assignee_ids: [user.id, other.id] } },
           headers: auth_headers

      expect(response).to have_http_status(:created)
      ActsAsTenant.with_tenant(organisation) do
        created = Ticket.find(JSON.parse(response.body).dig('data', 'id'))
        expect(created.assignees.pluck(:id)).to contain_exactly(user.id, other.id)
      end
    end

    it 'returns 422 without a title' do
      post "/api/v1/projects/#{project.id}/tickets",
           params: { ticket: { title: '' } },
           headers: auth_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 403 without write access' do
      ActsAsTenant.with_tenant(organisation) { project_permission.update!(tickets_access: :read_only) }
      post "/api/v1/projects/#{project.id}/tickets",
           params: { ticket: { title: 'Nope' } },
           headers: auth_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'returns 404 for a project outside the token scope' do
      other_org = create(:organisation)
      foreign_project = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
      post "/api/v1/projects/#{foreign_project.id}/tickets",
           params: { ticket: { title: 'Nope' } },
           headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end

    # --- sub-tickets (parent_id) -----------------------------------------

    it 'creates a sub-ticket under a top-level parent in the same project' do
      post "/api/v1/projects/#{project.id}/tickets",
           params: { ticket: { title: 'Child', parent_id: ticket.id } },
           headers: auth_headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig('data', 'parent_id')).to eq(ticket.id)
      ActsAsTenant.with_tenant(organisation) do
        expect(ticket.reload.children.pluck(:title)).to eq(['Child'])
      end
    end

    it 'creates a top-level ticket when parent_id is blank' do
      post "/api/v1/projects/#{project.id}/tickets",
           params: { ticket: { title: 'No parent', parent_id: '' } },
           headers: auth_headers

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body).dig('data', 'parent_id')).to be_nil
    end

    it 'returns 422 for a parent in another project of the same org' do
      other_parent = ActsAsTenant.with_tenant(organisation) do
        other_project = create(:project, organisation: organisation)
        create(:ticket, project: other_project, organisation: organisation, creator: user)
      end

      expect do
        post "/api/v1/projects/#{project.id}/tickets",
             params: { ticket: { title: 'Wrong project', parent_id: other_parent.id } },
             headers: auth_headers
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { Ticket.count } })

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 422 for a parent in a foreign organisation' do
      other_org = create(:organisation)
      foreign_parent = ActsAsTenant.with_tenant(other_org) do
        foreign_project = create(:project, organisation: other_org)
        create(:ticket, project: foreign_project, organisation: other_org, creator: create(:user))
      end

      post "/api/v1/projects/#{project.id}/tickets",
           params: { ticket: { title: 'Cross-tenant', parent_id: foreign_parent.id } },
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      ActsAsTenant.without_tenant { expect(Ticket.where(parent_id: foreign_parent.id)).to be_empty }
    end

    it 'creates a grandchild when the parent is itself a sub-ticket (depth is unlimited)' do
      child = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user, parent: ticket)
      end

      post "/api/v1/projects/#{project.id}/tickets",
           params: { ticket: { title: 'Grandchild', parent_id: child.id } },
           headers: auth_headers

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body.dig('data', 'parent_id')).to eq(child.id)
      ActsAsTenant.with_tenant(organisation) { expect(Ticket.find(body.dig('data', 'id')).parent_id).to eq(child.id) }
    end

    # --- mapper hardening (save_ticket_create_params) -------------------

    it "defaults a blank ticket_type to 'support' (kills dropping .presence || 'support')" do
      post "/api/v1/projects/#{project.id}/tickets",
           params: { ticket: { title: 'No type', ticket_type: '' } },
           headers: auth_headers

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body).dig('data', 'ticket_type')).to eq('support')
    end

    it 'does not persist a ticket when write access is missing (authorize runs before the write)' do
      ActsAsTenant.with_tenant(organisation) { project_permission.update!(tickets_access: :read_only) }

      expect do
        post "/api/v1/projects/#{project.id}/tickets",
             params: { ticket: { title: 'Should not persist' } },
             headers: auth_headers
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { Ticket.count } })

      expect(response).to have_http_status(:forbidden)
    end
  end

  # ------------------------------------------------------------------
  # PATCH /api/v1/tickets/:id  (status + assignees)
  # ------------------------------------------------------------------
  describe 'PATCH /api/v1/tickets/:id' do
    it 'updates the status' do
      patch "/api/v1/tickets/#{ticket.id}",
            params: { ticket: { status: 'in_progress' } },
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig('data', 'status')).to eq('in_progress')
      expect(ticket.reload.custom_attributes['status']).to eq('in_progress')
    end

    it 'replaces the assignee set' do
      other_user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: other_user, organisation: organisation, role: role, active: true)
        create(:project_permission, user: other_user, project: project, tickets_access: :read_write)
      end

      patch "/api/v1/tickets/#{ticket.id}",
            params: { ticket: { assignee_ids: [user.id, other_user.id] } },
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      assigned_ids = ticket.reload.assignees.pluck(:id)
      expect(assigned_ids).to contain_exactly(user.id, other_user.id)
    end

    it 'removes all assignees with an empty array' do
      ActsAsTenant.with_tenant(organisation) { ticket.assignees << user }
      patch "/api/v1/tickets/#{ticket.id}",
            params: { ticket: { assignee_ids: [] } },
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.assignees).to be_empty
    end

    it 'silently ignores assignee_ids of users not in the org' do
      stranger = create(:user) # no membership in `organisation`
      patch "/api/v1/tickets/#{ticket.id}",
            params: { ticket: { assignee_ids: [stranger.id] } },
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.assignees).to be_empty
    end

    it 'returns 403 with read_only tickets access' do
      ActsAsTenant.with_tenant(organisation) do
        project_permission.update!(tickets_access: :read_only)
      end

      patch "/api/v1/tickets/#{ticket.id}",
            params: { ticket: { status: 'in_progress' } },
            headers: auth_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'returns 404 for a ticket outside the token scope' do
      other_org = create(:organisation)
      foreign_project = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
      foreign_ticket = ActsAsTenant.with_tenant(other_org) do
        create(:ticket, project: foreign_project, organisation: other_org, creator: create(:user))
      end

      patch "/api/v1/tickets/#{foreign_ticket.id}",
            params: { ticket: { status: 'in_progress' } },
            headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end

    # --- mapper hardening (save_ticket_update_params) -------------------

    it 'merges status into custom_attributes, preserving other keys (kills merge -> replace)' do
      ActsAsTenant.with_tenant(organisation) do
        ticket.update!(custom_attributes: { 'status' => 'open', 'priority' => 'high' })
      end

      patch "/api/v1/tickets/#{ticket.id}",
            params: { ticket: { status: 'in_progress' } },
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      reloaded = ticket.reload.custom_attributes
      expect(reloaded['status']).to eq('in_progress')
      expect(reloaded['priority']).to eq('high')
    end

    it 'leaves existing assignees untouched on a status-only update (kills assignee key-gating)' do
      ActsAsTenant.with_tenant(organisation) { ticket.assignees << user }

      patch "/api/v1/tickets/#{ticket.id}",
            params: { ticket: { status: 'in_progress' } },
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(ticket.reload.assignees.pluck(:id)).to contain_exactly(user.id)
    end
  end

  # ------------------------------------------------------------------
  # Side-effect PARITY with the web write path.
  #
  # Web ticket writes go through Actors::SaveTicket, which records an 'assigned'
  # activity per added assignee (Ticket#track_assignee_added). The previous naive
  # API path (ticket.assignees = User.where(...)) bypassed this: assignee
  # subscriptions are still created via the TicketAssignment#auto_subscribe_assignee
  # callback on BOTH paths, but the activity is created ONLY by SaveTicket — see
  # the note in TicketAssignment ("Activity tracking ... is handled by SaveTicket ...
  # NOT here"). So the 'assigned' activity is the genuine web/API parity gap.
  # It is created synchronously inside SaveTicket, observable within the request's
  # transaction. If the API ever stops routing through SaveTicket, these go red.
  # ------------------------------------------------------------------
  describe 'side-effect parity with the web path (Actors::SaveTicket)' do
    let(:assignee_a) { create(:user) }
    let(:assignee_b) { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        [assignee_a, assignee_b].each do |u|
          create(:membership, user: u, organisation: organisation, role: role, active: true)
          create(:project_permission, user: u, project: project, tickets_access: :read_write)
        end
      end
    end

    def created_ticket
      ActsAsTenant.with_tenant(organisation) { Ticket.find(JSON.parse(response.body).dig('data', 'id')) }
    end

    def assigned_activity_secondary_ids(ticket)
      ActsAsTenant.with_tenant(organisation) do
        ticket.activities.where(action: 'assigned').pluck(:secondary_id)
      end
    end

    it "records an 'assigned' activity per assignee on create — like the web path" do
      post "/api/v1/projects/#{project.id}/tickets",
           params: { ticket: { title: 'Parity create', assignee_ids: [assignee_a.id, assignee_b.id] } },
           headers: auth_headers
      expect(response).to have_http_status(:created)

      expect(assigned_activity_secondary_ids(created_ticket)).to contain_exactly(assignee_a.id, assignee_b.id)
    end

    it "records an 'assigned' activity for newly added assignees on update — like the web path" do
      patch "/api/v1/tickets/#{ticket.id}",
            params: { ticket: { assignee_ids: [assignee_a.id] } },
            headers: auth_headers
      expect(response).to have_http_status(:ok)

      expect(assigned_activity_secondary_ids(ticket)).to contain_exactly(assignee_a.id)
    end
  end

  describe 'side-effect parity with the web path (Actors::SavePost)' do
    it 'records a post_added activity for the comment, like the web path' do
      post "/api/v1/tickets/#{ticket.id}/posts",
           params: { post: { body: 'Parity comment' } },
           headers: auth_headers
      expect(response).to have_http_status(:created)

      saved = ActsAsTenant.with_tenant(organisation) { Post.find(JSON.parse(response.body).dig('data', 'id')) }
      activity = ActsAsTenant.with_tenant(organisation) { Activity.find_by(action: 'post_added', secondary: saved) }
      expect(activity).to be_present
      expect(activity.actor).to eq(user)
      expect(activity.trackable).to eq(ticket)
    end
  end

  # ------------------------------------------------------------------
  # A read-only token writes nothing, on any endpoint
  # ------------------------------------------------------------------
  # Iterates the router instead of a list, so a new write endpoint is covered the day it
  # appears. Parity with the MCP seam (Mcp::ToolCall#write_blocked?).
  describe 'with a read-only token' do
    let(:read_only) { true }
    let(:pat) do
      pat = build(:personal_access_token, user: user, organisations: [organisation], read_only: read_only)
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
      pat
    end

    # Every right the user needs, so a 403 can only come from the token
    let!(:time_session_permission) do
      ActsAsTenant.with_tenant(organisation) do
        TimeSessionPermission.create!(user: user, project: project, can_create_own: true)
      end
    end

    let!(:notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: ticket,
                              project: project, state: 'queued')
      end
    end

    write_routes = Rails.application.routes.routes.filter_map do |route|
      next unless route.defaults[:controller].to_s.start_with?('api/v1/')

      verb = route.verb.to_s
      next if verb.blank? || %w[GET HEAD].include?(verb)

      [verb, route.path.spec.to_s.delete_suffix('(.:format)'), route.defaults[:controller]]
    end

    def request_write(verb, path_spec, controller)
      record_id = controller == 'api/v1/notifications' ? notification.id : ticket.id
      path = path_spec.gsub(':project_id', project.id).gsub(':ticket_id', ticket.id).gsub(':id', record_id)
      params = { ticket: { title: 'Written anyway' }, post: { body: 'Written anyway' }, change: { title: 'Written anyway' },
                 time_session: { occurred_on: '2026-05-20T10:00:00Z', duration_minutes: 30 } }
      process verb.downcase.to_sym, path, params: params, headers: auth_headers
    end

    it 'finds the write endpoints it is meant to cover' do
      expect(write_routes.map { |verb, path, _| "#{verb} #{path}" }).to include(
        'POST /api/v1/projects/:project_id/tickets',
        'PATCH /api/v1/tickets/:id',
        'POST /api/v1/tickets/:ticket_id/posts',
        'POST /api/v1/tickets/:ticket_id/time_sessions',
        'POST /api/v1/notifications/:id/mark_as_read'
      )
    end

    # The guard must not treat reads as writes: GET is covered by read_endpoints_spec (its
    # token is read-only by default), HEAD only here
    it 'lets a HEAD request through' do
      head "/api/v1/tickets/#{ticket.id}", headers: auth_headers

      expect(response).to have_http_status(:ok)
    end

    # The guard reads current_token, so it has to run after authentication: before it, a
    # request without a token would crash on nil instead of answering 401
    it 'answers a write without any token with 401, not an error' do
      patch "/api/v1/tickets/#{ticket.id}", params: { ticket: { title: 'Written anyway' } }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['error']).to eq('unauthorized')
    end

    write_routes.each do |verb, path_spec, controller|
      it "refuses #{verb} #{path_spec} with 403 and changes nothing" do
        ticket_state = ticket.reload.attributes

        expect { request_write(verb, path_spec, controller) }.not_to(change do
          ActsAsTenant.with_tenant(organisation) { [Ticket.count, Post.count, TimeSession.count] }
        end)

        expect(response).to have_http_status(:forbidden)
        # `error` as it always was, `code` naming the token as the reason (D6).
        expect(response.parsed_body).to eq('error' => 'forbidden', 'code' => 'read_only')
        expect(ticket.reload.attributes).to eq(ticket_state)
        expect(notification.reload).to have_attributes(read_at: nil, archived_at: nil)
      end

      # Proves the 403 above comes from the token alone: same user, same request
      context 'when the same token may write' do
        let(:read_only) { false }

        it "lets #{verb} #{path_spec} through" do
          request_write(verb, path_spec, controller)

          expect(response).to have_http_status(:success)
        end
      end
    end
  end
end
