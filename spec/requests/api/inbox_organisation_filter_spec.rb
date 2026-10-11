# frozen_string_literal: true

require 'rails_helper'

# organisation_id narrows the token inbox to one organisation, on both surfaces
# that read it (MCP list_notifications, GET /api/v1/notifications): its rows,
# project-less ones included, with every number of the page. An organisation that
# does not exist, one outside the token and one the person left answer alike, so
# the filter confirms nothing (terminal client plan, S1 a).
RSpec.describe 'Token inbox by organisation', :ci_guard, type: :request do
  let(:user) { create(:user) }
  let(:home) { create(:organisation) }
  let(:other) { create(:organisation) }
  let(:foreign) { create(:organisation) }

  def project_in(org)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org) }
  end

  def row(org, project)
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: user, organisation: org, project: project, notifiable: project || org,
                            event_type: Notifications::Constants::EVENT_TYPE_PROJECT_ANNOUNCEMENT,
                            channel: 'in_app', state: 'queued')
    end
  end

  # The fixtures repeat lookups per organisation (memberships, rights); the
  # requests below are what Prosopite watches.
  let!(:rows) do
    Prosopite.pause do
      [home, other].to_h do |org|
        project = project_in(org)
        make_token_owner_a_member(user, org, projects: [project])
        [org, [row(org, project), row(org, nil)]]
      end
    end
  end

  let(:pat) do
    token = build(:personal_access_token, user: user, organisations: [home, other], read_only: true)
    token.token_hash = nil
    token.token_prefix = nil
    token.generate_token!
    token
  end

  def call_tool(arguments)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call',
             params: { name: 'list_notifications', arguments: arguments } }.to_json
    post '/api/mcp', params: body,
                     headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }
    JSON.parse(response.body).fetch('result')
  end

  def rest(params)
    get '/api/v1/notifications', params: params, headers: { 'Authorization' => "Bearer #{pat.token}" }
    response
  end

  describe 'MCP list_notifications' do
    it 'lists one organisation, project-less rows included, with its own numbers' do
      result = call_tool(organisation_id: other.id)
      payload = JSON.parse(result.dig('content', 0, 'text'))
      expect(payload['data'].pluck('id')).to match_array(rows[other].map(&:id))
      expect(payload['meta']).to include('total' => 2, 'unread_total' => 2)
      expect(payload['meta']['by_organisation']).to eq([{ 'id' => other.id, 'name' => other.name, 'unread' => 2 }])
    end

    it 'answers an organisation it cannot reach exactly like one that does not exist' do
      answers = [SecureRandom.uuid, foreign.id].map { |id| call_tool(organisation_id: id) }
      expect(answers.map { |a| a.except('content').merge('text' => a.dig('content', 0, 'text')) }.uniq.size).to eq(1)
      expect(answers.first['isError']).to be true
      expect(answers.first['_meta']).to eq('lalabase/code' => 'not_found')
    end

    it 'names the argument in its input schema' do
      post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json,
                       headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }
      tool = JSON.parse(response.body).dig('result', 'tools').find { |t| t['name'] == 'list_notifications' }
      expect(tool.dig('inputSchema', 'properties', 'organisation_id', 'type')).to eq('string')
    end
  end

  describe 'GET /api/v1/notifications' do
    it 'lists one organisation, project-less rows included' do
      body = JSON.parse(rest(organisation_id: other.id).body)
      expect(body['data'].pluck('id')).to match_array(rows[other].map(&:id))
    end

    it 'answers an organisation it cannot reach exactly like one that does not exist' do
      missing = rest(organisation_id: SecureRandom.uuid)
      missing_answer = [missing.status, missing.body]
      outside = rest(organisation_id: foreign.id)
      expect([outside.status, outside.body]).to eq(missing_answer)
      expect(outside).to have_http_status(:not_found)
    end
  end
end
