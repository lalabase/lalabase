# frozen_string_literal: true

# == Schema Information
#
# Table name: codebase_import_mappings
#
#  id           :uuid             not null, primary key
#  entity_type  :string           not null
#  mapping_data :json
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  codebase_id  :string           not null
#  local_id     :uuid             not null
#
# Indexes
#
#  index_codebase_import_mappings_on_codebase_id_and_entity_type  (codebase_id,entity_type) UNIQUE
#  index_codebase_import_mappings_on_entity_type                  (entity_type)
#  index_codebase_import_mappings_on_local_id_and_entity_type     (local_id,entity_type)
#
require 'rails_helper'

RSpec.describe CodebaseImportMapping, type: :model do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'organisation boundary' do
    let(:other_organisation) { create(:organisation) }

    it 'keeps the mappings of each organisation apart, even for the same Codebase id' do
      local_ids = [organisation, other_organisation].to_h do |org|
        ActsAsTenant.with_tenant(org) do
          [org, described_class.create!(codebase_id: '500', local_id: SecureRandom.uuid, entity_type: 'Ticket').local_id]
        end
      end

      Prosopite.pause do
        [organisation, other_organisation].each do |org|
          ActsAsTenant.with_tenant(org) do
            expect(described_class.find_local_id('500', 'Ticket')).to eq(local_ids[org])
          end
        end
      end
    end

    it 'records the organisation it was created in' do
      mapping = described_class.create!(codebase_id: '501', local_id: SecureRandom.uuid, entity_type: 'User')
      expect(mapping.organisation_id).to eq(organisation.id)
    end
  end

  describe 'validations' do
    subject { build(:codebase_import_mapping) }

    it { should validate_presence_of(:codebase_id) }
    it { should validate_presence_of(:local_id) }
    it { should validate_presence_of(:entity_type) }
  end

  describe 'scopes' do
    let!(:user_mapping) { create(:codebase_import_mapping, entity_type: 'User') }
    let!(:ticket_mapping) { create(:codebase_import_mapping, entity_type: 'Ticket') }
    let!(:other_mapping) { create(:codebase_import_mapping, entity_type: 'Document') }

    describe '.users' do
      it 'returns only user mappings' do
        expect(described_class.users).to contain_exactly(user_mapping)
      end
    end

    describe '.tickets' do
      it 'returns only ticket mappings' do
        expect(described_class.tickets).to contain_exactly(ticket_mapping)
      end
    end
  end

  describe '.find_local_id' do
    let!(:mapping) do
      create(:codebase_import_mapping,
             codebase_id: 'cb123',
             entity_type: 'User',
             local_id: SecureRandom.uuid)
    end

    context 'when mapping exists' do
      it 'returns the local_id' do
        result = described_class.find_local_id('cb123', 'User')
        expect(result).to eq(mapping.local_id)
      end
    end

    context 'when mapping does not exist' do
      it 'returns nil' do
        result = described_class.find_local_id('nonexistent', 'User')
        expect(result).to be_nil
      end
    end

    context 'when codebase_id exists but entity_type is different' do
      it 'returns nil' do
        result = described_class.find_local_id('cb123', 'Ticket')
        expect(result).to be_nil
      end
    end
  end

  describe '#original_data' do
    context 'when mapping_data contains original_data' do
      let(:mapping) do
        create(:codebase_import_mapping,
               mapping_data: {
                 'original_data' => { 'name' => 'Test User', 'email' => 'test@example.com' },
                 'action' => 'imported'
               })
      end

      it 'returns the original_data' do
        expect(mapping.original_data).to eq({ 'name' => 'Test User', 'email' => 'test@example.com' })
      end
    end

    context 'when mapping_data is nil' do
      let(:mapping) { create(:codebase_import_mapping, mapping_data: nil) }

      it 'returns nil' do
        expect(mapping.original_data).to be_nil
      end
    end

    context 'when mapping_data does not contain original_data' do
      let(:mapping) { create(:codebase_import_mapping, mapping_data: { 'action' => 'imported' }) }

      it 'returns nil' do
        expect(mapping.original_data).to be_nil
      end
    end
  end

  describe '#action_taken' do
    context 'when mapping_data contains action' do
      let(:mapping) do
        create(:codebase_import_mapping,
               mapping_data: {
                 'action' => 'imported',
                 'original_data' => { 'name' => 'Test User' }
               })
      end

      it 'returns the action' do
        expect(mapping.action_taken).to eq('imported')
      end
    end

    context 'when mapping_data is nil' do
      let(:mapping) { create(:codebase_import_mapping, mapping_data: nil) }

      it 'returns nil' do
        expect(mapping.action_taken).to be_nil
      end
    end

    context 'when mapping_data does not contain action' do
      let(:mapping) { create(:codebase_import_mapping, mapping_data: { 'original_data' => { 'name' => 'Test' } }) }

      it 'returns nil' do
        expect(mapping.action_taken).to be_nil
      end
    end
  end

  describe 'database constraints' do
    it 'enforces unique constraint on codebase_id and entity_type' do
      create(:codebase_import_mapping, codebase_id: 'cb123', entity_type: 'User')

      expect do
        create(:codebase_import_mapping, codebase_id: 'cb123', entity_type: 'User')
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows same codebase_id with different entity_type' do
      create(:codebase_import_mapping, codebase_id: 'cb123', entity_type: 'User')

      expect do
        create(:codebase_import_mapping, codebase_id: 'cb123', entity_type: 'Ticket')
      end.not_to raise_error
    end
  end

  describe 'JSON mapping_data' do
    let(:mapping_data) do
      {
        'action' => 'imported',
        'original_data' => {
          'name' => 'John Doe',
          'email' => 'john@example.com',
          'role' => 'developer'
        },
        'import_timestamp' => '2025-07-14T12:00:00Z',
        'notes' => 'Imported successfully'
      }
    end

    let(:mapping) { create(:codebase_import_mapping, mapping_data: mapping_data) }

    it 'stores and retrieves JSON data correctly' do
      expect(mapping.mapping_data).to eq(mapping_data)
      expect(mapping.mapping_data['action']).to eq('imported')
      expect(mapping.mapping_data['original_data']['name']).to eq('John Doe')
    end

    it 'handles nested JSON structures' do
      expect(mapping.mapping_data.dig('original_data', 'email')).to eq('john@example.com')
    end
  end
end
