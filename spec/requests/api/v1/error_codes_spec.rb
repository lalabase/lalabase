# frozen_string_literal: true

require 'rails_helper'

# What: every /api/v1 error body carries `code`, the MCP error vocabulary
#   (invalid_input, read_only, forbidden, not_found, refused, plus unauthorized),
#   next to its unchanged `error` value and HTTP status (cli_rest_plan D6).
# Why: a program branches on a fixed code. `error` stays exactly as it was,
#   because existing token clients read it; "missing" and "not visible to you"
#   stay one answer, so the code leaks no existence either.
RSpec.describe 'API V1 error codes', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }
  let(:foreign_ticket) do
    ActsAsTenant.with_tenant(other_organisation) do
      foreign_project = create(:project, organisation: other_organisation)
      create(:ticket, project: foreign_project, organisation: other_organisation, creator: create(:user))
    end
  end

  def build_pat(read_only:)
    build(:personal_access_token, user: user, organisations: [organisation], read_only: read_only).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  let(:pat) { build_pat(read_only: false) }
  let(:read_pat) { build_pat(read_only: true) }

  def headers(token = pat)
    { 'Authorization' => "Bearer #{token.token}" }
  end

  def body = response.parsed_body

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    create(:project_permission, user: user, project: project, tickets_access: :read_write)
  end

  after { ActsAsTenant.current_tenant = nil }

  it 'answers a missing token with unauthorized, error unchanged' do
    get '/api/v1/me'
    expect(response).to have_http_status(:unauthorized)
    expect(body).to eq('error' => 'unauthorized', 'code' => 'unauthorized')
  end

  # The 401 lives in a concern /api/mcp shares; MCP answers as before.
  it 'leaves the 401 of /api/mcp as it was' do
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/list' }.to_json,
                     headers: { 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:unauthorized)
    expect(body).to eq('error' => 'unauthorized')
  end

  it 'answers a write with a read-only token as read_only, error unchanged' do
    post "/api/v1/tickets/#{ticket.id}/posts", params: { post: { body: 'x' } }, headers: headers(read_pat)
    expect(response).to have_http_status(:forbidden)
    expect(body).to eq('error' => 'forbidden', 'code' => 'read_only')
  end

  it 'answers a Pundit refusal as forbidden' do
    ProjectPermission.find_by!(user: user, project: project).update!(tickets_access: :read_only)
    post "/api/v1/tickets/#{ticket.id}/posts", params: { post: { body: 'x' } }, headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(body).to eq('error' => 'forbidden', 'code' => 'forbidden')
  end

  it 'answers a missing and a foreign ticket with one and the same not_found' do
    get "/api/v1/tickets/#{SecureRandom.uuid}", headers: headers
    missing = [response.status, body]
    get "/api/v1/tickets/#{foreign_ticket.id}", headers: headers
    expect([response.status, body]).to eq(missing)
    expect(missing).to eq([404, { 'error' => 'not_found', 'code' => 'not_found' }])
  end

  it 'answers a missing parameter as invalid_input, keeping error and message' do
    post "/api/v1/tickets/#{ticket.id}/posts", params: {}, headers: headers
    expect(response).to have_http_status(:bad_request)
    expect(body).to include('error' => 'bad_request', 'code' => 'invalid_input')
    expect(body['message']).to be_present
  end

  it 'answers a validation failure as invalid_input, keeping error and errors' do
    post "/api/v1/projects/#{project.id}/tickets", params: { ticket: { title: '' } }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(body).to include('error' => 'validation_failed', 'code' => 'invalid_input')
    expect(body['errors']).to be_present
  end

  it 'answers an unusable inbox filter as invalid_input' do
    get '/api/v1/notifications', params: { status: 'bogus' }, headers: headers
    expect(response).to have_http_status(:bad_request)
    expect(body).to include('error' => 'bad_request', 'code' => 'invalid_input')
  end

  it 'answers a time session without duration as invalid_input' do
    create(:time_session_permission, user: user, project: project)
    post "/api/v1/tickets/#{ticket.id}/time_sessions", params: { time_session: { description: 'x' } }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(body).to include('error' => 'validation_failed', 'code' => 'invalid_input')
  end

  describe 'actor failures on a ticket write' do
    def fail_with(code)
      allow(Actors::SaveTicket).to receive(:call)
        .and_return(Actors::BaseActor::Result.new(success: false, errors: ['nope'], code: code))
      patch "/api/v1/tickets/#{ticket.id}", params: { ticket: { status: 'new' } }, headers: headers
    end

    it 'answers stale_object as refused with the old error as reason, status unchanged' do
      fail_with(:stale_object)
      expect(response).to have_http_status(:conflict)
      expect(body).to eq('error' => 'stale_object', 'code' => 'refused', 'reason' => 'stale_object', 'errors' => ['nope'])
    end

    it 'answers conflict as refused' do
      fail_with(:conflict)
      expect(response).to have_http_status(:conflict)
      expect(body).to include('error' => 'conflict', 'code' => 'refused', 'reason' => 'conflict')
    end

    it 'answers not_member as forbidden' do
      fail_with(:not_member)
      expect(response).to have_http_status(:forbidden)
      expect(body).to include('error' => 'not_member', 'code' => 'forbidden')
      expect(body).not_to have_key('reason')
    end

    it 'answers an unknown actor code as refused, status 422 as before' do
      fail_with(:error)
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include('error' => 'error', 'code' => 'refused', 'reason' => 'error')
    end
  end
end
