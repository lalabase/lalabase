# frozen_string_literal: true

require 'rails_helper'

# Sorting of the saved-views list. The column and direction come from params and
# end up in ORDER BY, so both are held to an allowlist; an unexpected shape (an
# array instead of a string) must not turn into a 500.
RSpec.describe 'Organisations::SmartFolders GET #index sorting', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    %w[Bravo Alpha Charlie].each do |name|
      create(:smart_folder, name: name, user: user, organisation: organisation, project: project,
                            target_object_type: 'Ticket', is_public: true)
    end
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def folder_names(params)
    get organisation_smart_folders_path(organisation, format: :json), params: params
    expect(response).to have_http_status(:ok)
    response.parsed_body['smart_folders'].pluck('name')
  end

  it 'sorts by an allowed column in both directions' do
    expect(folder_names(sort: 'name', direction: 'asc')).to eq(%w[Alpha Bravo Charlie])
    expect(folder_names(sort: 'name', direction: 'DESC')).to eq(%w[Charlie Bravo Alpha])
  end

  it 'ignores a column outside the allowlist' do
    expect(folder_names(sort: 'name; DROP TABLE smart_folders', direction: 'asc').size).to eq(3)
  end

  it 'answers an array direction with the default order instead of a 500' do
    expect(folder_names(sort: 'name', direction: ['asc']).size).to eq(3)
  end
end
