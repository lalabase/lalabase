# frozen_string_literal: true

require 'rails_helper'

# What: two answers of GET /api/v1/projects that the shared reader must not change.
# Why: PersonalAccessTokens::ReachListing also serves the MCP tool list_projects, which
#   leaves archived projects out and refuses an unusable organisation_id. REST does
#   neither, and a client reads it that way: an admin gets archived projects, marked,
#   and an id that cannot be a UUID finds nothing instead of everything.
RSpec.describe 'GET /api/v1/projects, what the MCP tool does differently', :ci_guard, type: :request do
  let(:user) { create(:user) }
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:pat) do
    build(:personal_access_token, user: user, organisations: [organisation]).tap do |token|
      token.token_hash = nil
      token.token_prefix = nil
      token.generate_token!
    end
  end

  before { make_token_owner_a_member(user, organisation, projects: [project]) }

  def rows(query = '')
    get "/api/v1/projects#{query}", headers: { 'Authorization' => "Bearer #{pat.token}" }
    response.parsed_body['data']
  end

  it 'shows an admin archived projects, marked' do
    archived = ActsAsTenant.with_tenant(organisation) do
      Membership.find_by!(user: user, organisation: organisation)
                .update!(role: create(:admin_role, organisation: organisation))
      create(:project, organisation: organisation, archived_at: 1.day.ago)
    end

    expect(rows.find { |row| row['id'] == archived.id }).to include('archived' => true)
  end

  it 'finds nothing for an organisation_id that cannot be a UUID, not everything' do
    project

    expect(rows('?organisation_id=oops')).to eq([])
  end

  it 'lists every organisation in reach without one' do
    expect(rows.pluck('id')).to eq([project.id])
  end
end
