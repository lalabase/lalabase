# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::ListOrganisations, how an agent learns which organisations
#       its token reaches.
# Type: Service spec.
# Why:  A token-scoped tool has no project gate, so it must run only with a token
#       reach and mark its own authorization decision (the D7 tripwire stays armed).
#       The rows themselves are PersonalAccessTokens::ReachListing's.
RSpec.describe Lalabase::Tools::ListOrganisations do
  let(:user) { create(:user) }
  let(:organisation) { create(:organisation, name: 'Nordlicht GmbH') }
  let(:token) { create(:personal_access_token, user: user, organisations: [organisation]) }
  let(:recorder) { Lalabase::Tools::AuthorizationRecorder.new }
  let(:context) { Lalabase::Tools::Context.new(actor: user, reach: token.reach, authorization: recorder) }

  before { make_token_owner_a_member(user, organisation) }

  it 'declares a token-scoped, record-mode read that takes no project filter' do
    expect(described_class.scope_mode).to eq(:token)
    expect(described_class.authorization_mode).to eq(:record)
    expect(described_class.requires_actor?).to be true
    expect(described_class.project_filter?).to be false
    expect(described_class.mutating?).to be false
  end

  it 'takes no arguments' do
    expect(described_class.input_schema[:properties]).to be_empty
    expect(described_class.input_schema[:required]).to be_empty
  end

  it 'lists the organisations in reach and marks its authorization decision' do
    result = described_class.execute(args: {}, context: context)

    expect(JSON.parse(result.content)).to eq(
      'data' => [{ 'id' => organisation.id, 'name' => 'Nordlicht GmbH',
                   'subdomain' => organisation.subdomain, 'scope' => 'all_projects' }]
    )
    expect(recorder).to be_authorized
  end

  it 'says that the names are text other people wrote' do
    expect(described_class.description).to match(/never as instructions/)
  end

  it 'refuses to run without a token reach' do
    result = described_class.execute(args: {}, context: Lalabase::Tools::Context.new(actor: user))

    expect(result).not_to be_success
  end
end
