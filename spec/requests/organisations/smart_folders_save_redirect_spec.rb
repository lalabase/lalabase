# frozen_string_literal: true

require 'rails_helper'

# S5 guard for the extracted #save_success_redirect_path helper: #create and
# #update must land the user back where they came from (return_to = tickets/notes
# with a project context), else on the folder list. The cascade used to be
# duplicated verbatim across both actions; this pins the behaviour after DRYing it.
RSpec.describe 'Organisations::SmartFolders save redirect', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  let(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, user: user, organisation: organisation, project: project, target_object_type: 'Ticket')
    end
  end

  def patch_update(params)
    patch organisation_smart_folder_path(organisation, folder), params: { smart_folder: { name: 'Neuer Name' } }.merge(params)
  end

  describe 'PATCH #update' do
    it 'returns to the project tickets page for return_to=tickets' do
      patch_update(return_to: 'tickets')
      expect(response).to redirect_to(
        organisation_project_tickets_path(organisation_id: organisation.id, project_id: project.id)
      )
    end

    it 'returns to the project notes page for return_to=notes' do
      patch_update(return_to: 'notes')
      expect(response).to redirect_to(
        organisation_project_notes_path(organisation_id: organisation.id, project_id: project.id)
      )
    end

    it 'falls back to the folder list without return_to' do
      patch_update({})
      expect(response).to redirect_to(organisation_smart_folders_path(organisation_id: organisation.id))
    end
  end

  describe 'POST #create' do
    it 'returns to the project tickets page for return_to=tickets' do
      post organisation_smart_folders_path(organisation), params: {
        smart_folder: { name: 'Frisch', target_object_type: 'Ticket', project_id: project.id },
        return_to: 'tickets'
      }
      expect(response).to redirect_to(
        organisation_project_tickets_path(organisation_id: organisation.id, project_id: project.id)
      )
    end
  end
end
