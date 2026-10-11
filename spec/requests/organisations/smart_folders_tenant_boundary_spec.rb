# frozen_string_literal: true

require 'rails_helper'

# A saved view is bound to a project of its own organisation or to none. The
# project id arrives as a raw form value, so the model has to refuse a project
# of another organisation for every view type, even for an account admin.
RSpec.describe 'Saved views stay inside their organisation', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:other_organisation) { create(:organisation) }
  let(:foreign_project) { ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) } }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation), active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def folder_count
    ActsAsTenant.without_tenant { SmartFolder.count }
  end

  SmartFolder::SUPPORTED_OBJECT_TYPES.each_key do |target|
    it "refuses a #{target} view bound to a project of another organisation" do
      foreign_project
      expect do
        post organisation_smart_folders_path(organisation), params: {
          smart_folder: { name: 'Cross tenant', target_object_type: target, project_id: foreign_project.id }
        }
      end.not_to(change { folder_count })
      # Meeting views look the project up among the reader's meeting projects
      # first (404); every other type is refused by the model (422).
      expect(response).to have_http_status(target == 'Meeting' ? :not_found : :unprocessable_content)
    end
  end
end
