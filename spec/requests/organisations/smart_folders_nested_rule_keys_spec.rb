# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the silent nested-attributes drop in the smart folder
# modal form (found live 2026-07-14): ActionController::Parameters#permit only
# treats hash keys that LOOK LIKE INTEGERS as fields_for-style child indices.
# A prefixed key such as "new_rule_1784049277296" is dropped WITHOUT any error —
# #update answers 200 OK while the added rule never reaches the model.
#
# Contract pinned here, both halves:
#   1. Server: #update persists rules/groups submitted under pure-integer
#      timestamp child indices (the shape the form JS emits after the fix).
#   2. Client: smart_folder_form_controller.js must inject pure-integer child
#      indices. Source-level guard because the JS has no DOM test lane
#      (importmap project; npm test only covers pure functions).
RSpec.describe 'Organisations::SmartFolders nested rule child indices', type: :request do
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
    create(:smart_folder, user: user, organisation: organisation, project: project, target_object_type: 'Ticket')
  end
  let(:group) { create(:smart_folder_rule_group, smart_folder: folder, position: 1) }
  let(:existing_rule) do
    create(:smart_folder_rule, smart_folder_rule_group: group,
                               field: 'title', operator: 'contains', value: 'alt', position: 1)
  end

  describe 'PATCH #update with JS-generated integer child indices' do
    it 'updates the existing rule and persists the rule added under a timestamp key' do
      existing_rule

      patch organisation_smart_folder_path(organisation, folder), params: {
        smart_folder: {
          name: folder.name,
          smart_folder_rule_groups_attributes: {
            '0' => {
              'id' => group.id, '_destroy' => 'false', 'position' => '1',
              'smart_folder_rules_attributes' => {
                '0' => { 'id' => existing_rule.id, 'field' => 'title', 'operator' => 'contains',
                         'value' => 'neu', '_destroy' => 'false', 'position' => '1' },
                '1784049277296' => { 'field' => 'title', 'operator' => 'contains',
                                     'value' => 'zusatz', '_destroy' => 'false', 'position' => '2' }
              }
            }
          }
        }
      }

      expect(response).to have_http_status(:redirect)
      expect(group.smart_folder_rules.reload.count).to eq(2)
      expect(existing_rule.reload.value).to eq('neu')
      expect(group.smart_folder_rules.pluck(:value)).to include('zusatz')
    end

    it 'persists a brand-new group including its nested rule (both timestamp-keyed)' do
      existing_rule

      patch organisation_smart_folder_path(organisation, folder), params: {
        smart_folder: {
          name: folder.name,
          smart_folder_rule_groups_attributes: {
            '0' => { 'id' => group.id, '_destroy' => 'false', 'position' => '1' },
            '1784049300000' => {
              '_destroy' => 'false', 'position' => '2',
              'smart_folder_rules_attributes' => {
                '1784049300001' => { 'field' => 'title', 'operator' => 'contains',
                                     'value' => 'gruppe-zwei', '_destroy' => 'false', 'position' => '1' }
              }
            }
          }
        }
      }

      expect(response).to have_http_status(:redirect)
      expect(folder.smart_folder_rule_groups.reload.count).to eq(2)
      new_group = folder.smart_folder_rule_groups.order(:position).last
      expect(new_group.smart_folder_rules.pluck(:value)).to eq(['gruppe-zwei'])
    end
  end

  describe 'POST #create with JS-generated integer child indices' do
    it 'persists a folder whose extra rule was added under a timestamp key' do
      post organisation_smart_folders_path(organisation), params: {
        smart_folder: {
          name: 'Frisch angelegt', target_object_type: 'Ticket', project_id: project.id,
          smart_folder_rule_groups_attributes: {
            '0' => {
              '_destroy' => 'false', 'position' => '1',
              'smart_folder_rules_attributes' => {
                '0' => { 'field' => 'title', 'operator' => 'contains',
                         'value' => 'erste', '_destroy' => 'false', 'position' => '1' },
                '1784049277296' => { 'field' => 'title', 'operator' => 'contains',
                                     'value' => 'zweite', '_destroy' => 'false', 'position' => '2' }
              }
            }
          }
        }
      }

      expect(response).to have_http_status(:redirect)
      ActsAsTenant.with_tenant(organisation) do
        created = SmartFolder.find_by(name: 'Frisch angelegt')
        expect(created.smart_folder_rule_groups.first.smart_folder_rules.pluck(:value))
          .to contain_exactly('erste', 'zweite')
      end
    end
  end

  describe 'smart_folder_form_controller.js child index contract' do
    let(:js_source) do
      Rails.root.join('app/javascript/controllers/smart_folder_form_controller.js').read
    end

    it 'does not inject prefixed (non-integer) child indices' do
      # "new_rule_${timestamp}" / "new_group_${timestamp}" keys are what
      # permit() silently drops — the exact bug this file guards against.
      expect(js_source).not_to match(/new_(?:rule|group)_\$\{timestamp\}/)
    end

    it 'replaces the nested NEW_RULE_RECORD placeholder when adding a whole group' do
      # The group template ships with one nested rule; without this second
      # replacement its child index stays the literal "NEW_RULE_RECORD" and
      # the rule of a freshly added group is dropped as well.
      add_rule_group_body = js_source[/addRuleGroup\(event\).*?\n  \}/m]
      expect(add_rule_group_body).to include('NEW_RULE_RECORD')
    end
  end
end
