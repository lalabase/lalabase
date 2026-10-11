# frozen_string_literal: true

# What: Request spec for the status quick-change side path of post creation
#   (posts#create → handle_ticket_status_change), now routed through
#   Actors::ApplyTicketChanges with a set of one (formerly SetTicketAttribute).
# Why: pins the F2 decision at the request level — a legacy-invalid NEIGHBOUR
#   attribute must not block the status write while commenting (the old inline path
#   did NOT skip validation and could fail here). Also proves the happy path still
#   writes the status.

require 'rails_helper'

RSpec.describe 'Organisations::Posts status quick-change', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) } }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  let!(:status_attr) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket_attribute_definition, project: project, name: 'status', system: true, field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu', 'en' => 'New' } },
                                             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt', 'en' => 'Done' } }
                                           ] })
    end
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user,
                      custom_attributes: { 'status' => 'Neu' })
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Current.user = user
  end

  after { Current.reset }

  def create_post_with_status(status)
    post organisation_project_ticket_posts_path(organisation, project, ticket),
         params: { post: { content: 'A comment' }, ticket_status: status }
  end

  def stored_status
    ActsAsTenant.with_tenant(organisation) { ticket.reload.get_custom_attribute('status') }
  end

  it 'applies the status change while commenting' do
    create_post_with_status('Erledigt')
    expect(stored_status).to eq('Erledigt')
  end

  it 'ignores a status value that is not allowed (best-effort side effect)' do
    create_post_with_status('Bogus')
    expect(response).not_to have_http_status(:internal_server_error)
    expect(stored_status).to eq('Neu')
  end

  context 'with a legacy-invalid neighbour attribute (F2 regression)' do
    let!(:priority_attr) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket_attribute_definition, project: project, name: 'priority', field_type: 'select',
                                             options: { 'allowed_values' => [
                                               { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } },
                                               { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } }
                                             ] })
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        ticket.update_columns(custom_attributes: { 'status' => 'Neu', 'priority' => 'LEGACY_BOGUS' })
      end
    end

    it 'still writes the status despite the invalid neighbour (skip_validation, F2)' do
      create_post_with_status('Erledigt')
      expect(response).not_to have_http_status(:internal_server_error)
      expect(stored_status).to eq('Erledigt')
    end

    it 'leaves the invalid neighbour value untouched' do
      create_post_with_status('Erledigt')
      expect(ActsAsTenant.with_tenant(organisation) { ticket.reload.get_custom_attribute('priority') }).to eq('LEGACY_BOGUS')
    end
  end
end
