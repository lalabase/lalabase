# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolderDissolver do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  def create_smart_folder_with_rules(rules_config, multi_group: false)
    sf = create(:smart_folder,
                user: user,
                organisation: organisation,
                project: project,
                target_object_type: 'Ticket')

    # Precompute shared data to avoid N+1 during individual rule creation
    all_rule_attrs = multi_group ? rules_config.flatten : rules_config

    field_config_data = (SmartFolderRule.field_config_with_custom_attributes(organisation, project) if all_rule_attrs.any? { |r| r[:field]&.start_with?('custom_') })

    user_ids = all_rule_attrs.select { |r| %w[assignee creator].include?(r[:field]) }.filter_map { |r| r[:value] }
    preloaded_refs = if user_ids.any?
                       users = User.where(id: user_ids).index_by { |u| u.id.to_s }
                       { 'User' => users }
                     end

    if multi_group
      # rules_config is an Array of Arrays (one array per group)
      rules_config.each_with_index do |group_rules, g_idx|
        group = create(:smart_folder_rule_group, smart_folder: sf, position: g_idx + 1)
        group_rules.each_with_index do |rule_attrs, r_idx|
          create(:smart_folder_rule,
                 smart_folder_rule_group: group,
                 field: rule_attrs[:field],
                 operator: rule_attrs[:operator],
                 value: rule_attrs[:value],
                 position: r_idx + 1,
                 cached_field_config_data: field_config_data,
                 preloaded_references: preloaded_refs)
        end
      end
    else
      # rules_config is an Array of Hashes (single group)
      group = create(:smart_folder_rule_group, smart_folder: sf, position: 1)
      rules_config.each_with_index do |rule_attrs, idx|
        create(:smart_folder_rule,
               smart_folder_rule_group: group,
               field: rule_attrs[:field],
               operator: rule_attrs[:operator],
               value: rule_attrs[:value],
               position: idx + 1,
               cached_field_config_data: field_config_data,
               preloaded_references: preloaded_refs)
      end
    end

    sf.reload
  end

  describe '#call' do
    context 'with empty SmartFolder' do
      it 'returns dissolvable with empty filters' do
        sf = create(:smart_folder,
                    user: user,
                    organisation: organisation,
                    project: project,
                    target_object_type: 'Ticket')

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({})
        expect(result.ad_hoc_operators).to eq({})
        expect(result.complex_rules).to eq([])
      end
    end

    context 'with assignee equals rule (Meine Aufgaben pattern)' do
      it 'dissolves into assignee filter' do
        sf = create_smart_folder_with_rules([
                                              { field: 'assignee', operator: 'equals', value: user.id }
                                            ])

        result = described_class.new(sf, user).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'assignee' => [user.id.to_s] })
        expect(result.ad_hoc_operators).to eq({})
        expect(result.complex_rules).to be_empty
      end
    end

    context 'with assignee not_equals rule' do
      it 'dissolves with NOT operator' do
        sf = create_smart_folder_with_rules([
                                              { field: 'assignee', operator: 'not_equals', value: user.id }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'assignee' => [user.id.to_s] })
        expect(result.ad_hoc_operators).to eq({ 'assignee' => 'not' })
      end
    end

    context 'with creator rules (seit dem creator-Regel-Feld)' do
      let(:second_user) { create(:user) }

      it 'dissolves creator equals into creator filter' do
        sf = create_smart_folder_with_rules([
                                              { field: 'creator', operator: 'equals', value: user.id }
                                            ])

        result = described_class.new(sf, user).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'creator' => [user.id.to_s] })
        expect(result.ad_hoc_operators).to eq({})
      end

      it 'dissolves creator not_equals with NOT operator' do
        sf = create_smart_folder_with_rules([
                                              { field: 'creator', operator: 'not_equals', value: user.id }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_operators).to eq({ 'creator' => 'not' })
      end

      it 'dissolves the multi-group creator OR pattern with shared base rules' do
        sf = create_smart_folder_with_rules([
                                              [{ field: 'creator', operator: 'equals', value: user.id },
                                               { field: 'tag', operator: 'has', value: 'wichtig' }],
                                              [{ field: 'creator', operator: 'equals', value: second_user.id },
                                               { field: 'tag', operator: 'has', value: 'wichtig' }]
                                            ], multi_group: true)

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters['creator']).to contain_exactly(user.id.to_s, second_user.id.to_s)
        expect(result.ad_hoc_filters['tag']).to eq(['wichtig'])
      end

      it 'dissolves the assignee x creator cross product back to both OR lists' do
        sf = create_smart_folder_with_rules([
                                              [{ field: 'assignee', operator: 'equals', value: user.id },
                                               { field: 'creator', operator: 'equals', value: user.id }],
                                              [{ field: 'assignee', operator: 'equals', value: user.id },
                                               { field: 'creator', operator: 'equals', value: second_user.id }],
                                              [{ field: 'assignee', operator: 'equals', value: second_user.id },
                                               { field: 'creator', operator: 'equals', value: user.id }],
                                              [{ field: 'assignee', operator: 'equals', value: second_user.id },
                                               { field: 'creator', operator: 'equals', value: second_user.id }]
                                            ], multi_group: true)

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters['assignee']).to contain_exactly(user.id.to_s, second_user.id.to_s)
        expect(result.ad_hoc_filters['creator']).to contain_exactly(user.id.to_s, second_user.id.to_s)
      end
    end

    context 'with tag rules' do
      it 'dissolves has_any_of into OR tag filter' do
        sf = create_smart_folder_with_rules([
                                              { field: 'tag', operator: 'has_any_of', value: 'bug,urgent' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'tag' => %w[bug urgent] })
        expect(result.ad_hoc_operators).to eq({})
      end

      it 'dissolves has_all_of into AND tag filter' do
        sf = create_smart_folder_with_rules([
                                              { field: 'tag', operator: 'has_all_of', value: 'bug,urgent' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'tag' => %w[bug urgent] })
        expect(result.ad_hoc_operators).to eq({ 'tag' => 'and' })
      end

      it 'dissolves not_has into NOT tag filter' do
        sf = create_smart_folder_with_rules([
                                              { field: 'tag', operator: 'not_has', value: 'wontfix' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'tag' => ['wontfix'] })
        expect(result.ad_hoc_operators).to eq({ 'tag' => 'not' })
      end

      it 'dissolves single has into tag filter' do
        sf = create_smart_folder_with_rules([
                                              { field: 'tag', operator: 'has', value: 'bug' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'tag' => ['bug'] })
      end
    end

    context 'with date rules' do
      it 'dissolves created_at in_the_last_days 7 to last_7_days preset' do
        sf = create_smart_folder_with_rules([
                                              { field: 'created_at', operator: 'in_the_last_days', value: '7' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'created_at' => ['last_7_days'] })
      end

      it 'dissolves updated_at in_the_last_days 30 to last_30_days preset' do
        sf = create_smart_folder_with_rules([
                                              { field: 'updated_at', operator: 'in_the_last_days', value: '30' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'updated_at' => ['last_30_days'] })
      end

      it 'marks unsupported date values as complex' do
        sf = create_smart_folder_with_rules([
                                              { field: 'created_at', operator: 'in_the_last_days', value: '14' }
                                            ])

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
        expect(result.complex_rules.size).to eq(1)
      end

      it 'marks unsupported date operators as complex' do
        sf = create_smart_folder_with_rules([
                                              { field: 'created_at', operator: 'before', value: '2025-01-01' }
                                            ])

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
        expect(result.complex_rules.size).to eq(1)
      end

      # The preset IS the operator (SmartFolders::DatePresets), read back as itself.
      # Iterate the constant: a preset the rule gains without a way back turns this red.
      SmartFolders::DatePresets::KEYS.each do |preset|
        it "dissolves the preset operator #{preset} to the preset itself" do
          sf = create_smart_folder_with_rules([
                                                { field: 'updated_at', operator: preset, value: nil }
                                              ])

          result = described_class.new(sf).call

          expect(result).to be_dissolvable
          expect(result.ad_hoc_filters).to eq({ 'updated_at' => [preset] })
        end
      end

      it 'marks two presets in ONE group (AND) as complex: the bar cannot say "today and yesterday"' do
        sf = create_smart_folder_with_rules([
                                              { field: 'created_at', operator: 'today', value: nil },
                                              { field: 'created_at', operator: 'yesterday', value: nil }
                                            ])

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
        expect(result.complex_rules.size).to eq(1)
      end
    end

    context 'with deadline preset rules (the bar\'s due_date category)' do
      before do
        create(:ticket_attribute_definition, project: project, name: 'frist', field_type: 'date',
                                             labels: { 'de' => 'Frist', 'en' => 'Deadline' }, options: { 'deadline' => true })
      end

      Ticket::DUE_DATE_PRESET_KEYS.each do |preset|
        it "dissolves custom_frist #{preset} to due_date #{preset}" do
          sf = create_smart_folder_with_rules([
                                                { field: 'custom_frist', operator: preset, value: nil }
                                              ])

          result = described_class.new(sf).call

          expect(result).to be_dissolvable
          expect(result.ad_hoc_filters).to eq({ 'due_date' => [preset] })
        end
      end

      it 'dissolves one deadline preset per group into one OR condition' do
        sf = create_smart_folder_with_rules([
                                              [{ field: 'custom_frist', operator: 'overdue', value: nil }],
                                              [{ field: 'custom_frist', operator: 'due_today', value: nil }]
                                            ], multi_group: true)

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'due_date' => %w[overdue due_today] })
      end
    end

    # The waiting states (doc/ticket_relations_plan.md, revision 4, §9) come back as the bar's
    # flag: "ist" or "ist nicht", whichever way round the rule says it.
    context 'with waiting state rules' do
      {
        [SmartFolders::Operators::IS, 'true'] => nil,
        [SmartFolders::Operators::IS_NOT, 'true'] => 'not',
        [SmartFolders::Operators::IS, 'false'] => 'not',
        [SmartFolders::Operators::IS_NOT, 'false'] => nil
      }.each do |(operator, value), bar_operator|
        %w[waiting blocking].each do |field|
          it "dissolves #{field} #{operator} #{value} to the flag with operator #{bar_operator.inspect}" do
            sf = create_smart_folder_with_rules([{ field: field, operator: operator, value: value }])

            result = described_class.new(sf).call

            expect(result).to be_dissolvable
            expect(result.ad_hoc_filters).to eq({ field => ['true'] })
            expect(result.ad_hoc_operators).to eq(bar_operator ? { field => bar_operator } : {})
          end
        end
      end

      it 'keeps two rules on one state in one group as an expert rule' do
        sf = create_smart_folder_with_rules([
                                              { field: 'waiting', operator: SmartFolders::Operators::IS, value: 'true' },
                                              { field: 'waiting', operator: SmartFolders::Operators::IS_NOT, value: 'true' }
                                            ])

        expect(described_class.new(sf).call).not_to be_dissolvable
      end

      it 'dissolves a state that stands in every group of an OR over assignees' do
        other = create(:user)
        sf = create_smart_folder_with_rules([
                                              [{ field: 'assignee', operator: 'equals', value: user.id.to_s },
                                               { field: 'blocking', operator: SmartFolders::Operators::IS_NOT, value: 'true' }],
                                              [{ field: 'assignee', operator: 'equals', value: other.id.to_s },
                                               { field: 'blocking', operator: SmartFolders::Operators::IS_NOT, value: 'true' }]
                                            ], multi_group: true)

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'assignee' => [user.id.to_s, other.id.to_s], 'blocking' => ['true'] })
        expect(result.ad_hoc_operators).to eq({ 'blocking' => 'not' })
      end
    end

    context 'with custom attribute rules' do
      before do
        create(:ticket_attribute_definition, :select,
               project: project,
               name: 'status',
               options: {
                 'allowed_values' => [
                   { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                   { 'value' => 'in_progress', 'labels' => { 'de' => 'In Bearbeitung', 'en' => 'In Progress' } },
                   { 'value' => 'closed', 'labels' => { 'de' => 'Geschlossen', 'en' => 'Closed' } }
                 ]
               })
        create(:ticket_attribute_definition, :select,
               project: project,
               name: 'priority',
               options: {
                 'allowed_values' => [
                   { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } },
                   { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } },
                   { 'value' => 'urgent', 'labels' => { 'de' => 'Dringend', 'en' => 'Urgent' } }
                 ]
               })
      end

      it 'dissolves custom_* equals into ad-hoc filter' do
        sf = create_smart_folder_with_rules([
                                              { field: 'custom_status', operator: 'equals', value: 'open' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'status' => ['open'] })
        expect(result.ad_hoc_operators).to eq({})
      end

      it 'dissolves custom_* not_equals into NOT filter' do
        sf = create_smart_folder_with_rules([
                                              { field: 'custom_priority', operator: 'not_equals', value: 'low' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'priority' => ['low'] })
        expect(result.ad_hoc_operators).to eq({ 'priority' => 'not' })
      end

      it 'dissolves custom_* in_list into multi-value filter' do
        sf = create_smart_folder_with_rules([
                                              { field: 'custom_status', operator: 'in_list', value: 'open,in_progress' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'status' => %w[open in_progress] })
      end

      it 'marks custom_* contains as complex' do
        create(:ticket_attribute_definition,
               project: project,
               name: 'description_field',
               field_type: 'text')
        sf = create_smart_folder_with_rules([
                                              { field: 'custom_description_field', operator: 'contains', value: 'open' }
                                            ])

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
        expect(result.complex_rules.size).to eq(1)
      end
    end

    context 'with complex fields (non-dissolvable)' do
      it 'marks title rules as complex' do
        sf = create_smart_folder_with_rules([
                                              { field: 'title', operator: 'contains', value: 'deploy' }
                                            ])

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
        expect(result.complex_rules.size).to eq(1)
      end

      it 'marks has_time_sessions rules as complex' do
        sf = create_smart_folder_with_rules([
                                              { field: 'has_time_sessions', operator: 'is', value: 'true' }
                                            ])

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
      end

      it 'marks number rules as complex' do
        sf = create_smart_folder_with_rules([
                                              { field: 'number', operator: 'greater_than', value: '100' }
                                            ])

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
      end
    end

    context 'with mixed dissolvable and complex rules' do
      it 'returns non-dissolvable with complex_rules populated' do
        sf = create_smart_folder_with_rules([
                                              { field: 'assignee', operator: 'equals', value: user.id },
                                              { field: 'has_time_sessions', operator: 'is', value: 'true' }
                                            ])

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'assignee' => [user.id.to_s] })
        expect(result.complex_rules.size).to eq(1)
        expect(result.complex_rules.first.field).to eq('has_time_sessions')
      end
    end

    context 'multi-group: assignee OR pattern' do
      it 'dissolves multiple assignee groups into OR filter' do
        user2 = create(:user)
        sf = create_smart_folder_with_rules([
                                              [{ field: 'assignee', operator: 'equals', value: user.id }],
                                              [{ field: 'assignee', operator: 'equals', value: user2.id }]
                                            ], multi_group: true)

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters['assignee']).to contain_exactly(user.id.to_s, user2.id.to_s)
        expect(result.ad_hoc_operators).to eq({})
      end

      it 'dissolves assignee OR with shared base rules' do
        user2 = create(:user)
        sf = create_smart_folder_with_rules([
                                              [
                                                { field: 'assignee', operator: 'equals', value: user.id },
                                                { field: 'tag', operator: 'has_any_of', value: 'bug,urgent' }
                                              ],
                                              [
                                                { field: 'assignee', operator: 'equals', value: user2.id },
                                                { field: 'tag', operator: 'has_any_of', value: 'bug,urgent' }
                                              ]
                                            ], multi_group: true)

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters['assignee']).to contain_exactly(user.id.to_s, user2.id.to_s)
        expect(result.ad_hoc_filters['tag']).to eq(%w[bug urgent])
      end
    end

    context 'multi-group: same-field OR pattern (Hohe Prio)' do
      it 'dissolves same custom field across groups' do
        create(:ticket_attribute_definition, :select,
               project: project,
               name: 'priority',
               options: {
                 'allowed_values' => [
                   { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } },
                   { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } },
                   { 'value' => 'urgent', 'labels' => { 'de' => 'Dringend', 'en' => 'Urgent' } }
                 ]
               })
        sf = create_smart_folder_with_rules([
                                              [{ field: 'custom_priority', operator: 'equals', value: 'high' }],
                                              [{ field: 'custom_priority', operator: 'equals', value: 'urgent' }]
                                            ], multi_group: true)

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters['priority']).to contain_exactly('high', 'urgent')
      end
    end

    context 'multi-group: non-dissolvable pattern' do
      it 'marks unrecognizable multi-group as complex' do
        sf = create_smart_folder_with_rules([
                                              [{ field: 'title', operator: 'contains', value: 'bug' }],
                                              [{ field: 'title', operator: 'contains', value: 'error' }]
                                            ], multi_group: true)

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
        expect(result.complex_rules.size).to eq(2)
      end
    end

    # What AdHocToSmartFolderService#build_rules_for_groups writes for two presets
    # of one category: one group per preset, base rules duplicated.
    context 'multi-group: date presets OR pattern' do
      it 'dissolves one preset per group into one OR condition' do
        sf = create_smart_folder_with_rules([
                                              [{ field: 'created_at', operator: 'today', value: nil }],
                                              [{ field: 'created_at', operator: 'yesterday', value: nil }]
                                            ], multi_group: true)

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'created_at' => %w[today yesterday] })
        expect(result.ad_hoc_operators).to eq({})
      end

      it 'dissolves the cross product of presets and assignees with a shared base rule' do
        user2 = create(:user)
        groups = %w[today yesterday].product([user.id, user2.id]).map do |preset, uid|
          [
            { field: 'created_at', operator: preset, value: nil },
            { field: 'assignee', operator: 'equals', value: uid },
            { field: 'tag', operator: 'has_any_of', value: 'bug' }
          ]
        end
        sf = create_smart_folder_with_rules(groups, multi_group: true)

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters['created_at']).to eq(%w[today yesterday])
        expect(result.ad_hoc_filters['assignee']).to contain_exactly(user.id.to_s, user2.id.to_s)
        expect(result.ad_hoc_filters['tag']).to eq(['bug'])
      end
    end

    context 'default SmartFolder types' do
      it 'dissolves "Meine Aufgaben" (assignee equals current_user)' do
        sf = create_smart_folder_with_rules([
                                              { field: 'assignee', operator: 'equals', value: user.id }
                                            ])

        result = described_class.new(sf, user).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to have_key('assignee')
      end

      it 'dissolves "Kuerzlich erstellt" (created_at in_the_last_days 7)' do
        sf = create_smart_folder_with_rules([
                                              { field: 'created_at', operator: 'in_the_last_days', value: '7' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'created_at' => ['last_7_days'] })
      end

      it 'dissolves "Kuerzlich aktualisiert" (updated_at in_the_last_days 7)' do
        sf = create_smart_folder_with_rules([
                                              { field: 'updated_at', operator: 'in_the_last_days', value: '7' }
                                            ])

        result = described_class.new(sf).call

        expect(result).to be_dissolvable
        expect(result.ad_hoc_filters).to eq({ 'updated_at' => ['last_7_days'] })
      end

      it 'marks "Unbilled" as NOT dissolvable (has_time_sessions + time_session_billed)' do
        sf = create_smart_folder_with_rules([
                                              { field: 'has_time_sessions', operator: 'is', value: 'true' },
                                              { field: 'time_session_billed', operator: 'is_not', value: 'true' }
                                            ])

        result = described_class.new(sf).call

        expect(result).not_to be_dissolvable
        expect(result.complex_rules.size).to eq(2)
      end
    end
  end
end
