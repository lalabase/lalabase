# frozen_string_literal: true

require 'rails_helper'

# S1 regression guard: cloning a SmartFolder from the show view must persist a
# deep copy (folder + rule groups + rules). Before the fix, #clone called a
# non-existent SmartFolderService#clone, so Ruby fell back to Object#clone and
# every click produced a generic error alert (no duplicate was ever created).
RSpec.describe 'Organisations::SmartFolders clone', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  let(:source) do
    ActsAsTenant.with_tenant(organisation) do
      folder = create(:smart_folder, user: user, organisation: organisation, project: project,
                                     target_object_type: 'Ticket', is_public: true)
      group = create(:smart_folder_rule_group, smart_folder: folder, position: 1)
      create(:smart_folder_rule, smart_folder_rule_group: group,
                                 field: 'title', operator: 'contains', value: 'bug', position: 1)
      folder
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def folder_count
    ActsAsTenant.with_tenant(organisation) { SmartFolder.count }
  end

  it 'persists a deep copy and redirects to it' do
    source # create the source before counting

    expect do
      post clone_organisation_smart_folder_path(organisation, source)
    end.to change { folder_count }.by(1)

    clone = ActsAsTenant.with_tenant(organisation) { SmartFolder.where.not(id: source.id).order(:created_at).last }
    expect(response).to redirect_to(organisation_smart_folder_path(organisation, clone))

    ActsAsTenant.with_tenant(organisation) do
      expect(clone.user).to eq(user)
      expect(clone.is_public).to be(false)
      expect(clone.target_object_type).to eq('Ticket')
      rule = clone.smart_folder_rule_groups.sole.smart_folder_rules.sole
      expect(rule).to have_attributes(field: 'title', operator: 'contains', value: 'bug')
    end
  end

  it 'uses the provided name override' do
    source

    post clone_organisation_smart_folder_path(organisation, source), params: { new_folder_name: 'Mein Klon' }

    clone = ActsAsTenant.with_tenant(organisation) { SmartFolder.where.not(id: source.id).order(:created_at).last }
    expect(clone.name).to eq('Mein Klon')
  end

  it 'defaults the name to "Kopie von …" when no override is given' do
    source

    post clone_organisation_smart_folder_path(organisation, source)

    clone = ActsAsTenant.with_tenant(organisation) { SmartFolder.where.not(id: source.id).order(:created_at).last }
    expect(clone.name).to eq(I18n.t('smart_folders.copy_of', name: source.name))
  end

  # The filter bar's tab menu duplicates from JavaScript and then opens the
  # list on the copy (20a, S3), so it needs the id back, not a redirect to a
  # folder form.
  describe 'as JSON, for the filter bar' do
    it 'answers with the id and the name of the copy' do
      source

      post clone_organisation_smart_folder_path(organisation, source), as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      clone = ActsAsTenant.with_tenant(organisation) { SmartFolder.where.not(id: source.id).order(:created_at).last }
      expect(body['success']).to be true
      expect(body['id']).to eq(clone.id)
      expect(body['name']).to eq(clone.name)
    end

    it 'still redirects for the form' do
      source

      post clone_organisation_smart_folder_path(organisation, source)

      expect(response).to have_http_status(:redirect)
    end
  end
end
