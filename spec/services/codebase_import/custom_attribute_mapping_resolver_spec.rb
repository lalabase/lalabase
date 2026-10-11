# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImport::CustomAttributeMappingResolver do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:custom_attribute_service) { CodebaseImport::CustomAttributeImportService.new(organisation, user) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  let!(:status_attr) do
    create(:ticket_attribute_definition,
           project: project,
           name: 'status',
           field_type: 'select',
           options: {
             'allowed_values' => [
               { 'value' => 'open', 'labels' => { 'de' => 'Offen', 'en' => 'Open' } },
               { 'value' => 'closed', 'labels' => { 'de' => 'Geschlossen', 'en' => 'Closed' } }
             ]
           })
  end

  describe '#resolve' do
    context 'with status mappings' do
      let(:mappings) do
        {
          'New' => { 'action' => 'create' },
          'Open' => { 'action' => 'map', 'target_value' => 'open' },
          'Resolved' => { 'action' => 'create' }
        }
      end

      let(:resolver) { described_class.new(organisation, 'status', mappings, custom_attribute_service) }

      it 'resolves mappings correctly' do
        result = resolver.resolve

        expect(result['New']).to eq('New')
        expect(result['Open']).to eq('open')
        expect(result['Resolved']).to eq('Resolved')
      end

      it 'adds new values to custom attributes when action is create' do
        resolver.resolve

        status_attr.reload
        allowed_values = status_attr.allowed_values.map { |v| v['value'] }

        expect(allowed_values).to include('New', 'Resolved')
      end
    end

    context 'with invalid mappings' do
      let(:mappings) do
        {
          'Invalid' => { 'action' => 'map', 'target_value' => 'non_existent' }
        }
      end

      let(:resolver) { described_class.new(organisation, 'status', mappings, custom_attribute_service) }

      it 'automatically adds non-existent target value' do
        expect(custom_attribute_service).to receive(:add_allowed_value).with('status', 'non_existent')
        result = resolver.resolve
        expect(result['Invalid']).to eq('non_existent')
      end
    end

    context 'with unknown action' do
      let(:mappings) do
        {
          'Test' => { 'action' => 'unknown' }
        }
      end

      let(:resolver) { described_class.new(organisation, 'status', mappings, custom_attribute_service) }

      it 'raises error for unknown action' do
        expect do
          resolver.resolve
        end.to raise_error(CodebaseImport::TicketImporter::MappingError, /Unbekannte Action für status/)
      end
    end
  end
end
