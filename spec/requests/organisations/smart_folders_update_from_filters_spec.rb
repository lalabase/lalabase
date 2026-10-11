# frozen_string_literal: true

require 'rails_helper'

# The endpoint behind "Änderung speichern" in the filter bar
# (doc/filterleiste_s1_s4_plan.md, S3). It replaces the whole rule tree of a
# folder with the conditions it receives, so two shapes of request must never
# reach the actor: an empty set (the view would match nothing from then on)
# and an org-wide folder without a project to read the attribute names from
# (the list sends its project_id along).
RSpec.describe 'Organisations::SmartFolders#update_from_filters', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  # Tenant-wrapped: a request resets the tenant, and this project is first
  # referenced after a PATCH in one example.
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:json) { { 'ACCEPT' => 'application/json' } }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def folder_with_tag_rule(project:)
    ActsAsTenant.with_tenant(organisation) do
      folder = create(:smart_folder, name: 'Tagged', organisation: organisation, project: project,
                                     user: user, target_object_type: 'Ticket')
      group = create(:smart_folder_rule_group, smart_folder: folder)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'has_any_of', value: 'bug,ui')
      folder
    end
  end

  def rule_values(folder)
    ActsAsTenant.with_tenant(organisation) do
      SmartFolderRule.joins(:smart_folder_rule_group)
                     .where(smart_folder_rule_groups: { smart_folder_id: folder.id })
                     .pluck(:field, :operator, :value)
    end
  end

  it 'replaces the rules with the conditions it receives' do
    folder = folder_with_tag_rule(project: project)

    patch update_from_filters_organisation_smart_folder_path(organisation, folder),
          params: { filter: { tag: ['bug'] } }, headers: json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('success' => true)
    expect(rule_values(folder)).to contain_exactly(%w[tag has_any_of bug])
  end

  it 'refuses an empty set and leaves the rules as they are' do
    folder = folder_with_tag_rule(project: project)

    patch update_from_filters_organisation_smart_folder_path(organisation, folder),
          params: { filter: { tag: [''] } }, headers: json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['success']).to be false
    expect(rule_values(folder)).to contain_exactly(['tag', 'has_any_of', 'bug,ui'])
  end

  # S7: the type condition is the folder's target, which is immutable. The
  # sanitizer would slice it away and the bar would record it as saved; the
  # endpoint refuses instead, and the bar offers "Als neue Ansicht" for that.
  it 'refuses a set that carries a type condition and leaves the rules as they are' do
    folder = folder_with_tag_rule(project: project)

    patch update_from_filters_organisation_smart_folder_path(organisation, folder),
          params: { filter: { tag: ['bug'], type: ['document'] } }, headers: json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['success']).to be false
    expect(rule_values(folder)).to contain_exactly(['tag', 'has_any_of', 'bug,ui'])
  end

  it "saves an org-wide folder with the list's project_id and refuses it without one" do
    folder = folder_with_tag_rule(project: nil)

    patch update_from_filters_organisation_smart_folder_path(organisation, folder),
          params: { filter: { tag: ['bug'] } }, headers: json
    expect(response).to have_http_status(:unprocessable_content)
    expect(rule_values(folder)).to contain_exactly(['tag', 'has_any_of', 'bug,ui'])

    patch update_from_filters_organisation_smart_folder_path(organisation, folder),
          params: { filter: { tag: ['bug'] }, project_id: project.id }, headers: json
    expect(response).to have_http_status(:ok)
    expect(rule_values(folder)).to contain_exactly(%w[tag has_any_of bug])
  end
  it 'keeps the rules when the conditions exceed what a view may hold' do
    folder = folder_with_tag_rule(project: project)
    ids = Array.new(8) { SecureRandom.uuid }

    patch update_from_filters_organisation_smart_folder_path(organisation, folder),
          params: { project_id: project.id, filter: { creator: ids, assignee: ids.reverse } }, headers: json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq(I18n.t('activerecord.errors.models.smart_folder.too_many_rule_groups', count: SmartFolder::MAX_RULE_GROUPS))
    expect(rule_values(folder)).to eq([%w[tag has_any_of bug,ui]])
  end
end
