# frozen_string_literal: true

require 'rails_helper'

# What: every API door that lists or opens a token's organisations asks
#   PersonalAccessToken#organisation_scopes: /organisations, /projects, /me,
#   /time_sessions/open and the MCP project gate.
# Why: until 2026-10-02 four of them read the organisation link rows themselves, with
#   their own copy of the active-membership rule or without one (/me and
#   /time_sessions/open still named an organisation the owner had been deactivated in).
#   A token with all_organisations has no link rows at all, so a door that reads them
#   would answer "nothing" for it.
RSpec.describe 'API token organisation scopes', :ci_guard, type: :request do
  let(:user) { create(:user) }
  let(:org_a) { create(:organisation, name: 'Alpha GmbH') }
  let(:org_later) { create(:organisation, name: 'Later GmbH') }
  let(:org_left) { create(:organisation, name: 'Left GmbH') }

  def member(org, active: true)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, title: 'account_admin', organisation: org)
      create(:membership, user: user, organisation: org, role: role, active: active)
    end
  end

  def project_in(org, name)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org, name: name) }
  end

  def minted(**attrs)
    build(:personal_access_token, user: user, **attrs).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  def get_json(path, pat)
    get path, headers: { 'Authorization' => "Bearer #{pat.token}" }
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  after { ActsAsTenant.current_tenant = nil }

  context 'with a token for all organisations, made before the owner joined one more' do
    let!(:pat) do
      Prosopite.pause { member(org_a) }
      minted(all_organisations: true)
    end

    before do
      Prosopite.pause do
        member(org_later)
        project_in(org_a, 'Alpha project')
        project_in(org_later, 'Later project')
      end
    end

    it 'lists both organisations, each with all projects' do
      data = get_json('/api/v1/organisations', pat)['data']
      expect(data.map { |o| o['name'] }).to contain_exactly('Alpha GmbH', 'Later GmbH')
      expect(data.map { |o| o['scope'] }).to all(eq('all_projects'))
    end

    it 'lists the projects of the organisation joined later' do
      names = get_json('/api/v1/projects', pat)['data'].map { |p| p['name'] }
      expect(names).to include('Alpha project', 'Later project')
    end

    it 'reports the option and the organisations it reaches on /me' do
      body = get_json('/api/v1/me', pat)['data']
      expect(body['token']['all_organisations']).to be(true)
      expect(body['scoped_organisations'].map { |o| o['name'] }).to contain_exactly('Alpha GmbH', 'Later GmbH')
    end

    it 'opens a project of the organisation joined later through the MCP gate' do
      project = ActsAsTenant.with_tenant(org_later) { Project.find_by!(name: 'Later project') }
      post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                                 params: { name: 'list_tickets', arguments: { project_id: project.id } } }.to_json,
                       headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }
      expect(response.parsed_body.dig('result', 'isError')).to be(false)
    end
  end

  # Both lists come in a stable order, organisations by name ignoring case
  # (Organisation.by_name, the order of the org switcher): a token for all organisations
  # reads its organisations from the memberships, in no order of their own.
  context 'with a token for all organisations, joined in reverse alphabetical order' do
    let(:org_zulu) { create(:organisation, name: 'Zulu GmbH') }
    let(:org_beta) { create(:organisation, name: 'beta GmbH') }
    let!(:pat) do
      Prosopite.pause do
        member(org_zulu)
        member(org_beta)
        member(org_a)
        project_in(org_zulu, 'Zulu project')
        project_in(org_beta, 'beta project')
        project_in(org_a, 'Alpha project')
      end
      minted(all_organisations: true)
    end

    it 'lists organisations by name, ignoring case' do
      expect(get_json('/api/v1/organisations', pat)['data'].map { |o| o['name'] })
        .to eq(['Alpha GmbH', 'beta GmbH', 'Zulu GmbH'])
    end

    it 'lists projects organisation by organisation, by name ignoring case' do
      expect(get_json('/api/v1/projects', pat)['data'].map { |p| p['name'] })
        .to eq(['Alpha project', 'beta project', 'Zulu project'])
    end

    # The filter used to go through ActiveRecord, which normalises a UUID (case, hyphens).
    it 'filters by an organisation id written in capitals' do
      names = get_json("/api/v1/projects?organisation_id=#{org_a.id.upcase}", pat)['data'].map { |p| p['name'] }
      expect(names).to eq(['Alpha project'])
    end
  end

  # Pundit memoises policy_scope per scope object. Asked with the bare class once per
  # organisation, the second organisation got the first one's answer: until 2026-10-02
  # /projects listed the first organisation's projects once per linked organisation.
  context 'with a link token for two organisations' do
    let!(:pat) do
      Prosopite.pause do
        member(org_a)
        member(org_later)
        project_in(org_a, 'Alpha project')
        project_in(org_later, 'Later project')
      end
      minted(organisations: [org_a, org_later])
    end

    it 'lists the projects of each organisation once' do
      names = get_json('/api/v1/projects', pat)['data'].map { |p| p['name'] }
      expect(names).to contain_exactly('Alpha project', 'Later project')
    end
  end

  context 'with a link token whose owner was deactivated in one of its organisations' do
    let!(:pat) do
      Prosopite.pause do
        member(org_a)
        member(org_left)
      end
      minted(organisations: [org_a, org_left])
    end

    before { Membership.where(user: user, organisation: org_left).update_all(active: false) }

    it 'no longer names that organisation on /me' do
      names = get_json('/api/v1/me', pat)['data']['scoped_organisations'].map { |o| o['name'] }
      expect(names).to eq(['Alpha GmbH'])
    end

    it 'no longer lists open hours of that organisation' do
      left_project = Prosopite.pause { project_in(org_left, 'Left project') }
      ActsAsTenant.with_tenant(org_left) do
        TimeSession.create!(project: left_project, organisation: org_left, creator: user,
                            occurred_on: 2.days.ago, duration: 30)
      end

      data = get_json('/api/v1/time_sessions/open', pat)['data']
      expect(data.map { |s| s['organisation_id'] || s.dig('organisation', 'id') }.compact).not_to include(org_left.id)
      expect(data.size).to eq(0)
    end
  end
end
