# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImport::CustomAttributeImportService do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:service) { described_class.new(organisation, user) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe '#ensure_import_attributes' do
    context 'when project has no attribute definitions' do
      it 'creates status and priority attributes on the project' do
        expect(project.ticket_attribute_definitions).to be_empty

        service.ensure_import_attributes(project)

        project.reload
        status_attr = project.ticket_attribute_definitions.find_by(name: 'status')
        priority_attr = project.ticket_attribute_definitions.find_by(name: 'priority')

        expect(status_attr).to be_present
        expect(status_attr.field_type).to eq('select')
        expect(status_attr.validation_rules['required']).to be true

        expect(priority_attr).to be_present
        expect(priority_attr.field_type).to eq('select')
        expect(priority_attr.validation_rules['required']).to be false
      end
    end

    context 'when attributes already exist' do
      let!(:status_attr) { create(:ticket_attribute_definition, project: project, name: 'status') }
      let!(:priority_attr) { create(:ticket_attribute_definition, project: project, name: 'priority') }

      # These deliberately do NOT assert a global TicketAttributeDefinition.count. The earlier
      # version did, and went red the moment DefaultAttributeService gained a third default
      # (the due-date field) that this context does not pre-create — a false alarm about
      # duplication when nothing had been duplicated. What the service actually promises is
      # that it leaves existing definitions alone and adds each default at most once.
      it 'does not duplicate the definitions that are already there' do
        service.ensure_import_attributes(project)

        expect(project.ticket_attribute_definitions.where(name: 'status').count).to eq(1)
        expect(project.ticket_attribute_definitions.where(name: 'priority').count).to eq(1)
        expect(status_attr.reload).to be_persisted
        expect(priority_attr.reload).to be_persisted
      end

      it 'is idempotent — a second run creates nothing at all' do
        service.ensure_import_attributes(project)

        expect do
          service.ensure_import_attributes(project)
        end.not_to(change { TicketAttributeDefinition.count })
      end
    end
  end

  describe '#add_allowed_value' do
    let!(:status_attr) do
      create(:ticket_attribute_definition,
             project: project,
             name: 'status',
             field_type: 'select',
             options: {
               'allowed_values' => [
                 { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } }
               ]
             })
    end

    it 'adds new value to allowed_values' do
      service.add_allowed_value('status', 'closed', 'Geschlossen')

      status_attr.reload
      allowed_values = status_attr.allowed_values

      expect(allowed_values.size).to eq(2)
      expect(allowed_values.last['value']).to eq('closed')
      expect(allowed_values.last['labels']['de']).to eq('Geschlossen')
    end

    it 'does not add duplicate values' do
      service.add_allowed_value('status', 'open', 'Offen')

      status_attr.reload
      allowed_values = status_attr.allowed_values

      expect(allowed_values.size).to eq(1)
    end

    it 'humanizes value if no label provided' do
      service.add_allowed_value('status', 'in_progress')

      status_attr.reload
      allowed_values = status_attr.allowed_values

      expect(allowed_values.last['labels']['de']).to eq('In progress')
    end
  end

  describe '#collect_unique_values' do
    let(:tickets_data) do
      [
        { status_cache: 'new', priority_cache: 'high' },
        { status_cache: 'open', priority_cache: 'normal' },
        { status_cache: 'new', priority_cache: 'high' }, # duplicate
        { status_cache: 'closed', priority_cache: 'low' }
      ]
    end

    it 'returns unique status and priority values' do
      result = service.collect_unique_values(tickets_data)

      expect(result[:statuses]).to contain_exactly('new', 'open', 'closed')
      expect(result[:priorities]).to contain_exactly('high', 'normal', 'low')
    end
  end

  describe '#prepare_for_import' do
    let(:tickets_data) do
      [
        { status_cache: 'New', priority_cache: 'High' },
        { status_cache: 'Open', priority_cache: 'Normal' },
        { status_cache: 'Resolved', priority_cache: 'Low' }
      ]
    end

    it 'creates attributes and adds all unique values' do
      service.prepare_for_import(project, tickets_data)

      project.reload
      status_attr = project.ticket_attribute_definitions.find_by(name: 'status')
      priority_attr = project.ticket_attribute_definitions.find_by(name: 'priority')

      expect(status_attr).to be_present
      expect(priority_attr).to be_present

      status_values = status_attr.allowed_values.map { |v| v['value'] }
      priority_values = priority_attr.allowed_values.map { |v| v['value'] }

      expect(status_values).to include('New', 'Open', 'Resolved')
      expect(priority_values).to include('High', 'Normal', 'Low')
    end
  end
end
