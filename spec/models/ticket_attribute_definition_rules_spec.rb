# frozen_string_literal: true

require 'rails_helper'

# The rules of TicketAttributeDefinition that had no direct spec: the whitelists, the
# name format and its immutability, the label requirement, the database defaults and
# unique index, the name generated from a label, and the per-ticket rules
# (visible_for?, required_for?, strictly_required?, validate_value on select fields).
# Each example names the mutation it is there to kill.
RSpec.describe TicketAttributeDefinition, 'rules' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def labels(text = 'Feld')
    { 'de' => text, 'en' => text }
  end

  def select_options(*values)
    { 'allowed_values' => values.map { |value| { 'value' => value, 'labels' => { 'de' => value.upcase, 'en' => value } } } }
  end

  # Something with the two readers visible_for?/required_for? use, so the rules are
  # tested without the ticket's own custom attribute validation getting in the way.
  def stand_in(ticket_type, custom_attributes)
    double('ticket', ticket_type: ticket_type, custom_attributes: custom_attributes)
  end

  describe 'field_type whitelist' do
    # Written out, not read from FIELD_TYPES: iterating the constant loses the example
    # together with the entry, so a shrunk list would stay green. Stored rows carry
    # these types; dropping one makes every such field invalid on its next save.
    %w[select multiselect checkbox text date].each do |type|
      it "accepts #{type.inspect}" do
        expect(build(:ticket_attribute_definition, project: project, field_type: type)).to be_valid
      end
    end

    ['Select', 'select ', 'currency', 'number', '', nil].each do |type|
      it "rejects #{type.inspect}" do
        definition = build(:ticket_attribute_definition, project: project, field_type: type)

        expect(definition).not_to be_valid
        expect(definition.errors[:field_type]).to be_present
      end
    end
  end

  describe 'width whitelist' do
    # Written out for the same reason as the field types above.
    %w[full half third quarter].each do |width|
      it "accepts #{width.inspect}" do
        expect(build(:ticket_attribute_definition, project: project, width: width)).to be_valid
      end
    end

    %w[Full half-width 50%].each do |width|
      it "rejects #{width.inspect}" do
        definition = build(:ticket_attribute_definition, project: project, width: width)

        expect(definition).not_to be_valid
        expect(definition.errors.details[:width]).to include(a_hash_including(error: :inclusion))
      end
    end
  end

  describe 'position boundary' do
    it 'accepts 0 (boundary n)' do
      expect(build(:ticket_attribute_definition, project: project, position: 0)).to be_valid
    end

    it 'rejects -1 (boundary n-1)' do
      definition = build(:ticket_attribute_definition, project: project, position: -1)

      expect(definition).not_to be_valid
      expect(definition.errors.details[:position]).to include(a_hash_including(error: :greater_than_or_equal_to))
    end
  end

  describe 'name format' do
    %w[a status due_date field_2 a1_b2].each do |name|
      it "accepts #{name.inspect}" do
        expect(build(:ticket_attribute_definition, project: project, name: name)).to be_valid
      end
    end

    # "Status" kills a dropped case rule, "1st"/"_x" the first-letter rule, "a-b"/"a b"
    # the character class, and the two newline cases `^`/`$` instead of `\A`/`\z`.
    ['Status', '1st', '_x', 'a-b', 'a b', "status\nX", "X\nstatus"].each do |name|
      it "rejects #{name.inspect}" do
        definition = build(:ticket_attribute_definition, project: project, name: name, labels: labels)

        expect(definition).not_to be_valid
        expect(definition.errors.details[:name]).to include(a_hash_including(error: :invalid))
        expect(definition.errors[:name]).to include(definition.errors.generate_message(:name, :lowercase_underscore))
      end
    end
  end

  describe 'name uniqueness (defense in depth)' do
    it 'rejects a second definition with the same name in the same project (model layer)' do
      create(:ticket_attribute_definition, project: project, name: 'notes')
      duplicate = build(:ticket_attribute_definition, project: project, name: 'notes')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors.details[:name]).to include(a_hash_including(error: :taken))
    end

    it 'raises RecordNotUnique when the model validation is bypassed (database layer)' do
      create(:ticket_attribute_definition, project: project, name: 'notes')
      racer = build(:ticket_attribute_definition, project: project, name: 'notes')

      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows the same name in another project' do
      create(:ticket_attribute_definition, project: project, name: 'notes')

      expect(build(:ticket_attribute_definition, project: create(:project, organisation: organisation),
                                                 name: 'notes')).to be_valid
    end
  end

  describe 'label requirement' do
    it 'accepts a German label alone' do
      expect(build(:ticket_attribute_definition, project: project, labels: { 'de' => 'Feld' })).to be_valid
    end

    it 'accepts an English label alone' do
      expect(build(:ticket_attribute_definition, project: project, labels: { 'en' => 'Field' })).to be_valid
    end

    [{}, { 'de' => '', 'en' => ' ' }, { 'fr' => 'Champ' }, nil].each do |given|
      it "rejects #{given.inspect}" do
        definition = build(:ticket_attribute_definition, project: project, name: 'field', labels: given)

        expect(definition).not_to be_valid
        expect(definition.errors.details[:labels]).to include(a_hash_including(error: :at_least_one_required))
      end
    end
  end

  describe 'defaults' do
    # Not through the factory: it sets every one of these itself.
    let(:bare) do
      described_class.create!(project: project, name: 'bare', field_type: 'text', labels: labels).reload
    end

    it 'takes the database defaults when the columns are omitted on insert' do
      expect(bare).to have_attributes(active: true, system: false, width: 'full', position: 0,
                                      options: {}, validation_rules: {}, visibility_rules: {})
    end

    it 'turns an explicit nil in the jsonb columns into an empty hash before validation' do
      definition = build(:ticket_attribute_definition, project: project,
                                                       options: nil, validation_rules: nil, visibility_rules: nil)

      expect(definition).to be_valid
      expect(definition).to have_attributes(options: {}, validation_rules: {}, visibility_rules: {})
    end
  end

  describe 'cascade' do
    it 'is destroyed with its project' do
      create(:ticket_attribute_definition, project: project)

      expect { project.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  describe 'name generated from the label (on create)' do
    def created_from(labels)
      described_class.create!(project: project, field_type: 'text', labels: labels)
    end

    it 'prefers the English label' do
      expect(created_from('de' => 'Kunde', 'en' => 'Customer').name).to eq('customer')
    end

    it 'falls back to the German label' do
      expect(created_from('de' => 'Ansprechpartner Firma').name).to eq('ansprechpartner_firma')
    end

    it 'prefixes a label that does not start with a letter' do
      expect(created_from('en' => '2nd contact').name).to eq('field_2nd_contact')
    end

    it 'counts up from 2 when the name is taken in the project' do
      created_from('en' => 'Customer')

      expect(created_from('en' => 'Customer').name).to eq('customer_2')
      expect(created_from('en' => 'Customer').name).to eq('customer_3')
    end

    it 'ignores a taken name in another project' do
      described_class.create!(project: create(:project, organisation: organisation), field_type: 'text',
                              labels: { 'en' => 'Customer' })

      expect(created_from('en' => 'Customer').name).to eq('customer')
    end

    it 'keeps a name that was given explicitly' do
      definition = described_class.create!(project: project, name: 'client', field_type: 'text',
                                           labels: { 'en' => 'Customer' })

      expect(definition.name).to eq('client')
    end

    it 'does not rename an existing record when its label changes' do
      definition = created_from('en' => 'Customer')
      definition.update!(labels: { 'en' => 'Client' })

      expect(definition.reload.name).to eq('customer')
    end
  end

  describe 'name immutable while tickets use it' do
    let!(:definition) { create(:ticket_attribute_definition, project: project, name: 'notes') }

    it 'refuses a rename once a ticket of the project carries the key' do
      create(:ticket, project: project, custom_attributes: { 'notes' => 'x' })
      expect(definition).to be_in_use

      definition.name = 'remarks'

      expect(definition).not_to be_valid
      expect(definition.errors.details[:name]).to include(a_hash_including(error: :immutable_when_in_use))
    end

    it 'allows a rename while no ticket carries the key' do
      create(:ticket, project: project, custom_attributes: {})
      expect(definition).not_to be_in_use

      definition.name = 'remarks'

      expect(definition).to be_valid
    end

    it 'ignores tickets of another project with the same key' do
      other_project = create(:project, organisation: organisation)
      create(:ticket_attribute_definition, project: other_project, name: 'notes')
      create(:ticket, project: other_project, custom_attributes: { 'notes' => 'x' })

      definition.name = 'remarks'

      expect(definition).to be_valid
    end

    it 'allows other changes to a definition in use' do
      create(:ticket, project: project, custom_attributes: { 'notes' => 'x' })

      expect(definition.update(labels: labels('Notizen'), position: 4)).to be(true)
    end
  end

  describe 'system functions' do
    SystemFunctions::Registry::ALL_FUNCTIONS.each do |key|
      it "accepts the registered function #{key.inspect}" do
        definition = build(:ticket_attribute_definition, :select, project: project, options: {
                             'allowed_values' => [{ 'value' => 'a', 'labels' => labels, 'system_functions' => [key] }]
                           })

        expect(definition).to be_valid
      end
    end

    it 'rejects an unknown function and names it and the option' do
      definition = build(:ticket_attribute_definition, :select, project: project, options: {
                           'allowed_values' => [{ 'value' => 'a', 'labels' => labels, 'system_functions' => ['is_bogus'] }]
                         })

      expect(definition).not_to be_valid
      expect(definition.errors.details[:options])
        .to include({ error: :invalid_system_function, func_key: 'is_bogus', option: 'a' })
    end

    it 'checks multiselect fields as well' do
      definition = build(:ticket_attribute_definition, project: project, field_type: 'multiselect', options: {
                           'allowed_values' => [{ 'value' => 'a', 'labels' => labels, 'system_functions' => ['is_bogus'] }]
                         })

      expect(definition).not_to be_valid
    end

    it 'returns the functions of a value, and [] for an unknown value' do
      definition = build(:ticket_attribute_definition, :select, project: project, options: {
                           'allowed_values' => [{ 'value' => 'a', 'labels' => labels, 'system_functions' => ['is_new'] }]
                         })

      expect(definition.system_functions_for('a')).to eq(['is_new'])
      expect(definition.system_functions_for('b')).to eq([])
    end
  end

  describe '#validate_value on select fields' do
    let(:select_field) do
      build(:ticket_attribute_definition, project: project, field_type: 'select', options: select_options('low', 'high'))
    end
    let(:multi_field) do
      build(:ticket_attribute_definition, project: project, field_type: 'multiselect', options: select_options('a', 'b'))
    end

    it 'accepts a configured value' do
      expect(select_field.validate_value('high')).to be_empty
    end

    it 'rejects a value that is not configured, compared exactly' do
      expect(select_field.validate_value('HIGH')).to eq([I18n.t('errors.messages.inclusion')])
    end

    it 'accepts a multiselect subset, including all values' do
      expect(multi_field.validate_value(%w[a])).to be_empty
      expect(multi_field.validate_value(%w[a b])).to be_empty
    end

    it 'rejects a multiselect list with one unknown value among known ones' do
      expect(multi_field.validate_value(%w[a c])).to eq([I18n.t('errors.messages.inclusion')])
    end

    it 'rejects a plain string for a multiselect' do
      expect(multi_field.validate_value('a')).to eq([I18n.t('errors.messages.invalid')])
    end

    it 'reports a missing value only when the field is required' do
      required = build(:ticket_attribute_definition, project: project, field_type: 'select',
                                                     options: select_options('low'), validation_rules: { 'required' => true })

      expect(required.validate_value('')).to eq([I18n.t('errors.messages.blank')])
      expect(select_field.validate_value('')).to be_empty
    end
  end

  describe '#visible_for?' do
    def visible_with(rules, ticket_type: 'bug', attributes: {})
      build(:ticket_attribute_definition, project: project, visibility_rules: rules)
        .visible_for?(stand_in(ticket_type, attributes))
    end

    it 'is visible without rules' do
      expect(visible_with({})).to be(true)
    end

    it 'follows the ticket type' do
      expect(visible_with({ 'ticket_type' => 'bug' }, ticket_type: 'bug')).to be(true)
      expect(visible_with({ 'ticket_type' => 'bug' }, ticket_type: 'task')).to be(false)
    end

    it 'follows the presence of another attribute' do
      expect(visible_with({ 'has_attribute' => 'customer' }, attributes: { 'customer' => 'ACME' })).to be(true)
      expect(visible_with({ 'has_attribute' => 'customer' }, attributes: { 'customer' => '' })).to be(false)
    end

    it 'follows the value of another attribute' do
      rule = { 'attribute_equals' => { 'attribute' => 'kind', 'value' => 'external' } }

      expect(visible_with(rule, attributes: { 'kind' => 'external' })).to be(true)
      expect(visible_with(rule, attributes: { 'kind' => 'internal' })).to be(false)
    end

    it 'needs ALL rules to hold, not any' do
      rules = { 'ticket_type' => 'bug', 'has_attribute' => 'customer' }

      expect(visible_with(rules, ticket_type: 'bug', attributes: {})).to be(false)
    end

    it 'ignores an unknown rule key' do
      expect(visible_with({ 'something_new' => 'x' })).to be(true)
    end
  end

  describe 'requirement' do
    def field_with(rules)
      build(:ticket_attribute_definition, project: project, validation_rules: rules)
    end

    let(:ticket) { stand_in('bug', { 'kind' => 'external' }) }
    let(:conditional) do
      field_with('required' => true, 'required_if' => { 'attribute' => 'kind', 'value' => 'external' })
    end

    it 'is optional without the flag' do
      expect(field_with({}).required_for?(ticket)).to be(false)
      expect(field_with({}).strictly_required?).to be(false)
    end

    it 'is required for every ticket with the flag alone' do
      expect(field_with('required' => true).required_for?(ticket)).to be(true)
      expect(field_with('required' => true).strictly_required?).to be(true)
    end

    # A form posts "true" as a string. Only a real true counts, "true" must not.
    it 'does not treat the string "true" as required' do
      expect(field_with('required' => 'true').required_for?(ticket)).to be(false)
      expect(field_with('required' => 'true').strictly_required?).to be(false)
    end

    it 'follows the condition when one is set' do
      expect(conditional.required_for?(ticket)).to be(true)
      expect(conditional.required_for?(stand_in('bug', { 'kind' => 'internal' }))).to be(false)
    end

    it 'is never strictly required with a condition, even when the condition holds' do
      expect(conditional.strictly_required?).to be(false)
    end
  end

  describe '#display_value and #label_for' do
    let(:field) do
      build(:ticket_attribute_definition, project: project, name: 'priority', field_type: 'select',
                                          labels: { 'de' => 'Priorität', 'en' => 'Priority' },
                                          options: select_options('low', 'high'))
    end

    it 'shows the label of the current locale, then the default locale' do
      expect(field.display_value('low', :en)).to eq('low')
      expect(field.display_value('low', :de)).to eq('LOW')
      expect(field.display_value('low', :fr)).to eq('LOW')
    end

    it 'joins multiselect values' do
      field.field_type = 'multiselect'

      expect(field.display_value(%w[low high], :de)).to eq('LOW, HIGH')
    end

    it 'shows an unknown value as it is' do
      expect(field.display_value('gone', :de)).to eq('gone')
    end

    it 'falls back from the locale to the default locale to the humanized name' do
      expect(field.label_for(:en)).to eq('Priority')
      expect(field.label_for(:fr)).to eq('Priorität')
      expect(build(:ticket_attribute_definition, project: project, name: 'due_date', labels: { 'en' => '' })
               .tap { |d| d.labels = {} }.label_for(:de)).to eq('Due date')
    end
  end
end
