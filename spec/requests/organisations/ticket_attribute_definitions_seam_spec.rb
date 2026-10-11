# frozen_string_literal: true

# What: Request spec for the attribute-management writes now on the actor seam
#   (ticket_attribute_definitions#sort → SortTicketAttributeDefinitions,
#   #execute_merge → MergeTicketAttributeOption).
# Why: proves the controller wiring — sort persists + 200, merge redirects with the
#   count-bearing notice and the coded error alert — while the heavy behaviour is
#   covered at the actor level. Merge touches exactly ONE ticket here (no bulk N+1).

require 'rails_helper'

RSpec.describe 'Ticket attribute definitions seam (sort + merge)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { sign_in user }

  describe 'PATCH sort' do
    let!(:attr_a) { ActsAsTenant.with_tenant(organisation) { create(:ticket_attribute_definition, project: project, name: 'aaa', position: 0) } }
    let!(:attr_b) { ActsAsTenant.with_tenant(organisation) { create(:ticket_attribute_definition, project: project, name: 'bbb', position: 1) } }

    it 'persists the new order and returns 200' do
      patch sort_organisation_project_ticket_attribute_definitions_path(organisation, project),
            params: { ids: [attr_b.id, attr_a.id] }

      expect(response).to have_http_status(:ok)
      expect(attr_b.reload.position).to eq(0)
      expect(attr_a.reload.position).to eq(1)
    end

    it 'rejects a non-array ids param with 400' do
      patch sort_organisation_project_ticket_attribute_definitions_path(organisation, project), params: { ids: 'nope' }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'PATCH execute_merge' do
    let!(:status_attr) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                             options: { 'allowed_values' => [
                                               { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                                               { 'value' => 'closed', 'labels' => { 'de' => 'Erledigt', 'en' => 'Closed' } }
                                             ] })
      end
    end
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, creator: user, custom_attributes: { 'status' => 'open' })
      end
    end

    def do_merge(source:, target:)
      patch execute_merge_organisation_project_ticket_attribute_definition_path(organisation, project, status_attr),
            params: { source_value: source, target_value: target }
    end

    it 'merges the option, rewrites the ticket and shows the count in the notice' do
      do_merge(source: 'open', target: 'closed')

      expect(response).to redirect_to(organisation_project_ticket_attribute_definitions_path(organisation, project))
      expect(ticket.reload.get_custom_attribute('status')).to eq('closed')
      expect(status_attr.reload.allowed_values.map { |v| v['value'] }).to contain_exactly('closed')
      expect(flash[:notice]).to include('1')
    end

    it 'redirects with the coded error alert when source == target (no write)' do
      do_merge(source: 'open', target: 'open')

      expect(flash[:alert]).to eq(I18n.t('activerecord.errors.models.ticket_attribute_definition.source_equals_target'))
      expect(ticket.reload.get_custom_attribute('status')).to eq('open')
      expect(status_attr.reload.allowed_values.map { |v| v['value'] }).to include('open')
    end
  end
end
