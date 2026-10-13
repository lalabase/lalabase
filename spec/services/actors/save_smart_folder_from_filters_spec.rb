# frozen_string_literal: true

require 'rails_helper'

# Actors::SaveSmartFolderFromFilters is the ONE persistence path for turning
# ad-hoc list filters into a SmartFolder — create (smart_folder: nil) and update
# (smart_folder: given, rule tree replaced) share it. Conversion logic itself is
# covered by ad_hoc_to_smart_folder_service_spec.rb.
RSpec.describe Actors::SaveSmartFolderFromFilters do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    create(:project_permission, user: user, project: project, tickets_access: 'read_write')
  end

  after { ActsAsTenant.current_tenant = nil }

  describe 'create (smart_folder: nil)' do
    def create_from(filter_params: { 'tag' => %w[bug] }, **opts)
      described_class.call(
        project: project, current_user: user,
        filter_params: filter_params, operator_params: {},
        name: 'Mein Filter', **opts
      )
    end

    it 'persists a folder with the expected attributes and returns it' do
      result = create_from
      expect(result).to be_success

      folder = result.resource
      expect(folder).to be_persisted
      expect(folder).to have_attributes(
        name: 'Mein Filter', user: user, project: project,
        organisation: organisation, target_object_type: 'Ticket'
      )
    end

    it 'persists the converted rules' do
      folder = create_from(filter_params: { 'tag' => %w[bug urgent] }).resource
      rule = folder.smart_folder_rule_groups.sole.smart_folder_rules.sole
      expect(rule).to have_attributes(field: 'tag', operator: 'has_any_of', value: 'bug,urgent')
    end

    it 'honours target_object_type and sort params' do
      folder = create_from(target_object_type: 'Note', sort_column: 'created_at', sort_direction: 'desc').resource
      expect(folder).to have_attributes(target_object_type: 'Note', sort_column: 'created_at', sort_direction: 'desc')
    end

    it 'creates a folder with no groups for empty filters' do
      folder = create_from(filter_params: {}).resource
      expect(folder.smart_folder_rule_groups).to be_empty
    end

    it 'persists one group per assignee for a multi-OR assignee filter' do
      other = create(:user, organisation: organisation)
      folder = create_from(filter_params: { 'assignee' => [user.id.to_s, other.id.to_s] }).resource
      expect(folder.smart_folder_rule_groups.count).to eq(2)
    end

    it 'fails without persisting when the folder is invalid (blank name)' do
      expect do
        result = described_class.call(
          project: project, current_user: user,
          filter_params: { 'tag' => ['bug'] }, operator_params: {}, name: ''
        )
        expect(result).not_to be_success
        expect(result.errors).to be_present
      end.not_to change(SmartFolder, :count)
    end
  end

  describe 'update (smart_folder: given)' do
    let(:folder) do
      f = create(:smart_folder, user: user, organisation: organisation, project: project,
                                name: 'Bestand', target_object_type: 'Ticket')
      group = create(:smart_folder_rule_group, smart_folder: f, position: 1)
      create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'alt', position: 1)
      f
    end

    def update_with(filter_params)
      described_class.call(
        smart_folder: folder, project: project, current_user: user,
        filter_params: filter_params, operator_params: {}, name: folder.name
      )
    end

    it 'replaces the rule tree with the new filters' do
      result = update_with('tag' => %w[bug])
      expect(result).to be_success

      rule = folder.reload.smart_folder_rule_groups.sole.smart_folder_rules.sole
      expect(rule).to have_attributes(field: 'tag', operator: 'has_any_of', value: 'bug')
    end

    it 'keeps the same folder (no new record) and its attributes' do
      folder # create the existing folder before measuring
      expect { update_with('tag' => %w[bug]) }.not_to change(SmartFolder, :count)
      expect(folder.reload).to have_attributes(name: 'Bestand', target_object_type: 'Ticket')
    end

    it 'clears rules when the new filters are empty' do
      update_with({})
      expect(folder.reload.smart_folder_rule_groups).to be_empty
    end

    # The update path destroys the old rule tree before rebuilding it. Both must
    # share ONE transaction so a rebuild failure rolls the destroy back — otherwise
    # a failed save silently wipes the user's existing rules. This pins that
    # data-loss guarantee; without the single transaction it turns red.
    it 'rolls back the destroy_all and keeps the old rules when the rebuild fails' do
      folder # materialise the existing folder + its 'alt' rule first
      allow(SmartFolderRuleFactory).to receive(:build)
        .and_raise(ActiveRecord::RecordInvalid.new(SmartFolderRule.new))

      result = update_with('tag' => %w[bug])

      expect(result).not_to be_success
      surviving = folder.reload.smart_folder_rule_groups.sole.smart_folder_rules.sole
      expect(surviving).to have_attributes(field: 'title', value: 'alt')
    end
  end
end
