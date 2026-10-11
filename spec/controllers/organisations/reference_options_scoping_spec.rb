# frozen_string_literal: true

require 'rails_helper'

# R4 integration guard (live endpoint): smart_folders#reference_options is the reachable
# filter-builder reference endpoint. PR #17 wired accessible_project_ids for Project/Ticket
# refs, but the helper's User branch stayed org-wide — so assignee references leaked
# foreign-project (even foreign-org) users. This asserts the User reference is now scoped.
RSpec.describe Organisations::SmartFoldersController, type: :controller do
  let(:organisation) { create(:organisation) }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  def member_in(role = standard_role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  let(:project_a) { create(:project, organisation: organisation) }
  let(:project_b) { create(:project, organisation: organisation) }
  let(:owner) { member_in }

  before do
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        get 'reference_options/:field', to: 'smart_folders#reference_options', as: 'reference_options'
      end
    end

    ActsAsTenant.current_tenant = organisation
    create(:project_permission, user: owner, project: project_a, tickets_access: 'read_write')
    sign_in owner
  end

  after do
    ActsAsTenant.current_tenant = nil
    Rails.application.reload_routes!
  end

  describe 'GET #reference_options (assignee)' do
    it 'scopes assignee options to users the requester can see' do
      colleague = member_in
      foreigner = member_in
      create(:project_permission, user: colleague, project: project_a, tickets_access: 'read_only')
      create(:project_permission, user: foreigner, project: project_b, tickets_access: 'read_only')

      get :reference_options, params: { organisation_id: organisation.id, field: 'assignee', project_id: project_a.id }

      ids = JSON.parse(response.body)['options'].map { |o| o['value'] }
      expect(ids).to include(colleague.id)
      expect(ids).not_to include(foreigner.id)
    end
  end
end
