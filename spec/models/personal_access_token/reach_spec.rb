# frozen_string_literal: true

require 'rails_helper'

# What: PersonalAccessToken::Reach, the token's contract as a value object.
# Type: Model spec.
# Why:  Token-wide reads (the HTTP inbox, the MCP tool list_notifications) apply
#       the token's project scope through this object instead of the per-project
#       gate, so the two spellings of the rule must agree: #project? is pinned
#       against #accessible_project? for every combination the scope tables allow.
RSpec.describe PersonalAccessToken::Reach, :ci_guard do
  subject(:reach) { token.reach }

  let(:org_a) { create(:organisation) }
  let(:org_b) { create(:organisation) }
  let(:org_c) { create(:organisation) }
  let(:user) { create(:user) }
  let(:a1) { ActsAsTenant.with_tenant(org_a) { create(:project, organisation: org_a) } }
  let(:a2) { ActsAsTenant.with_tenant(org_a) { create(:project, organisation: org_a) } }
  let(:b1) { ActsAsTenant.with_tenant(org_b) { create(:project, organisation: org_b) } }
  let(:c1) { ActsAsTenant.with_tenant(org_c) { create(:project, organisation: org_c) } }

  # The owner is an active member of all three organisations: the reach counts
  # only organisations where that is true (#organisation_scopes).
  # Setup, not a request: three factory rows in a loop are no N+1 worth flagging.
  let!(:memberships) do
    Prosopite.pause do
      [org_a, org_b, org_c].index_with do |org|
        ActsAsTenant.with_tenant(org) { create(:membership, user: user, organisation: org, active: true) }
      end
    end
  end

  # org_a restricted to a1, org_b with every project, org_c outside the scope.
  let(:token) do
    create(:personal_access_token, user: user, organisations: [org_a, org_b], project_scopes: { org_a => [a1] })
  end

  it 'names exactly the scoped organisations' do
    expect(reach.organisation_ids).to contain_exactly(org_a.id, org_b.id)
    expect(reach.organisation?(org_c.id)).to be false
  end

  it 'restricts a project-linked organisation to its linked projects' do
    expect(reach.project_ids_for(org_a.id)).to eq([a1.id])
  end

  it 'leaves an all_projects organisation unrestricted (nil = every project)' do
    expect(reach.project_ids_for(org_b.id)).to be_nil
  end

  it 'answers nothing, not everything, for an organisation outside the scope' do
    expect(reach.project_ids_for(org_c.id)).to eq([])
  end

  it 'answers project? exactly like PersonalAccessToken#accessible_project?' do
    expect([a1, a2, b1, c1].map { |project| reach.project?(project) }).to eq([true, false, true, false])
    # accessible_project? queries per call by design (it decides whether a tenant
    # may be set); four calls in a row are the parity check, not an N+1.
    Prosopite.pause do
      [a1, a2, b1, c1].each do |project|
        expect(reach.project?(project)).to eq(token.accessible_project?(project)), project.id
      end
    end
    expect(reach.project?(nil)).to be false
  end

  it 'answers project_id? like the object and per-project gates using routing IDs' do
    projects = [a1, a2, b1, c1]
    Prosopite.pause do
      projects.each do |project|
        expected = token.accessible_project?(project)
        expect(reach.project_id?(project.organisation_id, project.id)).to eq(expected), project.id
        expect(reach.project?(project)).to eq(expected), project.id
      end
    end
  end

  it 'denies every project when the selected-project list is empty' do
    empty_reach = described_class.new(project_ids_by_organisation: { org_a.id => [] })
    expect(empty_reach.project_id?(org_a.id, a1.id)).to be false
    expect(empty_reach.project?(a1)).to be false
  end

  it 'drops an organisation once the owner\'s membership there is inactive, like accessible_project?' do
    memberships[org_b].update!(active: false)

    expect(reach.organisation?(org_b.id)).to be false
    expect(reach.project?(b1)).to be false
    expect(token.accessible_project?(b1)).to be false
    expect(reach.project?(a1)).to be true
  end

  it 'is memoised on the token' do
    expect(token.reach).to be(reach)
  end
end
