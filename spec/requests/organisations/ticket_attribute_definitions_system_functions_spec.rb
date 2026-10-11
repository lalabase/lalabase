# frozen_string_literal: true

require 'rails_helper'

# System functions arrive as a hash of option index => list of function keys
# ({ "1" => ["high_priority"] }). They used to be taken with `permit!`, which let any
# shape through, and a plain string instead of a list raised NoMethodError (500).
RSpec.describe 'Ticket attribute definitions: option system functions', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:priority) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket_attribute_definition, :select, project: project, name: 'priority',
                                                    options: { 'allowed_values' => [
                                                      { 'value' => 'low', 'labels' => { 'de' => 'low' } },
                                                      { 'value' => 'high', 'labels' => { 'de' => 'high' } }
                                                    ] })
    end
  end

  before { sign_in user }

  def update_with(system_functions)
    patch organisation_project_ticket_attribute_definition_path(organisation, project, priority),
          params: { ticket_attribute_definition: { field_type: 'select', options: %w[low high],
                                                   option_system_functions: system_functions } }
  end

  def functions_of(value)
    entry = priority.reload.options['allowed_values'].find { |option| option['value'] == value }
    entry['system_functions']
  end

  it 'stores a list of function keys for an option' do
    update_with('1' => ['high_priority'])

    expect(response).to have_http_status(:redirect)
    expect(functions_of('high')).to eq(['high_priority'])
  end

  it 'accepts a single key sent as a string instead of a list' do
    update_with('1' => 'high_priority')

    expect(response).to have_http_status(:redirect)
    expect(functions_of('high')).to eq(['high_priority'])
  end

  it 'ignores indexes that match no option' do
    update_with('1' => ['high_priority'], '7' => ['is_new'])

    expect(response).to have_http_status(:redirect)
    expect(functions_of('low')).to be_nil
    expect(functions_of('high')).to eq(['high_priority'])
  end
end
