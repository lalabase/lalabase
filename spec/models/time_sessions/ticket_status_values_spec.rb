# frozen_string_literal: true

require 'rails_helper'

# What: The status values of one project, for the time list's ticket filter
#       (step 3b of doc/zeiten_weitere_filter_plan.md).
# Why:  The menu lists them in the project's order and in the reader's
#       language, and the page names a typed value only when it is one of them,
#       compared the way the filter matches (exactly).
RSpec.describe TimeSessions::TicketStatusValues do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def status_definition(allowed, active: true)
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                         active: active, options: { 'allowed_values' => allowed })
  end

  describe '.for' do
    it 'lists the values in their order, each in the reader\'s language' do
      status_definition([{ 'value' => 'Offen', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
                         { 'value' => 'Fertig', 'labels' => { 'de' => 'Fertig', 'en' => 'Finished' } }])

      expect(described_class.for(project).map(&:value)).to eq(%w[Offen Fertig])
      expect(I18n.with_locale(:en) { described_class.for(project).map(&:label) }).to eq(%w[Open Finished])
    end

    it 'shows the stored value of an option without labels' do
      status_definition([{ 'value' => 'Done' }])

      expect(described_class.for(project).map(&:label)).to eq(['Done'])
    end

    it 'has nothing for a project without an active status field' do
      status_definition([{ 'value' => 'Offen' }], active: false)

      expect(described_class.for(project)).to eq([])
    end

    it 'reads the status field, not another select' do
      create(:ticket_attribute_definition, project: project, name: 'priority', field_type: 'select',
                                           options: { 'allowed_values' => [{ 'value' => 'Hoch' }] })

      expect(described_class.for(project)).to eq([])
    end
  end

  describe '.find' do
    let(:choices) { [described_class::Choice.new(value: 'In Review', label: 'In Review')] }

    it 'finds the offered value' do
      expect(described_class.find(choices, 'In Review')).to eq(choices.first)
    end

    # Exactly, as the filter matches: a value in another case finds no
    # booking, so it names nothing either.
    it 'finds nothing for another case, another value, a blank or a list' do
      expect(described_class.find(choices, 'in review')).to be_nil
      expect(described_class.find(choices, 'Review')).to be_nil
      expect(described_class.find(choices, '')).to be_nil
      expect(described_class.find(choices, ['In Review'])).to be_nil
    end
  end
end
