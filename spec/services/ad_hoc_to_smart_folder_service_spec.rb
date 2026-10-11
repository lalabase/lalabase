# frozen_string_literal: true

require 'rails_helper'

# AdHocToSmartFolderService is a PURE converter: it turns ad-hoc filter params +
# operators into a rule-group structure (arrays of { field:, operator:, value: }
# hashes) plus warnings. Persistence lives in Actors::SaveSmartFolderFromFilters
# (see save_smart_folder_from_filters_spec.rb).
RSpec.describe AdHocToSmartFolderService do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    create(:project_permission, user: user, project: project, tickets_access: 'read_write')
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  def convert(filter_params: {}, operator_params: {})
    described_class.call(project: project, filter_params: filter_params, operator_params: operator_params)
  end

  # The rules of the single (sole) group produced for a conversion.
  def sole_group_rules(conversion)
    expect(conversion.rules_by_group.size).to eq(1)
    conversion.rules_by_group.first
  end

  describe '.call' do
    it 'uses Meeting fields explicitly even when the project has ticket attributes with the same names' do
      %w[participant occurred_at].each do |name|
        create(:ticket_attribute_definition, project: project, name: name, field_type: 'select',
                                             options: { 'allowed_values' => [{ 'value' => 'today', 'labels' => { 'de' => 'Heute' } }] })
      end
      filters = { 'participant' => ['Anna'], 'occurred_at' => ['today'] }
      conversion = described_class.call(project: project, filter_params: filters, target_object_type: 'Meeting')
      expect(sole_group_rules(conversion)).to contain_exactly(
        { field: 'participant', operator: 'has_any_of', value: '["Anna"]' },
        { field: 'occurred_at', operator: 'today', value: nil }
      )
    end

    context 'shape & preloading' do
      it 'returns a Conversion with the precomputed field config map' do
        conversion = convert(filter_params: { 'tag' => ['bug'] })
        expect(conversion.field_config_map).to be_a(Hash)
        expect(conversion.field_config_map).to have_key('tag')
      end

      it 'returns empty warnings when all filters are convertible' do
        expect(convert(filter_params: { 'tag' => ['bug'] }).warnings).to be_empty
      end

      it 'produces no groups for empty filter_params' do
        expect(convert(filter_params: {}).rules_by_group).to be_empty
      end

      it 'preloads referenced users for assignee/creator rules' do
        conversion = convert(filter_params: { 'creator' => [user.id.to_s] })
        expect(conversion.preloaded_references).to include('User')
        expect(conversion.preloaded_references['User']).to have_key(user.id.to_s)
      end

      it 'leaves preloaded_references nil when there are no reference rules' do
        expect(convert(filter_params: { 'tag' => ['bug'] }).preloaded_references).to be_nil
      end
    end

    context 'select custom attribute (status)' do
      before do
        create(:ticket_attribute_definition,
               project: project, name: 'status', field_type: 'select',
               options: {
                 'allowed_values' => [
                   { 'value' => 'Offen', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                   { 'value' => 'InProgress', 'labels' => { 'de' => 'In Bearbeitung', 'en' => 'In Progress' } },
                   { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt', 'en' => 'Done' } }
                 ]
               })
      end

      it 'converts status OR to custom_status in_list' do
        rules = sole_group_rules(convert(filter_params: { 'status' => %w[Offen InProgress] }))
        expect(rules).to contain_exactly(hash_including(field: 'custom_status', operator: 'in_list', value: 'Offen,InProgress'))
      end

      it 'converts status NOT to custom_status not_in_list' do
        rules = sole_group_rules(convert(filter_params: { 'status' => ['Erledigt'] }, operator_params: { 'status' => 'not' }))
        expect(rules).to contain_exactly(hash_including(field: 'custom_status', operator: 'not_in_list', value: 'Erledigt'))
      end
    end

    context 'multiselect custom attribute (skills)' do
      before do
        create(:ticket_attribute_definition,
               project: project, name: 'skills', field_type: 'multiselect',
               options: {
                 'allowed_values' => [
                   { 'value' => 'ruby', 'labels' => { 'de' => 'Ruby', 'en' => 'Ruby' } },
                   { 'value' => 'js', 'labels' => { 'de' => 'JavaScript', 'en' => 'JavaScript' } },
                   { 'value' => 'python', 'labels' => { 'de' => 'Python', 'en' => 'Python' } }
                 ]
               })
      end

      it 'converts multiselect OR to custom_skills in_list' do
        rules = sole_group_rules(convert(filter_params: { 'skills' => %w[ruby js] }))
        expect(rules).to contain_exactly(hash_including(field: 'custom_skills', operator: 'in_list', value: 'ruby,js'))
      end

      it 'converts multiselect AND to one rule per value with contains' do
        rules = sole_group_rules(convert(filter_params: { 'skills' => %w[ruby js] }, operator_params: { 'skills' => 'and' }))
        expect(rules).to eq([
                              { field: 'custom_skills', operator: 'contains', value: 'ruby' },
                              { field: 'custom_skills', operator: 'contains', value: 'js' }
                            ])
      end

      it 'converts multiselect NOT to custom_skills not_in_list' do
        rules = sole_group_rules(convert(filter_params: { 'skills' => %w[ruby js] }, operator_params: { 'skills' => 'not' }))
        expect(rules).to contain_exactly(hash_including(field: 'custom_skills', operator: 'not_in_list', value: 'ruby,js'))
      end
    end

    context 'tag filter' do
      it 'converts tags OR to has_any_of' do
        rules = sole_group_rules(convert(filter_params: { 'tag' => %w[bug urgent] }))
        expect(rules).to contain_exactly(hash_including(field: 'tag', operator: 'has_any_of', value: 'bug,urgent'))
      end

      it 'converts tags AND to has_all_of' do
        rules = sole_group_rules(convert(filter_params: { 'tag' => %w[bug urgent] }, operator_params: { 'tag' => 'and' }))
        expect(rules).to contain_exactly(hash_including(field: 'tag', operator: 'has_all_of', value: 'bug,urgent'))
      end

      it 'converts tags NOT to not_has' do
        rules = sole_group_rules(convert(filter_params: { 'tag' => %w[bug urgent] }, operator_params: { 'tag' => 'not' }))
        expect(rules).to contain_exactly(hash_including(field: 'tag', operator: 'not_has', value: 'bug,urgent'))
      end
    end

    context 'assignee filter' do
      let(:assignee_a) { create(:user) }
      let(:assignee_b) { create(:user) }

      it 'converts single assignee OR to equals' do
        rules = sole_group_rules(convert(filter_params: { 'assignee' => [assignee_a.id.to_s] }))
        expect(rules).to contain_exactly(hash_including(field: 'assignee', operator: 'equals', value: assignee_a.id.to_s))
      end

      it 'converts single assignee NOT to not_equals' do
        rules = sole_group_rules(convert(filter_params: { 'assignee' => [assignee_a.id.to_s] }, operator_params: { 'assignee' => 'not' }))
        expect(rules).to contain_exactly(hash_including(field: 'assignee', operator: 'not_equals', value: assignee_a.id.to_s))
      end

      it 'converts multiple assignees OR to separate rule groups' do
        conversion = convert(filter_params: { 'assignee' => [assignee_a.id.to_s, assignee_b.id.to_s] })
        groups = conversion.rules_by_group
        expect(groups.size).to eq(2)
        expect(groups[0]).to contain_exactly(hash_including(field: 'assignee', operator: 'equals', value: assignee_a.id.to_s))
        expect(groups[1]).to contain_exactly(hash_including(field: 'assignee', operator: 'equals', value: assignee_b.id.to_s))
      end

      it 'converts multiple assignees NOT to separate not_equals rules in one group' do
        rules = sole_group_rules(convert(filter_params: { 'assignee' => [assignee_a.id.to_s, assignee_b.id.to_s] }, operator_params: { 'assignee' => 'not' }))
        expect(rules.map { |r| r[:operator] }).to eq(%w[not_equals not_equals])
        expect(rules.map { |r| r[:value] }).to contain_exactly(assignee_a.id.to_s, assignee_b.id.to_s)
      end
    end

    context 'assignee OR with multiple values and other rules' do
      let(:assignee_a) { create(:user) }
      let(:assignee_b) { create(:user) }

      it 'duplicates base rules into each assignee group' do
        conversion = convert(filter_params: { 'tag' => %w[bug], 'assignee' => [assignee_a.id.to_s, assignee_b.id.to_s] })
        groups = conversion.rules_by_group
        expect(groups.size).to eq(2)
        groups.each do |rules|
          expect(rules.map { |r| r[:field] }).to contain_exactly('tag', 'assignee')
        end
      end
    end

    context 'date filter presets' do
      # The preset IS the operator (SmartFolders::DatePresets): what is written here,
      # SmartFolderDissolver reads back unchanged. Iterate the constant, so a preset
      # the bar gains without a rule form turns this red.
      SmartFolders::DatePresets::KEYS.each do |preset|
        it "converts created_at #{preset} to the valueless operator #{preset}" do
          rules = sole_group_rules(convert(filter_params: { 'created_at' => [preset] }))
          expect(rules).to contain_exactly({ field: 'created_at', operator: preset, value: nil })
        end
      end

      it 'converts an updated_at preset the same way' do
        rules = sole_group_rules(convert(filter_params: { 'updated_at' => ['last_30_days'] }))
        expect(rules).to contain_exactly({ field: 'updated_at', operator: 'last_30_days', value: nil })
      end

      it 'never freezes a preset into a date or a day count' do
        rules = convert(filter_params: { 'created_at' => %w[today yesterday this_week this_month] }).rules_by_group.flatten
        expect(rules.map { |r| r[:value] }).to all(be_nil)
        expect(rules.map { |r| r[:operator] }).not_to include('between', 'in_the_last_days')
      end

      it 'converts two presets to one group each (OR), never into one group (AND)' do
        groups = convert(filter_params: { 'created_at' => %w[today yesterday] }).rules_by_group
        expect(groups.map { |g| g.map { |r| r[:operator] } }).to contain_exactly(['today'], ['yesterday'])
      end

      it 'crosses two presets with two assignees into four groups' do
        first = create(:user)
        second = create(:user)
        groups = convert(filter_params: { 'created_at' => %w[today yesterday],
                                          'assignee' => [first.id.to_s, second.id.to_s] }).rules_by_group
        combos = groups.map do |rules|
          [rules.find { |r| r[:field] == 'created_at' }[:operator], rules.find { |r| r[:field] == 'assignee' }[:value]]
        end
        expect(combos).to contain_exactly(
          ['today', first.id.to_s], ['today', second.id.to_s],
          ['yesterday', first.id.to_s], ['yesterday', second.id.to_s]
        )
      end

      it 'drops a value that is no preset' do
        expect(convert(filter_params: { 'created_at' => ['fancy'] }).rules_by_group).to be_empty
      end
    end

    context 'due date presets' do
      let!(:deadline_def) do
        create(:ticket_attribute_definition, project: project, name: 'frist', field_type: 'date',
                                             labels: { 'de' => 'Frist', 'en' => 'Deadline' }, options: { 'deadline' => true })
      end

      # The deadline presets are the valueless operators of the project's deadline field,
      # whatever it is called (Ticket::DUE_DATE_PRESET_KEYS). Iterate the constant.
      Ticket::DUE_DATE_PRESET_KEYS.each do |preset|
        it "converts due_date #{preset} to the valueless operator #{preset} on the deadline field" do
          rules = sole_group_rules(convert(filter_params: { 'due_date' => [preset] }))
          expect(rules).to contain_exactly({ field: 'custom_frist', operator: preset, value: nil })
        end
      end

      it 'converts two presets to one group each' do
        groups = convert(filter_params: { 'due_date' => %w[overdue due_today] }).rules_by_group
        expect(groups.map { |g| g.map { |r| r[:operator] } }).to contain_exactly(['overdue'], ['due_today'])
      end

      it 'skips NOT on due_date with a warning' do
        conversion = convert(filter_params: { 'due_date' => ['overdue'] }, operator_params: { 'due_date' => 'not' })
        expect(conversion.rules_by_group).to be_empty
        expect(conversion.warnings.first).to include('due_date')
      end
    end

    context 'due date presets without a deadline field' do
      it 'skips the category with a warning instead of writing a rule the field rejects' do
        conversion = convert(filter_params: { 'due_date' => ['overdue'] })
        expect(conversion.rules_by_group).to be_empty
        expect(conversion.warnings.size).to eq(1)
      end
    end

    # The bar's waiting states (doc/ticket_relations_plan.md, revision 4, §9): one flag value,
    # "ist" is IS, "ist nicht" is IS_NOT, the rule value is the flag.
    context 'waiting and blocking' do
      %w[waiting blocking].each do |field|
        it "converts #{field} 'ist' to IS true" do
          rules = sole_group_rules(convert(filter_params: { field => ['true'] }))
          expect(rules).to contain_exactly({ field: field, operator: SmartFolders::Operators::IS, value: 'true' })
        end

        it "converts #{field} 'ist nicht' to IS_NOT true" do
          rules = sole_group_rules(convert(filter_params: { field => ['true'] }, operator_params: { field => 'not' }))
          expect(rules).to contain_exactly({ field: field, operator: SmartFolders::Operators::IS_NOT, value: 'true' })
        end

        it "drops a #{field} value the bar never offers" do
          expect(convert(filter_params: { field => ['false'] }).rules_by_group).to be_empty
        end
      end

      it 'writes both next to a status condition into one group' do
        rules = sole_group_rules(convert(filter_params: { 'waiting' => ['true'], 'blocking' => ['true'] },
                                         operator_params: { 'blocking' => 'not' }))
        expect(rules).to contain_exactly(
          { field: 'waiting', operator: SmartFolders::Operators::IS, value: 'true' },
          { field: 'blocking', operator: SmartFolders::Operators::IS_NOT, value: 'true' }
        )
      end
    end

    context 'creator filter' do
      let(:second_user) { create(:user) }

      it 'converts a single creator to an equals rule without warning' do
        conversion = convert(filter_params: { 'creator' => [user.id.to_s] })
        expect(sole_group_rules(conversion)).to contain_exactly(hash_including(field: 'creator', operator: 'equals', value: user.id.to_s))
        expect(conversion.warnings).to be_empty
      end

      it 'converts NOT creators to not_equals rules in one group' do
        rules = sole_group_rules(convert(filter_params: { 'creator' => [user.id.to_s, second_user.id.to_s] }, operator_params: { 'creator' => 'not' }))
        expect(rules.map { |r| r[:operator] }.uniq).to eq(['not_equals'])
        expect(rules.map { |r| r[:value] }).to contain_exactly(user.id.to_s, second_user.id.to_s)
      end

      it 'converts multiple OR creators to one group per value' do
        groups = convert(filter_params: { 'creator' => [user.id.to_s, second_user.id.to_s] }).rules_by_group
        expect(groups.size).to eq(2)
        expect(groups.map { |g| g.first[:value] }).to contain_exactly(user.id.to_s, second_user.id.to_s)
      end

      it 'builds the cross product when assignee AND creator are both multi-OR' do
        groups = convert(filter_params: {
                           'assignee' => [user.id.to_s, second_user.id.to_s],
                           'creator' => [user.id.to_s, second_user.id.to_s]
                         }).rules_by_group
        expect(groups.size).to eq(4)
        combos = groups.map do |rules|
          [rules.find { |r| r[:field] == 'assignee' }[:value], rules.find { |r| r[:field] == 'creator' }[:value]]
        end
        expect(combos).to contain_exactly(
          [user.id.to_s, user.id.to_s],
          [user.id.to_s, second_user.id.to_s],
          [second_user.id.to_s, user.id.to_s],
          [second_user.id.to_s, second_user.id.to_s]
        )
      end
    end

    context 'unsupported filters' do
      it 'skips NOT on date filter and adds a warning' do
        conversion = convert(filter_params: { 'created_at' => ['last_7_days'] }, operator_params: { 'created_at' => 'not' })
        expect(conversion.rules_by_group).to be_empty
        expect(conversion.warnings.size).to eq(1)
        expect(conversion.warnings.first).to include('created_at')
      end
    end

    context 'combined filters' do
      before do
        create(:ticket_attribute_definition,
               project: project, name: 'status', field_type: 'select',
               options: {
                 'allowed_values' => [
                   { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt', 'en' => 'Done' } }
                 ]
               })
      end

      it 'creates correct rules for status NOT + tag AND combination' do
        rules = sole_group_rules(convert(
                                   filter_params: { 'status' => ['Erledigt'], 'tag' => %w[bug urgent] },
                                   operator_params: { 'status' => 'not', 'tag' => 'and' }
                                 ))
        expect(rules).to contain_exactly(
          hash_including(field: 'custom_status', operator: 'not_in_list', value: 'Erledigt'),
          hash_including(field: 'tag', operator: 'has_all_of', value: 'bug,urgent')
        )
      end
    end

    context 'backward compatibility' do
      it 'handles nil operator_params (defaults to OR)' do
        rules = sole_group_rules(convert(filter_params: { 'tag' => ['bug'] }, operator_params: {}))
        expect(rules.first[:operator]).to eq('has_any_of')
      end

      it 'ignores blank values in filter_params' do
        rules = sole_group_rules(convert(filter_params: { 'tag' => ['', 'bug', ''] }))
        expect(rules.first[:value]).to eq('bug')
      end
    end
  end
  # Several values of one category become one group each, and several such
  # categories multiply. The bounds keep a saved view a query the database can
  # answer; the product is checked before it is built.
  # One list of the bar's special categories: the sanitizer of SmartFoldersController reads this
  # constant, the filter service applies it. Two copies drifted the moment a filter was added to
  # one of them (plan §9, option A).
  describe 'SPECIAL_FIELDS' do
    it 'is the list of AdHocFilterService, not a copy of it' do
      expect(described_class::SPECIAL_FIELDS).to equal(AdHocFilterService::SPECIAL_FIELDS)
    end

    it 'names the waiting states' do
      expect(described_class::SPECIAL_FIELDS).to include('waiting', 'blocking')
    end
  end

  describe 'bounds of the rule tree' do
    def ids(count)
      Array.new(count) { SecureRandom.uuid }
    end

    it 'collapses repeated values instead of multiplying them' do
      conversion = convert(filter_params: { 'created_at' => %w[today] * 30, 'updated_at' => %w[today] * 30 })
      expect(conversion.rules_by_group.size).to eq(1)
    end

    it 'keeps a tree at the bounds' do
      conversion = convert(filter_params: { 'creator' => ids(SmartFolder::MAX_RULE_GROUPS) })
      expect(conversion.rules_by_group.size).to eq(SmartFolder::MAX_RULE_GROUPS)
    end

    it 'refuses more combinations than a view may hold' do
      expect { convert(filter_params: { 'creator' => ids(8), 'assignee' => ids(8) }) }
        .to raise_error(described_class::RuleTreeTooLarge)
    end

    it 'refuses more rules in one group than a view may hold' do
      expect { convert(filter_params: { 'creator' => ids(SmartFolder::MAX_RULES_PER_GROUP + 1) }, operator_params: { 'creator' => 'not' }) }
        .to raise_error(described_class::RuleTreeTooLarge)
    end
  end
end
