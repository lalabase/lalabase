# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Projects::DefaultAttributeService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  describe '#call' do
    subject(:service) { described_class.new(project) }

    it 'creates status, priority and due_date attributes' do
      expect { service.call }.to change { project.ticket_attribute_definitions.count }.by(3)
    end

    describe 'status attribute' do
      before { service.call }

      let(:status_attr) { project.ticket_attribute_definitions.find_by(name: 'status') }

      it 'is a select field' do
        expect(status_attr.field_type).to eq('select')
      end

      it 'is a system attribute' do
        expect(status_attr.system).to be true
      end

      it 'is required' do
        expect(status_attr.validation_rules['required']).to be true
      end

      it 'has position 1' do
        expect(status_attr.position).to eq(1)
      end

      it 'has half width' do
        expect(status_attr.width).to eq('half')
      end

      it 'has DE and EN labels' do
        expect(status_attr.labels).to eq('de' => 'Status', 'en' => 'Status')
      end

      it 'has 5 options with correct values (backlog appended last, not the default)' do
        values = status_attr.allowed_values.map { |v| v['value'] }
        expect(values).to eq(%w[new in_progress resolved closed backlog])
      end

      it 'keeps an active status (not backlog) as the first/default option' do
        expect(status_attr.allowed_values.first['value']).to eq('new')
      end

      it 'has correct colors' do
        colors = status_attr.allowed_values.map { |v| v['color'] }
        expect(colors).to eq(%w[#3B82F6 #F59E0B #22C55E #6B7280 #94A3B8])
      end

      it 'assigns correct system functions' do
        functions = status_attr.allowed_values.map { |v| v['system_functions'] }
        expect(functions).to eq([
                                  ['is_new'],
                                  ['is_in_progress'],
                                  ['is_completed'],
                                  ['is_closed'],
                                  ['is_backlog']
                                ])
      end

      it 'has DE and EN labels for each option' do
        labels_de = status_attr.allowed_values.map { |v| v['labels']['de'] }
        labels_en = status_attr.allowed_values.map { |v| v['labels']['en'] }

        expect(labels_de).to eq(['Neu', 'In Bearbeitung', 'Erledigt', 'Geschlossen', 'Backlog'])
        expect(labels_en).to eq(['New', 'In Progress', 'Resolved', 'Closed', 'Backlog'])
      end
    end

    describe 'priority attribute' do
      before { service.call }

      let(:priority_attr) { project.ticket_attribute_definitions.find_by(name: 'priority') }

      it 'is a select field' do
        expect(priority_attr.field_type).to eq('select')
      end

      it 'is not a system attribute' do
        expect(priority_attr.system).to be false
      end

      it 'is not required' do
        expect(priority_attr.validation_rules['required']).to be false
      end

      it 'has position 2' do
        expect(priority_attr.position).to eq(2)
      end

      it 'has half width' do
        expect(priority_attr.width).to eq('half')
      end

      it 'has DE and EN labels' do
        expect(priority_attr.labels).to eq('de' => 'Priorität', 'en' => 'Priority')
      end

      it 'has 4 options with correct values' do
        values = priority_attr.allowed_values.map { |v| v['value'] }
        expect(values).to eq(%w[low normal high urgent])
      end

      it 'has correct colors' do
        colors = priority_attr.allowed_values.map { |v| v['color'] }
        expect(colors).to eq(%w[#93C5FD #FCD34D #F97316 #EF4444])
      end

      it 'assigns high_priority system function to high and urgent' do
        high_funcs = priority_attr.allowed_values.find { |v| v['value'] == 'high' }['system_functions']
        urgent_funcs = priority_attr.allowed_values.find { |v| v['value'] == 'urgent' }['system_functions']
        low_funcs = priority_attr.allowed_values.find { |v| v['value'] == 'low' }['system_functions']
        normal_funcs = priority_attr.allowed_values.find { |v| v['value'] == 'normal' }['system_functions']

        expect(high_funcs).to eq(['high_priority'])
        expect(urgent_funcs).to eq(['high_priority'])
        expect(low_funcs).to be_nil
        expect(normal_funcs).to be_nil
      end

      it 'assigns ascending signal-bar levels (low=1 … urgent=4)' do
        levels = priority_attr.allowed_values.map { |v| v['level'] }
        expect(levels).to eq([1, 2, 3, 4])
      end
    end

    describe 'due_date attribute' do
      before { service.call }

      let(:due_attr) { project.ticket_attribute_definitions.find_by(name: 'due_date') }

      it 'is a date field marked as the deadline' do
        expect(due_attr.field_type).to eq('date')
        expect(due_attr.deadline?).to be(true)
      end

      it 'is a system attribute with DE/EN labels' do
        expect(due_attr.system).to be(true)
        expect(due_attr.labels).to eq('de' => 'Fälligkeit', 'en' => 'Due date')
      end
    end

    describe 'due_date reconciliation' do
      it 'skips (does not overwrite) a pre-existing non-date due_date attribute' do
        project.ticket_attribute_definitions.create!(
          name: 'due_date', field_type: 'text',
          labels: { 'de' => 'Fällig', 'en' => 'Due' }, position: 9, active: true, width: 'half'
        )

        expect(described_class.ensure_due_date(project)).to eq(:conflict)
        expect(project.ticket_attribute_definitions.find_by(name: 'due_date').field_type).to eq('text')
      end
    end

    describe 'idempotency' do
      it 'does not create duplicate attributes when called twice' do
        service.call

        expect { service.call }.not_to(change { project.ticket_attribute_definitions.count })
      end

      it 'does not overwrite existing status attribute with different options' do
        project.ticket_attribute_definitions.create!(
          name: 'status',
          field_type: 'select',
          labels: { 'de' => 'Status', 'en' => 'Status' },
          options: {
            'allowed_values' => [
              { 'value' => 'custom_open', 'labels' => { 'de' => 'Custom Offen', 'en' => 'Custom Open' } }
            ]
          },
          position: 1,
          active: true,
          width: 'half'
        )

        service.call

        status_attr = project.ticket_attribute_definitions.find_by(name: 'status')
        values = status_attr.allowed_values.map { |v| v['value'] }
        expect(values).to eq(['custom_open'])
      end

      it 'does not overwrite existing priority attribute' do
        project.ticket_attribute_definitions.create!(
          name: 'priority',
          field_type: 'select',
          labels: { 'de' => 'Prio', 'en' => 'Prio' },
          options: {
            'allowed_values' => [
              { 'value' => 'p1', 'labels' => { 'de' => 'P1', 'en' => 'P1' } }
            ]
          },
          position: 2,
          active: true,
          width: 'half'
        )

        service.call

        priority_attr = project.ticket_attribute_definitions.find_by(name: 'priority')
        values = priority_attr.allowed_values.map { |v| v['value'] }
        expect(values).to eq(['p1'])
      end
    end
  end
end
