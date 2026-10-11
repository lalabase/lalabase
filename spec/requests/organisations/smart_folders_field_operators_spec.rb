# frozen_string_literal: true

require 'rails_helper'

# The rule builder of the expert filter gets its operators per field from this
# endpoint, and since the date presets became operators it also gets the list of
# operators that take no value ("valueless"), owned by
# SmartFolderRule.optional_value_operators, instead of keeping a copy of it
# (doc/filter_datumsvorgaben_rundlauf_plan.md, D3).
RSpec.describe 'GET smart_folders#field_operators: operators and the valueless ones', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:admin) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      create(:ticket_attribute_definition, project: project, name: 'frist', field_type: 'date',
                                           labels: { 'de' => 'Frist', 'en' => 'Deadline' }, options: { 'deadline' => true })
    end
    sign_in admin
  end

  def operators_for(field, **params)
    get organisation_field_operators_path(organisation, field: field, **params),
        headers: { 'Accept' => 'application/json', 'X-Requested-With' => 'XMLHttpRequest' }
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  it 'lists every date preset on created_at, labelled, and lists it as valueless' do
    body = operators_for('created_at')
    labels = body['operators'].to_h { |op| [op['value'], op['label']] }

    SmartFolders::DatePresets::KEYS.each do |preset|
      expect(labels).to have_key(preset)
      expect(body['valueless']).to include(preset)
    end
    expect(labels['this_week']).to eq('ist in dieser Woche')
    expect(body['valueless']).not_to include('between', 'in_the_last_days')
  end

  it 'lists the deadline presets and is_empty of the deadline field as valueless' do
    body = operators_for('custom_frist', project_id: project.id)

    expect(body['valueless']).to include('is_empty', *Ticket::DUE_DATE_PRESET_KEYS)
    expect(body['valueless']).not_to include('before', *SmartFolders::DatePresets::KEYS)
  end
end
