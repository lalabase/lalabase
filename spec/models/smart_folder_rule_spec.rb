# frozen_string_literal: true

# == Schema Information
#
# Table name: smart_folder_rules
#
#  id                         :uuid             not null, primary key
#  config                     :jsonb
#  display_value              :text
#  field                      :string           not null
#  operator                   :string           not null
#  position                   :integer          default(1), not null
#  value                      :text
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  smart_folder_rule_group_id :uuid             not null
#
# Indexes
#
#  idx_on_smart_folder_rule_group_id_position_5c8bc7ff32   (smart_folder_rule_group_id,position)
#  index_smart_folder_rules_on_config                      (config) USING gin
#  index_smart_folder_rules_on_field_and_operator          (field,operator)
#  index_smart_folder_rules_on_smart_folder_rule_group_id  (smart_folder_rule_group_id)
#
# Foreign Keys
#
#  fk_rails_...  (smart_folder_rule_group_id => smart_folder_rule_groups.id)
#
require 'rails_helper'

RSpec.describe SmartFolderRule, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:smart_folder) { create(:smart_folder, organisation: organisation, user: user, project: project, target_object_type: 'Ticket') }
  let(:smart_folder_rule_group) { create(:smart_folder_rule_group, smart_folder: smart_folder) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'field_config' do
    it 'uses ActionTextFilter for content field' do
      config = SmartFolderRule.field_config['content']
      expect(config[:filter_class]).to eq('ActionTextFilter')
    end

    it 'should not reference non-existent content column for Ticket' do
      # Tickets use ActionText rich_text_content, not a content column
      expect(Ticket.column_names).not_to include('content')
    end
  end

  describe '.field_config_with_custom_attributes access scoping' do
    let(:other_project) { create(:project, organisation: organisation) }
    let!(:own_attr) { create(:ticket_attribute_definition, project: project, name: 'ownfield', field_type: 'text') }
    let!(:foreign_attr) { create(:ticket_attribute_definition, project: other_project, name: 'foreignfield', field_type: 'text') }

    it 'restricts custom attributes to the given accessible_project_ids' do
      config = SmartFolderRule.field_config_with_custom_attributes(
        organisation, nil, accessible_project_ids: [project.id]
      )

      expect(config).to have_key('custom_ownfield')
      expect(config).not_to have_key('custom_foreignfield')
    end

    it 'includes custom attributes from ALL org projects when accessible_project_ids is nil' do
      # Backwards-compatible path: without the scoping argument the method behaves as before.
      # Catches a mutation that turns `unless accessible_project_ids.nil?` into "always filter".
      config = SmartFolderRule.field_config_with_custom_attributes(organisation, nil)

      expect(config).to have_key('custom_ownfield')
      expect(config).to have_key('custom_foreignfield')
    end

    it 'exposes NO custom attributes when accessible_project_ids is an empty array' do
      # Distinguishes an empty array (no project access) from nil (no scoping) —
      # a user without accessible projects must not see foreign field names.
      config = SmartFolderRule.field_config_with_custom_attributes(
        organisation, nil, accessible_project_ids: []
      )

      expect(config).not_to have_key('custom_ownfield')
      expect(config).not_to have_key('custom_foreignfield')
      expect(config).to have_key('content') # static fields are retained
    end
  end

  describe '.field_config_with_custom_attributes — date fields (Fälligkeit)' do
    let!(:deadline_def) do
      create(:ticket_attribute_definition, project: project, name: 'due_date', field_type: 'date',
                                           labels: { 'de' => 'Fälligkeit', 'en' => 'Due date' }, options: { 'deadline' => true })
    end
    let!(:plain_date_def) do
      create(:ticket_attribute_definition, project: project, name: 'review_on', field_type: 'date',
                                           labels: { 'de' => 'Review', 'en' => 'Review' })
    end

    let(:config) { SmartFolderRule.field_config_with_custom_attributes(organisation, project) }

    it 'routes date custom attributes to the CustomAttributeDateFilter (so before/after/between work)' do
      expect(config['custom_due_date'][:filter_class]).to eq('CustomAttributeDateFilter')
      expect(config['custom_review_on'][:filter_class]).to eq('CustomAttributeDateFilter')
    end

    it 'offers EVERY canonical relative deadline operator ONLY on the marked deadline field' do
      # Iterate the constant (not a hardcoded list) so adding/removing a preset, or a partial append
      # like `operators += DEADLINE_RELATIVE_OPERATORS.first(2)`, turns this red.
      Ticket::DUE_DATE_PRESET_KEYS.each do |preset|
        expect(config['custom_due_date'][:operators]).to include(preset)
        expect(config['custom_review_on'][:operators]).not_to include(preset)
      end
    end

    it 'offers the (now working) absolute date operators on any date field' do
      expect(config['custom_review_on'][:operators]).to include('before', 'after', 'between', 'equals', 'is_empty')
    end

    # The date presets of the bar (SmartFolders::DatePresets) are the valueless operators of
    # the two built-in date fields, and of no custom date field. Iterate the constant.
    it 'offers EVERY date preset on created_at and updated_at, valueless, and on no custom date field' do
      SmartFolders::DatePresets::KEYS.each do |preset|
        expect(config['created_at'][:operators]).to include(preset)
        expect(config['updated_at'][:operators]).to include(preset)
        expect(config['custom_review_on'][:operators]).not_to include(preset)
        expect(SmartFolderRule.optional_value_operators).to include(preset)
      end
    end

    it 'accepts a preset rule without a value and still rejects a between rule without one' do
      folder = create(:smart_folder, organisation: organisation, user: user, project: project, target_object_type: 'Ticket')
      group = create(:smart_folder_rule_group, smart_folder: folder)

      expect(build(:smart_folder_rule, smart_folder_rule_group: group, field: 'created_at', operator: 'this_week', value: nil)).to be_valid
      expect(build(:smart_folder_rule, smart_folder_rule_group: group, field: 'created_at', operator: 'between', value: nil)).not_to be_valid
    end
  end

  describe 'content field search for tickets' do
    let(:ticket) { create(:ticket, project: project, title: 'Test Ticket') }

    before do
      ticket.content = 'This is the ticket content'
      ticket.save!
    end

    it 'should not attempt to search in tickets.content column' do
      rule = build(:smart_folder_rule,
                   smart_folder_rule_group: smart_folder_rule_group,
                   field: 'content',
                   operator: 'contains',
                   value: 'ticket content')

      # The rule should be valid
      expect(rule).to be_valid

      # But when applied, it should not try to search in a non-existent column
      service = SmartFolderService.new(smart_folder, user)

      # This should not raise an error about tickets.content column
      expect { service.fetch_results }.not_to raise_error
    end
  end
end
