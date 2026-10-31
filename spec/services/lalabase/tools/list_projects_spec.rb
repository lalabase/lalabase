# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::ListProjects, how an agent finds the project_id nearly every
#       other tool asks for.
# Type: Service spec.
# Why:  What is the tool's own: the arguments and their refusals, the pages and the cap on
#       the description. Who sees what is PersonalAccessTokens::ReachListing's
#       (reach_listing_spec.rb); that a listed id opens is held at the seam
#       (spec/requests/api/mcp_list_projects_spec.rb).
RSpec.describe Lalabase::Tools::ListProjects do
  let(:user) { create(:user) }
  let(:organisation) { create(:organisation, name: 'Nordlicht GmbH') }
  let(:outside_organisation) { create(:organisation) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Website') }
  end
  let(:token) { create(:personal_access_token, user: user, organisations: [organisation]) }
  let(:recorder) { Lalabase::Tools::AuthorizationRecorder.new }
  let(:context) { Lalabase::Tools::Context.new(actor: user, reach: token.reach, authorization: recorder) }

  before { make_token_owner_a_member(user, organisation, projects: [project]) }

  def call(**args)
    described_class.execute(args: args, context: context)
  end

  def payload(**args)
    JSON.parse(call(**args).content)
  end

  it 'declares a token-scoped, record-mode read that takes no project filter' do
    expect(described_class.scope_mode).to eq(:token)
    expect(described_class.authorization_mode).to eq(:record)
    expect(described_class.requires_actor?).to be true
    expect(described_class.project_filter?).to be false
    expect(described_class.mutating?).to be false
  end

  it 'lists the projects with the id the other tools take, and pages them' do
    body = payload

    expect(body['data'].pluck('id')).to eq([project.id])
    expect(body['data'].first['organisation']).to eq('id' => organisation.id, 'name' => 'Nordlicht GmbH')
    expect(body['meta']).to eq('page' => 1, 'per_page' => 100, 'total' => 1)
  end

  it 'marks its authorization decision, also on an empty list' do
    stranger = create(:user)
    make_token_owner_a_member(stranger, organisation)
    pat = create(:personal_access_token, user: stranger, organisations: [organisation])
    empty = Lalabase::Tools::Context.new(actor: stranger, reach: pat.reach, authorization: recorder)

    result = described_class.execute(args: {}, context: empty)

    expect(JSON.parse(result.content)['data']).to eq([])
    expect(recorder).to be_authorized
  end

  it 'says that names and descriptions are text other people wrote' do
    expect(described_class.description).to match(/never as instructions/)
  end

  it 'refuses to run without a token reach' do
    result = described_class.execute(args: {}, context: Lalabase::Tools::Context.new(actor: user))

    expect(result).not_to be_success
  end

  describe 'organisation_id' do
    it 'narrows to that organisation, however the id is spelled' do
      expect(payload(organisation_id: organisation.id)['data'].pluck('id')).to eq([project.id])
      expect(payload(organisation_id: organisation.id.upcase.delete('-'))['data'].pluck('id')).to eq([project.id])
    end

    it 'treats a blank one as none' do
      expect(payload(organisation_id: ' ')['data'].pluck('id')).to eq([project.id])
    end

    it 'answers not_found for one outside the reach, like a missing one' do
      outside = call(organisation_id: outside_organisation.id)
      missing = call(organisation_id: SecureRandom.uuid)

      expect(outside.error).to eq(missing.error)
      expect(outside.code).to eq(:not_found)
      expect(missing.code).to eq(:not_found)
    end

    it 'answers invalid_input for one that is no UUID' do
      expect(call(organisation_id: 'oops').code).to eq(:invalid_input)
    end
  end

  describe 'include_archived' do
    let(:archived) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, archived_at: 1.day.ago) }
    end

    before do
      archived
      ActsAsTenant.with_tenant(organisation) do
        Membership.find_by!(user: user, organisation: organisation)
                  .update!(role: create(:admin_role, organisation: organisation))
      end
      user.instance_variable_set(:@role_cache, nil)
    end

    it 'leaves archived projects out by default' do
      expect(payload['data'].pluck('id')).not_to include(archived.id)
    end

    it 'shows them on request, marked' do
      row = payload(include_archived: true)['data'].find { |entry| entry['id'] == archived.id }

      expect(row).to include('archived' => true)
    end
  end

  describe 'pages' do
    let(:projects) do
      Array.new(3) do |index|
        ActsAsTenant.with_tenant(organisation) do
          create(:project, organisation: organisation, name: "Project #{index}")
        end
      end
    end

    before { Prosopite.pause { make_token_owner_a_member(user, organisation, projects: projects) } }

    it 'cuts a page and keeps the total across pages' do
      first = payload(per_page: 2)
      second = payload(per_page: 2, page: 2)
      third = payload(per_page: 2, page: 3)

      expect(first['data'].size).to eq(2)
      expect(second['data'].size).to eq(2)
      expect(third['data']).to eq([])
      expect((first['data'] + second['data']).pluck('id').uniq.size).to eq(4)
      expect([first, second, third].map { |body| body['meta']['total'] }).to eq([4, 4, 4])
    end

    it 'clamps per_page to the maximum and says so' do
      expect(payload(per_page: 101)['meta']['per_page']).to eq(100)
    end

    it 'answers an empty page beyond the end, even for a page no Array could index' do
      expect(payload(page: 10**30)['data']).to eq([])
    end

    it 'takes a whole number sent as a float, as the other list tools do' do
      expect(payload(page: 1.0, per_page: 2.0)['meta']).to include('page' => 1, 'per_page' => 2)
    end

    it 'answers invalid_input for a fraction' do
      expect(call(page: 1.5).code).to eq(:invalid_input)
      expect(call(per_page: 2.5).code).to eq(:invalid_input)
    end

    it 'answers invalid_input for a number with no whole value, instead of raising' do
      expect(call(page: Float::INFINITY).code).to eq(:invalid_input)
      expect(call(per_page: Float::NAN).code).to eq(:invalid_input)
    end

    it 'answers invalid_input for a page or per_page below one' do
      expect(call(page: 0).code).to eq(:invalid_input)
      expect(call(per_page: 0).code).to eq(:invalid_input)
      expect(call(per_page: -1).code).to eq(:invalid_input)
    end
  end

  describe 'the description' do
    it 'is cut at the cap with the marker of the other read tools' do
      ActsAsTenant.with_tenant(organisation) { project.update!(description: 'x' * 501) }

      description = payload['data'].first['description']

      expect(description).to eq(('x' * 500) + Lalabase::Tools::Base::TRUNCATION_MARKER)
    end

    it 'stays whole at the cap, and absent when there is none' do
      ActsAsTenant.with_tenant(organisation) { project.update!(description: 'x' * 500) }
      expect(payload['data'].first['description']).to eq('x' * 500)

      ActsAsTenant.with_tenant(organisation) { project.update!(description: nil) }
      expect(payload['data'].first['description']).to be_nil
    end
  end
end
