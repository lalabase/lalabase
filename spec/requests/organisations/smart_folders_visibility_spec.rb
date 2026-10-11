# frozen_string_literal: true

require 'rails_helper'

# Whether a saved view is public is the owner's decision, or an admin's. A
# member the view is shared with may edit its rules and name, but must not
# publish somebody else's private view to the whole organisation.
RSpec.describe 'Who decides whether a saved view is public', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:owner) { member }
  let(:editor) { member }
  let!(:folder) do
    ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, name: 'Private view', user: owner, organisation: organisation, project: project,
                            target_object_type: 'Ticket', is_public: false, public_access_level: 0).tap do |view|
        create(:smart_folder_share, smart_folder: view, user: editor, can_edit: true, can_share: true)
      end
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def member
    create(:user).tap do |user|
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation), active: true)
        create(:project_permission, user: user, project: project, tickets_access: 'read_write')
      end
    end
  end

  def publish
    patch organisation_smart_folder_path(organisation, folder),
          params: { smart_folder: { name: 'Renamed view', is_public: '1', public_access_level: '2' } }
  end

  def visibility
    ActsAsTenant.with_tenant(organisation) { folder.reload.slice(:name, :is_public, :public_access_level) }
  end

  it 'keeps the view private when a shared editor tries to publish it' do
    sign_in editor
    publish
    expect(visibility).to eq('name' => 'Renamed view', 'is_public' => false, 'public_access_level' => 0)
  end

  it 'lets the owner publish the view' do
    sign_in owner
    publish
    expect(visibility).to eq('name' => 'Renamed view', 'is_public' => true, 'public_access_level' => 2)
  end

  it 'shows the visibility fields only to those who may change them' do
    [[editor, false], [owner, true]].each do |user, allowed|
      sign_in user
      get edit_organisation_smart_folder_path(organisation, folder)
      expect(response).to have_http_status(:ok)
      expect(Capybara.string(response.body).has_css?('input[name="smart_folder[is_public]"]', visible: :all)).to be(allowed)
    end
  end
end
