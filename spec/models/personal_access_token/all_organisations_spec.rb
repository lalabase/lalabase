# frozen_string_literal: true

require 'rails_helper'

# What: a token with all_organisations reaches every organisation its owner is an ACTIVE
#   member of, at the moment of the request: one joined after the token was made counts,
#   one left or deactivated stops counting at once, one never joined never counts.
# Why: the option widens what a token reaches. PersonalAccessToken#organisation_scopes is
#   the ONE place that answers "which organisations does this token reach"; the gate
#   (accessible_organisation?, accessible_project?) and the token-wide reads (Reach) must
#   give the same answer through it, for flag tokens and for link tokens alike.
RSpec.describe PersonalAccessToken, :ci_guard, type: :model do
  let(:user) { create(:user) }
  let(:org_a) { create(:organisation) }
  let(:org_b) { create(:organisation) }
  let(:org_dormant) { create(:organisation) }
  let(:org_foreign) { create(:organisation) }

  def member(org, active: true)
    ActsAsTenant.with_tenant(org) { create(:membership, user: user, organisation: org, active: active) }
  end

  def project_in(org)
    ActsAsTenant.with_tenant(org) { create(:project, organisation: org) }
  end

  # A fresh instance, as the next request would load it: #reach is memoised per instance.
  def reloaded(token)
    described_class.find(token.id)
  end

  before do
    Prosopite.pause do
      member(org_a)
      member(org_b)
      member(org_dormant, active: false)
    end
  end

  let(:token) { create(:personal_access_token, :all_organisations, user: user) }

  describe 'validation' do
    it 'needs no organisation link' do
      expect(token).to be_valid
      expect(token.personal_access_token_organisations).to be_empty
    end

    it 'refuses organisation links next to the flag, so a token has one meaning' do
      both = build(:personal_access_token, :all_organisations, user: user, organisations: [org_a])
      expect(both).not_to be_valid
      expect(both.errors.details[:base]).to include(error: :organisation_links_with_all_organisations)
    end

    it 'refuses project links next to the flag too' do
      a1 = project_in(org_a)
      with_project = build(:personal_access_token, :all_organisations, user: user)
      with_project.personal_access_token_projects.build(project: a1)

      expect(with_project).not_to be_valid
      expect(with_project.errors.details[:base]).to include(error: :organisation_links_with_all_organisations)
    end

    it 'still refuses a token without the flag and without links' do
      expect(build(:personal_access_token, user: user)).not_to be_valid
    end

    it 'is off by default' do
      expect(described_class.new.all_organisations).to be(false)
    end
  end

  describe '#organisation_scopes' do
    it 'names every organisation with an active membership, each with all projects' do
      scopes = token.organisation_scopes
      expect(scopes.map(&:organisation_id)).to contain_exactly(org_a.id, org_b.id)
      expect(scopes).to all(be_all_projects)
    end

    it 'never names an organisation with a dormant membership or none' do
      ids = token.organisation_scopes.map(&:organisation_id)
      expect(ids).not_to include(org_dormant.id, org_foreign.id)
    end

    it 'names an organisation joined after the token was made' do
      token
      org_later = create(:organisation)
      member(org_later)

      expect(reloaded(token).organisation_scopes.map(&:organisation_id)).to include(org_later.id)
    end

    it 'drops an organisation the moment the membership is deactivated' do
      token
      Membership.where(user: user, organisation: org_b).update_all(active: false)

      expect(reloaded(token).organisation_scopes.map(&:organisation_id)).to contain_exactly(org_a.id)
    end

    it 'gives a link token its live links, as before' do
      a1 = project_in(org_a)
      link_token = create(:personal_access_token, user: user, organisations: [org_a, org_b, org_dormant],
                                                  project_scopes: { org_a => [a1] })
      scopes = link_token.organisation_scopes.index_by(&:organisation_id)

      expect(scopes.keys).to contain_exactly(org_a.id, org_b.id)
      expect(scopes[org_a.id]).not_to be_all_projects
      expect(scopes[org_b.id]).to be_all_projects
    end
  end

  describe 'the gate and the reach agree for a flag token' do
    let(:org_later) { create(:organisation) }
    let(:projects) do
      Prosopite.pause do
        { a: project_in(org_a), b: project_in(org_b), dormant: project_in(org_dormant),
          foreign: project_in(org_foreign), later: project_in(org_later) }
      end
    end

    before do
      token
      member(org_later)
    end

    it 'opens a project in an organisation joined later' do
      fresh = reloaded(token)
      expect(fresh.accessible_organisation?(org_later)).to be(true)
      expect(fresh.accessible_project?(projects[:later])).to be(true)
      expect(fresh.reach.project_ids_for(org_later.id)).to be_nil
    end

    it 'keeps a dormant or foreign organisation closed' do
      fresh = reloaded(token)
      expect(fresh.accessible_organisation?(org_dormant)).to be(false)
      expect(fresh.accessible_organisation?(org_foreign)).to be(false)
      expect(fresh.accessible_project?(projects[:dormant])).to be(false)
      expect(fresh.accessible_project?(projects[:foreign])).to be(false)
      expect(fresh.reach.organisation?(org_foreign.id)).to be(false)
    end

    it 'answers Reach#project? exactly like #accessible_project? for every project' do
      fresh = reloaded(token)
      # accessible_project? queries per call by design (it decides whether a tenant may be
      # set), so the loop repeats its query; same as reach_spec.rb.
      Prosopite.pause do
        projects.each_value do |project|
          expect(fresh.reach.project?(project)).to eq(fresh.accessible_project?(project)), project.organisation.name
        end
      end
    end
  end
end
