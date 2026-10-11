# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Read Endpoints', type: :request do
  # ------------------------------------------------------------------
  # Common setup
  # ------------------------------------------------------------------
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

  let!(:project_permission) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission,
             user: user,
             project: project,
             tickets_access: :read_write,
             documents_access: :read_only)
    end
  end

  let(:pat) do
    pat = build(:personal_access_token, user: user, organisations: [organisation])
    pat.token_hash = nil
    pat.token_prefix = nil
    pat.generate_token!
    pat
  end

  def auth_headers(token = pat.token)
    { 'Authorization' => "Bearer #{token}" }
  end

  # ------------------------------------------------------------------
  # Erased account: the credential must not outlive its owner
  # ------------------------------------------------------------------
  describe 'authentication of an erased account' do
    it 'rejects a still-unrevoked token whose owner row is soft-deleted (401, not 500)' do
      raw = pat.token
      # soft_delete! alone: the erasure path also revokes tokens, but a
      # credential must die with its account even when revocation was missed
      # (rows from before PersonalDataErasure#revoke_personal_access_tokens!).
      user.soft_delete!

      get '/api/v1/organisations', headers: auth_headers(raw)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ------------------------------------------------------------------
  # GET /api/v1/organisations
  # ------------------------------------------------------------------
  describe 'GET /api/v1/organisations' do
    it 'returns scoped organisations with all_projects flag' do
      get '/api/v1/organisations', headers: auth_headers
      expect(response).to have_http_status(:ok)

      data = JSON.parse(response.body)['data']
      expect(data.size).to eq(1)
      expect(data.first['id']).to eq(organisation.id)
      expect(data.first['scope']).to eq('all_projects')
    end

    it 'does not include orgs outside the token scope' do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:membership, user: user, organisation: other_organisation,
                            role: create(:role, organisation: other_organisation), active: true)
      end
      get '/api/v1/organisations', headers: auth_headers
      data = JSON.parse(response.body)['data']
      expect(data.map { |o| o['id'] }).not_to include(other_organisation.id)
    end
  end

  # ------------------------------------------------------------------
  # GET /api/v1/projects
  # ------------------------------------------------------------------
  describe 'GET /api/v1/projects' do
    it 'returns projects the user has access to within the token scope' do
      project # ensure created
      get '/api/v1/projects', headers: auth_headers
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)['data']
      expect(data.map { |p| p['id'] }).to include(project.id)
    end

    it 'filters by organisation_id when given' do
      project
      get '/api/v1/projects', params: { organisation_id: other_organisation.id }, headers: auth_headers
      expect(JSON.parse(response.body)['data']).to be_empty
    end

    it 'honours the token project restriction when all_projects=false' do
      other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: user, project: other_project, tickets_access: :read_write)
      end

      restricted = build(:personal_access_token, user: user)
      restricted.personal_access_token_organisations.build(organisation: organisation, all_projects: false)
      restricted.personal_access_token_projects.build(project: project)
      restricted.assign_token!
      restricted.save!

      get '/api/v1/projects', headers: auth_headers(restricted.token)

      ids = JSON.parse(response.body)['data'].map { |p| p['id'] }
      expect(ids).to include(project.id)
      expect(ids).not_to include(other_project.id)
    end
  end

  # ------------------------------------------------------------------
  # GET /api/v1/projects/:id/tickets
  # ------------------------------------------------------------------
  describe 'GET /api/v1/projects/:id/tickets' do
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user,
                        custom_attributes: { 'status' => 'open' })
      end
    end

    it 'lists tickets of the project' do
      get "/api/v1/projects/#{project.id}/tickets", headers: auth_headers
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)['data']
      expect(data.map { |t| t['id'] }).to include(ticket.id)
    end

    it 'filters by status' do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user,
                        custom_attributes: { 'status' => 'done' })
      end
      get "/api/v1/projects/#{project.id}/tickets", params: { status: 'done' }, headers: auth_headers
      statuses = JSON.parse(response.body)['data'].map { |t| t['status'] }
      expect(statuses).to all(eq('done'))
    end

    it 'filters by assignee=me' do
      other_ticket = ActsAsTenant.with_tenant(organisation) do
        ticket.assignees << user
        create(:ticket, project: project, organisation: organisation, creator: user)
      end

      get "/api/v1/projects/#{project.id}/tickets", params: { assignee: 'me' }, headers: auth_headers
      ids = JSON.parse(response.body)['data'].map { |t| t['id'] }
      expect(ids).to include(ticket.id)
      expect(ids).not_to include(other_ticket.id)
    end

    it 'returns 404 for a project outside the token scope' do
      foreign_project = ActsAsTenant.with_tenant(other_organisation) do
        create(:project, organisation: other_organisation)
      end
      get "/api/v1/projects/#{foreign_project.id}/tickets", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end

    it 'filters by full-text query (q)' do
      matching = ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user,
                        title: 'Login mit Sonderzeichen schlägt fehl')
      end
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user,
                        title: 'Datenbank-Migration beschleunigen')
      end

      get "/api/v1/projects/#{project.id}/tickets",
          params: { q: 'Login' },
          headers: auth_headers
      ids = JSON.parse(response.body)['data'].map { |t| t['id'] }
      expect(ids).to include(matching.id)
      expect(ids.size).to eq(1)
    end

    it 'paginates results' do
      # Prosopite flags has_many_attached Active Storage scans across factory creations,
      # which are not true N+1 for a request — they're per-record callbacks during setup.
      Prosopite.pause
      ActsAsTenant.with_tenant(organisation) do
        2.times { create(:ticket, project: project, organisation: organisation, creator: user) }
      end
      Prosopite.resume

      get "/api/v1/projects/#{project.id}/tickets",
          params: { per_page: 2, page: 1 },
          headers: auth_headers
      body = JSON.parse(response.body)
      expect(body['data'].size).to eq(2)
      expect(body['meta']['total']).to eq(3)
    end
  end

  # ------------------------------------------------------------------
  # GET /api/v1/projects/:id/ticket_attribute_definitions
  # ------------------------------------------------------------------
  describe 'GET /api/v1/projects/:id/ticket_attribute_definitions' do
    let!(:status_def) do
      ActsAsTenant.with_tenant(organisation) do
        TicketAttributeDefinition.create!(
          project: project,
          name: 'status',
          field_type: 'select',
          labels: { 'de' => 'Status', 'en' => 'Status' },
          options: { 'allowed_values' => [{ 'value' => 'open' }, { 'value' => 'done' }] },
          position: 1,
          system: true,
          active: true
        )
      end
    end

    it 'returns active attribute definitions ordered by position' do
      get "/api/v1/projects/#{project.id}/ticket_attribute_definitions", headers: auth_headers
      expect(response).to have_http_status(:ok)
      defs = JSON.parse(response.body)['data']
      expect(defs.size).to eq(1)
      expect(defs.first['name']).to eq('status')
      expect(defs.first['options']).to eq({ 'allowed_values' => [{ 'value' => 'open' }, { 'value' => 'done' }] })
    end
  end

  # ------------------------------------------------------------------
  # GET /api/v1/tickets/:id
  # ------------------------------------------------------------------
  describe 'GET /api/v1/tickets/:id' do
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user,
                        custom_attributes: { 'status' => 'open' })
      end
    end

    it 'returns the ticket head + posts + permissions block' do
      get "/api/v1/tickets/#{ticket.id}", headers: auth_headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body.dig('data', 'id')).to eq(ticket.id)
      expect(body.dig('data', 'project', 'id')).to eq(project.id)
      expect(body.dig('data', 'posts')).to eq([])
      expect(body.dig('permissions', 'tickets', 'read')).to be true
      expect(body.dig('permissions', 'documents', 'write')).to be false # read_only set in factory
    end

    it 'returns 404 for cross-org access' do
      foreign_project = ActsAsTenant.with_tenant(other_organisation) do
        create(:project, organisation: other_organisation)
      end
      foreign_ticket = ActsAsTenant.with_tenant(other_organisation) do
        create(:ticket, project: foreign_project, organisation: other_organisation,
                        creator: create(:user))
      end
      get "/api/v1/tickets/#{foreign_ticket.id}", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # ------------------------------------------------------------------
  # Sub-resources
  # ------------------------------------------------------------------
  describe 'GET /api/v1/tickets/:id/activities' do
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user)
      end
    end

    it 'returns an empty list when no activities exist' do
      get "/api/v1/tickets/#{ticket.id}/activities", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data']).to eq([])
    end
  end

  describe 'GET /api/v1/tickets/:id/time_sessions' do
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user)
      end
    end

    it 'returns an empty list when the user has no TimeSessionPermission' do
      get "/api/v1/tickets/#{ticket.id}/time_sessions", headers: auth_headers
      expect(response).to have_http_status(:ok)
      # Policy::Scope returns nothing without explicit permission.
      expect(JSON.parse(response.body)['data']).to eq([])
    end
  end

  # ------------------------------------------------------------------
  # GET /api/v1/time_sessions/open
  # ------------------------------------------------------------------
  describe 'GET /api/v1/time_sessions/open' do
    let(:project_for_time) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end

    let!(:project_perm_time) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_permission, user: user, project: project_for_time, tickets_access: :read_write)
        # The web's time-viewing rule applies here too (TimeSessions::ViewingScope):
        # without the right to see their own time, the person lists no open hours.
        create(:time_session_permission, user: user, project: project_for_time, can_view_own: true)
      end
    end

    let!(:open_session) do
      ActsAsTenant.with_tenant(organisation) do
        ts = TimeSession.new(
          project: project_for_time,
          organisation: organisation,
          creator: user,
          occurred_on: 2.days.ago,
          duration: 90
        )
        ts.save!
        ts
      end
    end

    it 'returns unbilled and ungrouped sessions of the current user' do
      get '/api/v1/time_sessions/open', headers: auth_headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body['data'].map { |s| s['id'] }).to include(open_session.id)
      expect(body['meta']['total']).to eq(1)
      expect(body['meta']['total_minutes']).to eq(90)
      expect(body['meta']['total_hours_decimal']).to eq(1.5)
    end

    it 'excludes billed sessions' do
      ActsAsTenant.with_tenant(organisation) do
        billed_ts = TimeSession.new(
          project: project_for_time, organisation: organisation, creator: user,
          occurred_on: 1.day.ago, duration: 60, billed: true, billed_at: 1.hour.ago
        )
        billed_ts.save!
      end
      get '/api/v1/time_sessions/open', headers: auth_headers
      expect(JSON.parse(response.body)['meta']['total']).to eq(1)
    end

    it 'excludes sessions that belong to a TimeSessionGroup' do
      group = ActsAsTenant.with_tenant(organisation) do
        TimeSessionGroup.create!(organisation: organisation, creator: user, name: 'Inv. 2026-05')
      end
      ActsAsTenant.with_tenant(organisation) do
        grouped = TimeSession.new(
          project: project_for_time, organisation: organisation, creator: user,
          occurred_on: 3.days.ago, duration: 30, time_session_group: group
        )
        grouped.save!
      end
      get '/api/v1/time_sessions/open', headers: auth_headers
      expect(JSON.parse(response.body)['meta']['total']).to eq(1)
    end

    it 'excludes sessions of other users' do
      stranger = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: stranger, organisation: organisation, role: role, active: true)
        TimeSession.new(
          project: project_for_time, organisation: organisation, creator: stranger,
          occurred_on: 1.day.ago, duration: 45
        ).save!
      end
      get '/api/v1/time_sessions/open', headers: auth_headers
      expect(JSON.parse(response.body)['meta']['total']).to eq(1)
    end

    it 'excludes sessions from organisations outside the token scope' do
      foreign_org = create(:organisation)
      foreign_project = ActsAsTenant.with_tenant(foreign_org) do
        create(:project, organisation: foreign_org)
      end
      ActsAsTenant.with_tenant(foreign_org) do
        TimeSession.new(
          project: foreign_project, organisation: foreign_org, creator: user,
          occurred_on: 1.day.ago, duration: 200
        ).save!
      end
      get '/api/v1/time_sessions/open', headers: auth_headers
      expect(JSON.parse(response.body)['meta']['total_minutes']).to eq(90)
    end

    it 'shows no ticket of another organisation even when a booking points at one' do
      foreign_ticket = ActsAsTenant.with_tenant(other_organisation) do
        other_project = create(:project, organisation: other_organisation)
        create(:ticket, organisation: other_organisation, project: other_project, creator: user, title: 'Foreign secret')
      end
      open_session.update_column(:ticket_id, foreign_ticket.id)

      get '/api/v1/time_sessions/open', headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Foreign secret')
      entry = JSON.parse(response.body)['data'].find { |session| session['id'] == open_session.id }
      expect(entry['ticket']).to be_nil
    end

    it 'includes inline project + ticket information in the payload' do
      get '/api/v1/time_sessions/open', headers: auth_headers
      first = JSON.parse(response.body)['data'].first
      expect(first.dig('project', 'id')).to eq(project_for_time.id)
      expect(first['duration_hours_decimal']).to eq(1.5)
    end
  end

  describe 'GET /api/v1/tickets/:id/attachments' do
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: user)
      end
    end

    it 'returns an empty list when no attachments exist' do
      get "/api/v1/tickets/#{ticket.id}/attachments", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data']).to eq([])
    end

    it 'lists the ticket own attachments' do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket_document, :with_pdf, ticket: ticket, organisation: organisation)
      end

      get "/api/v1/tickets/#{ticket.id}/attachments", headers: auth_headers

      data = JSON.parse(response.body)['data']
      expect(data.size).to eq(1)
      expect(data.first).to include('attached_to' => 'ticket', 'filename' => 'test_document.pdf')
    end

    # The count and the list have to answer the same question. #show reports
    # attachments_count from post_documents (Tickets::Serializer), so a client that
    # follows that number to fetch the file must find it here — otherwise the API
    # says "two files" on one endpoint and "none" on the next.
    it 'lists a comment attachment, the same one #show counts' do
      post_record = ActsAsTenant.with_tenant(organisation) do
        record = create(:post, ticket: ticket, user: user, is_private: false)
        create(:post_document, :with_pdf, post: record, organisation: organisation)
        record
      end

      get "/api/v1/tickets/#{ticket.id}/attachments", headers: auth_headers
      listed = JSON.parse(response.body)['data'].select { |a| a['attached_to'] == 'post' }

      get "/api/v1/tickets/#{ticket.id}", headers: auth_headers
      counted = JSON.parse(response.body).dig('data', 'posts').first['attachments_count']

      expect(counted).to eq(1)
      expect(listed.size).to eq(counted)
      expect(listed.first).to include('parent_id' => post_record.id, 'filename' => 'test_document.pdf')
      expect(listed.first['url']).to be_present
    end
  end
end
