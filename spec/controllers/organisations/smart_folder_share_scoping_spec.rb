# frozen_string_literal: true

require 'rails_helper'

# R2 regression guard: the SmartFolder share picker (#share) and the share write path
# (#perform_share) must be scoped to users with access to the folder's project — not the
# whole organisation. A tampered share_user_ids must not be able to share with a
# foreign-project user. (Controller spec so the picker assignment is asserted directly,
# independent of the share view.)
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

  let(:owner) { member_in }
  let(:colleague) { member_in }
  let(:foreigner) { member_in }

  let(:project_a) { create(:project, organisation: organisation) }
  let(:project_b) { create(:project, organisation: organisation) }

  let(:smart_folder) do
    create(:smart_folder, organisation: organisation, user: owner, project: project_a, target_object_type: 'Ticket')
  end

  before do
    routes.draw do
      root 'static#index'
      scope path: '/org/:organisation_id', module: :organisations, as: :organisation do
        resources :smart_folders do
          member do
            get :share
            post :perform_share
            delete 'unshare/:user_id', to: 'smart_folders#unshare', as: :unshare_user
          end
        end
      end
    end

    ActsAsTenant.current_tenant = organisation
    create(:project_permission, user: owner, project: project_a, tickets_access: 'read_write')
    create(:project_permission, user: colleague, project: project_a, tickets_access: 'read_only')
    create(:project_permission, user: foreigner, project: project_b, tickets_access: 'read_only')
    sign_in owner
  end

  after do
    ActsAsTenant.current_tenant = nil
    # routes.draw above replaces the global route set; restore it so request specs that run
    # afterwards (e.g. project_access_scoping_spec) keep their named routes.
    Rails.application.reload_routes!
  end

  describe 'GET #share (picker)' do
    it 'offers users with access to the folder project, never foreign-project users' do
      get :share, params: { organisation_id: organisation.id, id: smart_folder.id }

      expect(assigns(:users_for_sharing)).to include(colleague)
      expect(assigns(:users_for_sharing)).not_to include(foreigner)
    end

    it 'excludes the owner from the picker' do
      get :share, params: { organisation_id: organisation.id, id: smart_folder.id }

      expect(assigns(:users_for_sharing)).not_to include(owner)
    end
  end

  describe 'POST #perform_share' do
    it 'shares with a project colleague' do
      expect do
        post :perform_share,
             params: { organisation_id: organisation.id, id: smart_folder.id, share_user_ids: [colleague.id] }
      end.to change { SmartFolderShare.where(smart_folder: smart_folder, user_id: colleague.id).count }.by(1)
    end

    it 'refuses to share with a user from another project (IDOR via tampered ids)' do
      expect do
        post :perform_share,
             params: { organisation_id: organisation.id, id: smart_folder.id, share_user_ids: [foreigner.id] }
      end.not_to change(SmartFolderShare, :count)
    end
  end

  describe 'DELETE #unshare' do
    it 'revokes an existing share on the folder' do
      create(:smart_folder_share, smart_folder: smart_folder, user: colleague)

      expect do
        delete :unshare, params: { organisation_id: organisation.id, id: smart_folder.id, user_id: colleague.id }
      end.to change { smart_folder.smart_folder_shares.where(user_id: colleague.id).count }.from(1).to(0)
    end
  end
end
