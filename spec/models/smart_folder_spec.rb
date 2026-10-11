# frozen_string_literal: true

# == Schema Information
#
# Table name: smart_folders
#
#  id                  :uuid             not null, primary key
#  color_code          :integer
#  description         :text
#  display_columns     :jsonb
#  is_public           :boolean          default(FALSE)
#  name                :string           not null
#  position            :integer
#  public_access_level :integer          default(0)
#  sort_by             :integer          default(0)
#  sort_column         :string
#  sort_direction      :string
#  target_object_type  :string           default("Note")
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  organisation_id     :uuid             not null
#  project_id          :uuid
#  user_id             :uuid             not null
#
# Indexes
#
#  index_smart_folders_on_organisation_id                         (organisation_id)
#  index_smart_folders_on_organisation_id_and_is_public           (organisation_id,is_public)
#  index_smart_folders_on_organisation_id_and_project_id          (organisation_id,project_id)
#  index_smart_folders_on_organisation_id_and_target_object_type  (organisation_id,target_object_type)
#  index_smart_folders_on_organisation_id_and_user_id             (organisation_id,user_id)
#  index_smart_folders_on_project_id                              (project_id)
#  index_smart_folders_on_user_id                                 (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe SmartFolder, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:smart_folder) do
    create(:smart_folder, user: user, organisation: organisation, project: project)
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ==========================================================================
  # Associations
  # ==========================================================================

  describe 'associations' do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:organisation).without_validating_presence }
    it { is_expected.to have_many(:smart_folder_rule_groups).dependent(:destroy).inverse_of(:smart_folder) }
    it { is_expected.to have_many(:smart_folder_rules).through(:smart_folder_rule_groups) }
    it { is_expected.to have_many(:smart_folder_shares).dependent(:destroy).inverse_of(:smart_folder) }
    it { is_expected.to have_many(:shared_users).through(:smart_folder_shares).source(:user) }

    it 'orders rule groups by position ascending' do
      group_b = create(:smart_folder_rule_group, smart_folder: smart_folder, position: 2)
      group_a = create(:smart_folder_rule_group, smart_folder: smart_folder, position: 1)

      expect(smart_folder.smart_folder_rule_groups.reload).to eq([group_a, group_b])
    end

    it 'destroys rule groups when destroyed' do
      create(:smart_folder_rule_group, smart_folder: smart_folder)

      expect { smart_folder.destroy }.to change(SmartFolderRuleGroup, :count).by(-1)
    end

    it 'destroys shares when destroyed' do
      other_user = create(:user, organisation: organisation)
      create(:smart_folder_share, smart_folder: smart_folder, user: other_user)

      expect { smart_folder.destroy }.to change(SmartFolderShare, :count).by(-1)
    end
  end

  # ==========================================================================
  # Constants
  # ==========================================================================

  describe 'constants' do
    describe 'SUPPORTED_OBJECT_TYPES' do
      it 'includes all expected object types' do
        expect(described_class::SUPPORTED_OBJECT_TYPES.keys).to contain_exactly(
          'Note', 'Ticket', 'Document', 'TimeSession', 'Meeting', 'All'
        )
      end

      it 'is frozen' do
        expect(described_class::SUPPORTED_OBJECT_TYPES).to be_frozen
      end
    end

    describe 'VALID_SORT_COLUMNS' do
      it 'includes expected columns' do
        expect(described_class::VALID_SORT_COLUMNS).to contain_exactly(
          'updated_at', 'created_at', 'title', 'number', 'occurred_at', 'duration_minutes'
        )
      end

      it 'is frozen' do
        expect(described_class::VALID_SORT_COLUMNS).to be_frozen
      end
    end
  end

  # ==========================================================================
  # Validations
  # ==========================================================================

  describe 'validations' do
    describe 'project' do
      let(:other_organisation) { create(:organisation) }
      let(:foreign_project) { ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) } }

      it 'rejects a project of another organisation' do
        folder = build(:smart_folder, user: user, organisation: organisation, project_id: foreign_project.id)
        expect(folder).not_to be_valid
        expect(folder.errors[:project_id]).to be_present
      end

      it 'rejects moving an existing folder into a project of another organisation' do
        smart_folder.project_id = foreign_project.id
        expect(smart_folder).not_to be_valid
      end

      it 'accepts a project of its own organisation and no project at all' do
        expect(build(:smart_folder, user: user, organisation: organisation, project: project)).to be_valid
        expect(build(:smart_folder, user: user, organisation: organisation, project: nil)).to be_valid
      end
    end

    describe 'rule tree bounds (expert editor)' do
      def groups_attributes(count)
        Array.new(count) do |index|
          { position: index + 1,
            smart_folder_rules_attributes: [{ field: 'title', operator: 'contains', value: "v#{index}", position: 1 }] }
        end
      end

      it 'refuses more rule groups than a view may hold' do
        smart_folder.smart_folder_rule_groups_attributes = groups_attributes(SmartFolder::MAX_RULE_GROUPS + 1)
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:base]).to include(
          I18n.t('activerecord.errors.models.smart_folder.too_many_rule_groups', count: SmartFolder::MAX_RULE_GROUPS)
        )
      end

      it 'counts the stored rules of a group it adds to' do
        group = smart_folder.smart_folder_rule_groups.create!(position: 1)
        SmartFolder::MAX_RULES_PER_GROUP.times do |index|
          group.smart_folder_rules.create!(field: 'title', operator: 'contains', value: "v#{index}", position: index + 1)
        end
        folder = SmartFolder.find(smart_folder.id)
        folder.smart_folder_rule_groups_attributes = [
          { id: group.id, smart_folder_rules_attributes: [{ field: 'title', operator: 'contains', value: 'one more', position: 99 }] }
        ]
        expect(folder).not_to be_valid
        expect(folder.errors[:base]).to include(
          I18n.t('activerecord.errors.models.smart_folder.too_many_rules', count: SmartFolder::MAX_RULES_PER_GROUP)
        )
      end

      it 'accepts a tree at the bounds' do
        smart_folder.smart_folder_rule_groups_attributes = groups_attributes(SmartFolder::MAX_RULE_GROUPS)
        expect(smart_folder).to be_valid
      end
    end

    describe 'name' do
      it { is_expected.to validate_presence_of(:name) }

      it 'is invalid without a name' do
        smart_folder.name = nil
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:name]).to be_present
      end

      it 'is invalid with blank name' do
        smart_folder.name = ''
        expect(smart_folder).not_to be_valid
      end
    end

    describe 'user' do
      it { is_expected.to validate_presence_of(:user) }
    end

    describe 'target_object_type' do
      it { is_expected.to validate_presence_of(:target_object_type) }

      described_class::SUPPORTED_OBJECT_TYPES.each_key do |type|
        it "accepts '#{type}'" do
          smart_folder.target_object_type = type
          smart_folder.valid?
          expect(smart_folder.errors[:target_object_type]).to be_empty
        end
      end

      it 'rejects invalid object type' do
        smart_folder.target_object_type = 'InvalidType'
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:target_object_type]).to be_present
      end

      it 'rejects nil object type' do
        smart_folder.target_object_type = nil
        expect(smart_folder).not_to be_valid
      end
    end

    describe 'sort_column' do
      described_class::VALID_SORT_COLUMNS.each do |col|
        it "accepts '#{col}'" do
          smart_folder.sort_column = col
          smart_folder.valid?
          expect(smart_folder.errors[:sort_column]).to be_empty
        end
      end

      it 'allows nil' do
        smart_folder.sort_column = nil
        smart_folder.valid?
        expect(smart_folder.errors[:sort_column]).to be_empty
      end

      it 'rejects invalid column' do
        smart_folder.sort_column = 'invalid_column'
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:sort_column]).to be_present
      end
    end

    describe 'sort_direction' do
      %w[asc desc].each do |dir|
        it "accepts '#{dir}'" do
          smart_folder.sort_direction = dir
          smart_folder.valid?
          expect(smart_folder.errors[:sort_direction]).to be_empty
        end
      end

      it 'allows nil' do
        smart_folder.sort_direction = nil
        smart_folder.valid?
        expect(smart_folder.errors[:sort_direction]).to be_empty
      end

      it 'rejects invalid direction' do
        smart_folder.sort_direction = 'sideways'
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:sort_direction]).to be_present
      end
    end

    describe 'validate_display_columns_structure' do
      it 'skips validation when display_columns is nil' do
        smart_folder.display_columns = nil
        expect(smart_folder).to be_valid
      end

      it 'skips validation when display_columns is empty hash' do
        smart_folder.display_columns = {}
        expect(smart_folder).to be_valid
      end

      it 'rejects non-Hash display_columns (string)' do
        smart_folder.display_columns = 'not a hash'
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:display_columns]).to be_present
      end

      it 'rejects non-Hash display_columns (array)' do
        smart_folder.display_columns = ['column1']
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:display_columns]).to be_present
      end

      it 'rejects non-Hash display_columns (integer)' do
        smart_folder.display_columns = 42
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:display_columns]).to be_present
      end

      it 'rejects invalid keys' do
        smart_folder.display_columns = { 'invalid_key' => 'value', 'another_bad' => 'val' }
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:display_columns]).to be_present
      end

      it 'accepts valid keys only' do
        smart_folder.display_columns = {
          'table_columns' => %w[col1 col2],
          'list_columns' => { 'cells' => [] },
          'header_columns' => %w[h1 h2]
        }
        expect(smart_folder).to be_valid
      end

      it 'rejects table_columns that is not an array' do
        smart_folder.display_columns = { 'table_columns' => 'not_array' }
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:display_columns]).to be_present
      end

      it 'rejects header_columns that is not an array' do
        smart_folder.display_columns = { 'header_columns' => { 'wrong' => 'type' } }
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:display_columns]).to be_present
      end

      it 'rejects list_columns that is not a hash' do
        smart_folder.display_columns = { 'list_columns' => 'not_hash' }
        expect(smart_folder).not_to be_valid
        expect(smart_folder.errors[:display_columns]).to be_present
      end

      it 'accepts valid table_columns array' do
        smart_folder.display_columns = { 'table_columns' => %w[title status] }
        expect(smart_folder).to be_valid
      end

      it 'accepts valid list_columns hash' do
        smart_folder.display_columns = { 'list_columns' => { 'cells' => %w[a b] } }
        expect(smart_folder).to be_valid
      end

      it 'accepts nil values for sub-keys (not present)' do
        smart_folder.display_columns = { 'table_columns' => nil }
        expect(smart_folder).to be_valid
      end

      it 'allows mix of valid keys with some nil' do
        smart_folder.display_columns = { 'table_columns' => %w[col1], 'header_columns' => nil }
        expect(smart_folder).to be_valid
      end
    end
  end

  # ==========================================================================
  # Nested attributes
  # ==========================================================================

  describe 'nested attributes for smart_folder_rule_groups' do
    it 'accepts nested attributes with allow_destroy' do
      folder = create(:smart_folder, user: user, organisation: organisation, project: project)
      group = create(:smart_folder_rule_group, smart_folder: folder)

      folder.update(smart_folder_rule_groups_attributes: { '0' => { id: group.id, '_destroy' => '1' } })
      expect(SmartFolderRuleGroup.exists?(group.id)).to be false
    end

    describe 'reject_empty_destroyed_group?' do
      it 'rejects destroyed group with no rules' do
        attrs = { '_destroy' => '1', 'smart_folder_rules_attributes' => {} }
        expect(smart_folder.send(:reject_empty_destroyed_group?, attrs)).to be true
      end

      it 'rejects destroyed group with blank rules' do
        attrs = { '_destroy' => '1' }
        expect(smart_folder.send(:reject_empty_destroyed_group?, attrs)).to be true
      end

      it 'rejects destroyed group when all rules are also destroyed' do
        attrs = {
          '_destroy' => '1',
          'smart_folder_rules_attributes' => {
            '0' => { '_destroy' => '1' },
            '1' => { '_destroy' => '1' }
          }
        }
        expect(smart_folder.send(:reject_empty_destroyed_group?, attrs)).to be true
      end

      it 'does not reject destroyed group with surviving rules' do
        attrs = {
          '_destroy' => '1',
          'smart_folder_rules_attributes' => {
            '0' => { '_destroy' => '1' },
            '1' => { '_destroy' => '0', 'field' => 'title' }
          }
        }
        expect(smart_folder.send(:reject_empty_destroyed_group?, attrs)).to be false
      end

      it 'does not reject non-destroyed groups' do
        attrs = { '_destroy' => '0', 'smart_folder_rules_attributes' => {} }
        expect(smart_folder.send(:reject_empty_destroyed_group?, attrs)).to be false
      end

      it 'does not reject groups without _destroy flag' do
        attrs = { 'smart_folder_rules_attributes' => {} }
        expect(smart_folder.send(:reject_empty_destroyed_group?, attrs)).to be false
      end
    end
  end

  # ==========================================================================
  # sort_by_name
  # ==========================================================================

  describe '#sort_by_name' do
    {
      0 => 'updated_desc',
      1 => 'updated_asc',
      2 => 'created_desc',
      3 => 'created_asc',
      4 => 'title_asc',
      5 => 'title_desc'
    }.each do |value, expected|
      it "returns '#{expected}' for sort_by #{value}" do
        smart_folder.sort_by = value
        expect(smart_folder.sort_by_name).to eq(expected)
      end
    end

    it "defaults to 'updated_desc' for unknown value" do
      smart_folder.sort_by = 99
      expect(smart_folder.sort_by_name).to eq('updated_desc')
    end

    it "defaults to 'updated_desc' for nil" do
      smart_folder.sort_by = nil
      expect(smart_folder.sort_by_name).to eq('updated_desc')
    end
  end

  # ==========================================================================
  # public_access_level_name
  # ==========================================================================

  describe '#public_access_level_name' do
    {
      0 => 'view_only',
      1 => 'use_rules',
      2 => 'copy'
    }.each do |value, expected|
      it "returns '#{expected}' for public_access_level #{value}" do
        smart_folder.public_access_level = value
        expect(smart_folder.public_access_level_name).to eq(expected)
      end
    end

    it "defaults to 'view_only' for unknown value" do
      smart_folder.public_access_level = 99
      expect(smart_folder.public_access_level_name).to eq('view_only')
    end

    it "defaults to 'view_only' for nil" do
      smart_folder.public_access_level = nil
      expect(smart_folder.public_access_level_name).to eq('view_only')
    end
  end

  # ==========================================================================
  # public_copy?
  # ==========================================================================

  describe '#public_copy?' do
    it 'returns true when public_access_level is 2' do
      smart_folder.public_access_level = 2
      expect(smart_folder.public_copy?).to be true
    end

    it 'returns false when public_access_level is 0' do
      smart_folder.public_access_level = 0
      expect(smart_folder.public_copy?).to be false
    end

    it 'returns false when public_access_level is 1' do
      smart_folder.public_access_level = 1
      expect(smart_folder.public_copy?).to be false
    end

    it 'returns false when public_access_level is nil' do
      smart_folder.public_access_level = nil
      expect(smart_folder.public_copy?).to be false
    end
  end

  # ==========================================================================
  # Display column methods
  # ==========================================================================

  describe '#ordered_columns (doc/spaltenwahl_plan.md, D1 and D6)' do
    it 'is nil when the folder has no columns of its own and follows the base view' do
      smart_folder.display_columns = nil
      expect(smart_folder.ordered_columns).to be_nil
      smart_folder.display_columns = {}
      expect(smart_folder.ordered_columns).to be_nil
    end

    it 'is the table columns, required first' do
      smart_folder.display_columns = { 'table_columns' => %w[created_at title] }
      expect(smart_folder.ordered_columns).to eq(%w[number title created_at])
    end

    it 'folds the legacy second list in behind the table columns' do
      smart_folder.display_columns = { 'table_columns' => %w[number title assignees],
                                       'list_columns' => { 'cells' => %w[tags], 'metadata' => %w[created_at assignees] } }
      expect(smart_folder.ordered_columns).to eq(%w[number title assignees tags created_at])
    end

    it 'ignores a second list of an unexpected shape' do
      smart_folder.display_columns = { 'table_columns' => %w[tags], 'list_columns' => 'invalid' }
      expect(smart_folder.ordered_columns).to eq(%w[number title tags])
    end
  end

  describe '#ordered_columns=' do
    it 'writes one list and drops the legacy second list' do
      smart_folder.display_columns = { 'table_columns' => %w[number title assignees], 'list_columns' => { 'cells' => %w[tags] } }
      smart_folder.ordered_columns = %w[created_at title]
      expect(smart_folder.display_columns).to eq({ 'table_columns' => %w[number title created_at] })
      expect(smart_folder.ordered_columns).to eq(%w[number title created_at])
    end
  end

  describe '#custom_columns?' do
    it 'is true with a hash that holds anything' do
      smart_folder.display_columns = { 'table_columns' => %w[col1] }
      expect(smart_folder.custom_columns?).to be true
    end

    it 'is false for nil, an empty hash and a non-hash' do
      smart_folder.display_columns = nil
      expect(smart_folder.custom_columns?).to be false
      smart_folder.display_columns = {}
      expect(smart_folder.custom_columns?).to be false
      smart_folder.display_columns = 'string'
      expect(smart_folder.custom_columns?).to be false
    end
  end

  # ==========================================================================
  # Sort methods
  # ==========================================================================

  describe '#effective_sort_column' do
    it 'returns sort_column when present' do
      smart_folder.sort_column = 'title'
      expect(smart_folder.effective_sort_column).to eq('title')
    end

    it 'falls back to sort_by_to_column when sort_column is nil' do
      smart_folder.sort_column = nil
      smart_folder.sort_by = 2  # created_desc → 'created_at'
      expect(smart_folder.effective_sort_column).to eq('created_at')
    end

    it 'falls back to sort_by_to_column when sort_column is blank' do
      smart_folder.sort_column = ''
      smart_folder.sort_by = 4  # title_asc → 'title'
      expect(smart_folder.effective_sort_column).to eq('title')
    end

    context 'sort_by_to_column fallback values' do
      { 0 => 'updated_at', 1 => 'updated_at',
        2 => 'created_at', 3 => 'created_at',
        4 => 'title', 5 => 'title' }.each do |sort_by_val, expected_col|
        it "returns '#{expected_col}' for sort_by #{sort_by_val}" do
          smart_folder.sort_column = nil
          smart_folder.sort_by = sort_by_val
          expect(smart_folder.effective_sort_column).to eq(expected_col)
        end
      end

      it "defaults to 'updated_at' for unknown sort_by" do
        smart_folder.sort_column = nil
        smart_folder.sort_by = 99
        expect(smart_folder.effective_sort_column).to eq('updated_at')
      end
    end
  end

  describe '#effective_sort_direction' do
    it 'returns sort_direction when present' do
      smart_folder.sort_direction = 'asc'
      expect(smart_folder.effective_sort_direction).to eq('asc')
    end

    it 'falls back to sort_by_to_direction when sort_direction is nil' do
      smart_folder.sort_direction = nil
      smart_folder.sort_by = 1  # updated_asc → 'asc'
      expect(smart_folder.effective_sort_direction).to eq('asc')
    end

    it 'falls back to sort_by_to_direction when sort_direction is blank' do
      smart_folder.sort_direction = ''
      smart_folder.sort_by = 0  # updated_desc → 'desc'
      expect(smart_folder.effective_sort_direction).to eq('desc')
    end

    context 'sort_by_to_direction fallback values' do
      { 1 => 'asc', 3 => 'asc', 4 => 'asc',
        0 => 'desc', 2 => 'desc', 5 => 'desc' }.each do |sort_by_val, expected_dir|
        it "returns '#{expected_dir}' for sort_by #{sort_by_val}" do
          smart_folder.sort_direction = nil
          smart_folder.sort_by = sort_by_val
          expect(smart_folder.effective_sort_direction).to eq(expected_dir)
        end
      end

      it "defaults to 'desc' for unknown sort_by" do
        smart_folder.sort_direction = nil
        smart_folder.sort_by = 99
        expect(smart_folder.effective_sort_direction).to eq('desc')
      end
    end
  end

  # ==========================================================================
  # results
  # ==========================================================================

  describe '#results' do
    let(:expected_result) { { items: [], total: 0, page: 1, per_page: 25 } }

    it 'delegates to SmartFolderService with self and user' do
      service = instance_double(SmartFolderService, fetch_results: expected_result)
      allow(SmartFolderService).to receive(:new).with(smart_folder, user).and_return(service)

      result = smart_folder.results
      expect(result).to eq(expected_result)
      expect(SmartFolderService).to have_received(:new).with(smart_folder, user)
    end

    it 'passes current_user_context when provided' do
      other_user = create(:user, organisation: organisation)
      service = instance_double(SmartFolderService, fetch_results: expected_result)
      allow(SmartFolderService).to receive(:new).with(smart_folder, other_user).and_return(service)

      result = smart_folder.results(other_user)
      expect(result).to eq(expected_result)
      expect(SmartFolderService).to have_received(:new).with(smart_folder, other_user)
    end

    it 'falls back to folder owner when current_user_context is nil' do
      service = instance_double(SmartFolderService, fetch_results: expected_result)
      allow(SmartFolderService).to receive(:new).with(smart_folder, user).and_return(service)

      smart_folder.results(nil)
      expect(SmartFolderService).to have_received(:new).with(smart_folder, user)
    end
  end

  # ==========================================================================
  # accessible_by?
  # ==========================================================================

  describe '#accessible_by?' do
    it 'returns false for nil user' do
      expect(smart_folder.accessible_by?(nil)).to be false
    end

    it 'returns true for owner' do
      expect(smart_folder.accessible_by?(user)).to be true
    end

    it 'returns true for public folder with non-owner' do
      smart_folder.update!(is_public: true)
      other_user = create(:user, organisation: organisation)
      expect(smart_folder.accessible_by?(other_user)).to be true
    end

    it 'returns true for shared user' do
      other_user = create(:user, organisation: organisation)
      create(:smart_folder_share, smart_folder: smart_folder, user: other_user)
      expect(smart_folder.accessible_by?(other_user)).to be true
    end

    it 'returns true for organisation admin' do
      admin_user = create(:user, organisation: organisation)
      admin_role = create(:admin_role, organisation: organisation)
      admin_user.memberships.find_by(organisation: organisation).update!(role: admin_role)

      expect(smart_folder.accessible_by?(admin_user)).to be true
    end

    it 'returns false for non-owner, non-shared, non-admin user on private folder' do
      other_user = create(:user, organisation: organisation)
      expect(smart_folder.accessible_by?(other_user)).to be false
    end
  end

  # ==========================================================================
  # editable_by?
  # ==========================================================================

  describe '#editable_by?' do
    it 'returns false for nil user' do
      expect(smart_folder.editable_by?(nil)).to be false
    end

    it 'returns true for owner' do
      expect(smart_folder.editable_by?(user)).to be true
    end

    it 'returns true for shared user with can_edit' do
      other_user = create(:user, organisation: organisation)
      create(:smart_folder_share, smart_folder: smart_folder, user: other_user, can_edit: true)
      expect(smart_folder.editable_by?(other_user)).to be true
    end

    it 'returns false for shared user without can_edit' do
      other_user = create(:user, organisation: organisation)
      create(:smart_folder_share, smart_folder: smart_folder, user: other_user, can_edit: false)
      expect(smart_folder.editable_by?(other_user)).to be false
    end

    it 'returns true for organisation admin' do
      admin_user = create(:user, organisation: organisation)
      admin_role = create(:admin_role, organisation: organisation)
      admin_user.memberships.find_by(organisation: organisation).update!(role: admin_role)

      expect(smart_folder.editable_by?(admin_user)).to be true
    end

    it 'returns false for non-owner, non-shared user' do
      other_user = create(:user, organisation: organisation)
      expect(smart_folder.editable_by?(other_user)).to be false
    end
  end

  # ==========================================================================
  # share_with
  # ==========================================================================

  describe '#share_with' do
    let(:other_user) { create(:user, organisation: organisation) }

    it 'returns false for nil user' do
      expect(smart_folder.share_with(nil)).to be false
    end

    it 'returns false when sharing with the owner' do
      expect(smart_folder.share_with(user)).to be false
    end

    it 'returns false for user not in the organisation' do
      other_org = create(:organisation)
      outside_user = create(:user, organisation: other_org)
      expect(smart_folder.share_with(outside_user)).to be false
    end

    it 'creates a new share for valid user' do
      expect { smart_folder.share_with(other_user) }
        .to change(SmartFolderShare, :count).by(1)
    end

    it 'returns truthy on successful share' do
      expect(smart_folder.share_with(other_user)).to be_truthy
    end

    it 'sets default can_edit to false' do
      smart_folder.share_with(other_user)
      share = smart_folder.smart_folder_shares.find_by(user: other_user)
      expect(share.can_edit).to be false
    end

    it 'sets default can_share to false' do
      smart_folder.share_with(other_user)
      share = smart_folder.smart_folder_shares.find_by(user: other_user)
      expect(share.can_share).to be false
    end

    it 'accepts can_edit option' do
      smart_folder.share_with(other_user, can_edit: true)
      share = smart_folder.smart_folder_shares.find_by(user: other_user)
      expect(share.can_edit).to be true
    end

    it 'accepts can_share option' do
      smart_folder.share_with(other_user, can_share: true)
      share = smart_folder.smart_folder_shares.find_by(user: other_user)
      expect(share.can_share).to be true
    end

    it 'updates existing share instead of creating duplicate' do
      smart_folder.share_with(other_user, can_edit: false)

      expect { smart_folder.share_with(other_user, can_edit: true) }
        .not_to change(SmartFolderShare, :count)

      share = smart_folder.smart_folder_shares.find_by(user: other_user)
      expect(share.can_edit).to be true
    end

    it 'preserves existing can_edit when not provided in options' do
      smart_folder.share_with(other_user, can_edit: true)
      smart_folder.share_with(other_user, can_share: true)

      share = smart_folder.smart_folder_shares.find_by(user: other_user)
      expect(share.can_edit).to be true
      expect(share.can_share).to be true
    end
  end

  # ==========================================================================
  # unshare_with
  # ==========================================================================

  describe '#unshare_with' do
    let(:other_user) { create(:user, organisation: organisation) }

    it 'returns false for nil user' do
      expect(smart_folder.unshare_with(nil)).to be false
    end

    it 'destroys existing share' do
      create(:smart_folder_share, smart_folder: smart_folder, user: other_user)

      expect { smart_folder.unshare_with(other_user) }
        .to change(SmartFolderShare, :count).by(-1)
    end

    it 'does not raise for user without share' do
      expect { smart_folder.unshare_with(other_user) }.not_to raise_error
    end

    it 'returns empty array when no share exists' do
      result = smart_folder.unshare_with(other_user)
      expect(result).to eq([])
    end
  end

  # ==========================================================================
  # rules_count / groups_count
  # ==========================================================================

  describe '#rules_count' do
    it 'returns 0 when no rules exist' do
      expect(smart_folder.rules_count).to eq(0)
    end

    it 'returns correct count with rules' do
      group = create(:smart_folder_rule_group, smart_folder: smart_folder)
      create_list(:smart_folder_rule, 3, smart_folder_rule_group: group)

      expect(smart_folder.rules_count).to eq(3)
    end

    it 'counts rules across multiple groups' do
      group1 = create(:smart_folder_rule_group, smart_folder: smart_folder, position: 1)
      group2 = create(:smart_folder_rule_group, smart_folder: smart_folder, position: 2)
      create_list(:smart_folder_rule, 2, smart_folder_rule_group: group1)
      create(:smart_folder_rule, smart_folder_rule_group: group2)

      expect(smart_folder.rules_count).to eq(3)
    end
  end

  describe '#groups_count' do
    it 'returns 0 when no groups exist' do
      expect(smart_folder.groups_count).to eq(0)
    end

    it 'returns correct count' do
      create_list(:smart_folder_rule_group, 2, smart_folder: smart_folder)
      expect(smart_folder.groups_count).to eq(2)
    end
  end

  # ==========================================================================
  # Factory & persistence
  # ==========================================================================

  describe 'factory' do
    it 'creates a valid smart folder' do
      expect(smart_folder).to be_valid
      expect(smart_folder).to be_persisted
    end

    it 'can be created without project' do
      folder = create(:smart_folder, user: user, organisation: organisation, project: nil)
      expect(folder).to be_valid
    end
  end

  # ==========================================================================
  # Multi-tenancy
  # ==========================================================================

  describe 'multi-tenancy' do
    it 'is scoped to organisation via acts_as_tenant' do
      other_org = create(:organisation)
      other_user = create(:user, organisation: other_org)

      ActsAsTenant.with_tenant(other_org) do
        create(:smart_folder, user: other_user, organisation: other_org)
      end

      expect(described_class.count).to eq(0) # only current tenant's folders
      smart_folder # create in current tenant
      expect(described_class.count).to eq(1)
    end
  end
end
