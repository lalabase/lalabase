# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImport::TicketCreator do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  let(:status_mappings) { { 'Open' => 'open' } }
  let(:priority_mappings) { { 'High' => 'high' } }

  let(:ticket_data) do
    {
      id: '123',
      number: 1,
      subject: 'Test Ticket',
      description: 'Test Description',
      summary: 'Test Summary',
      status_cache: 'Open',
      priority_cache: 'High',
      reporter_id: '456',
      created_at: '2023-01-01T10:00:00Z',
      updated_at: '2023-01-01T11:00:00Z',
      updates: [
        {
          id: '789',
          content: 'Update comment',
          user_id: '456',
          created_at: '2023-01-01T12:00:00Z',
          updated_at: '2023-01-01T12:00:00Z',
          ticket_changes: {
            'status' => ['Open', 'In Progress']
          }
        }
      ]
    }
  end

  subject(:creator) do
    described_class.new(
      project: project,
      organisation: organisation,
      user: user,
      status_mappings: status_mappings,
      priority_mappings: priority_mappings
    )
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe '#create' do
    it 'creates a ticket with correct attributes' do
      ticket = creator.create(ticket_data)

      expect(ticket).to be_persisted
      expect(ticket.title).to eq('Test Ticket')
      expect(ticket.summary).to eq('Test Summary')
      expect(ticket.content.to_plain_text.strip).to eq('Test Description')
      expect(ticket.custom_attributes['status']).to eq('open')
      expect(ticket.custom_attributes['priority']).to eq('high')
      expect(ticket.creator).to eq(user)
    end

    # Ticket::TITLE_MAX_LENGTH: a longer subject used to be stored and would now
    # stop the import. It is cut instead, visibly.
    it 'cuts a subject over the title bound instead of failing the import' do
      ticket = creator.create(ticket_data.merge(subject: 'x' * (Ticket::TITLE_MAX_LENGTH + 45)))

      expect(ticket).to be_persisted
      expect(ticket.title.length).to eq(Ticket::TITLE_MAX_LENGTH)
      expect(ticket.title).to end_with('…')
    end

    it 'keeps a subject of the bound as it is' do
      subject_at_bound = 'y' * Ticket::TITLE_MAX_LENGTH
      expect(creator.create(ticket_data.merge(subject: subject_at_bound)).title).to eq(subject_at_bound)
    end

    it 'creates import mapping' do
      expect do
        creator.create(ticket_data)
      end.to change { CodebaseImportMapping.count }.by(1)

      mapping = CodebaseImportMapping.last
      expect(mapping.codebase_id).to eq('123')
      expect(mapping.entity_type).to eq('Ticket')
    end

    it 'imports ticket updates as posts' do
      ticket = creator.create(ticket_data)

      expect(ticket.posts.count).to eq(1)

      post = ticket.posts.first
      expect(post.content.to_plain_text).to include('Update comment')
      # Status changes are tracked as activities, not in post content
    end

    context 'when status is not mapped' do
      let(:ticket_data_no_status) { ticket_data.merge(status_cache: 'Unknown') }

      it 'uses original value when status not mapped' do
        ticket = creator.create(ticket_data_no_status)
        # When there's no mapping, it uses the original value
        expect(ticket.custom_attributes['status']).to eq('Unknown')
      end
    end

    context 'when user reference exists' do
      let(:mapped_user) { create(:user) }
      let!(:user_mapping) do
        create(:codebase_import_mapping,
               codebase_id: '456',
               local_id: mapped_user.id,
               entity_type: 'User')
      end

      it 'uses mapped user as creator' do
        ticket = creator.create(ticket_data)
        expect(ticket.creator).to eq(mapped_user)
      end
    end
  end

  describe 'private methods' do
    describe '#resolve_custom_attribute_value' do
      it 'returns mapped status when cache matches' do
        result = creator.send(:resolve_custom_attribute_value, 'status', 'Open')
        expect(result).to eq('open')
      end

      it 'returns nil when cache is blank' do
        result = creator.send(:resolve_custom_attribute_value, 'status', '')
        expect(result).to be_nil
      end
    end

    describe '#parse_timestamp' do
      it 'parses valid timestamp' do
        timestamp = creator.send(:parse_timestamp, '2023-01-01T10:00:00Z')
        expect(timestamp).to be_a(Time)
        expect(timestamp.year).to eq(2023)
      end

      it 'returns current time for invalid timestamp' do
        timestamp = creator.send(:parse_timestamp, 'invalid')
        expect(timestamp).to be_a(Time)
        expect(timestamp).to be_within(1.second).of(Time.current)
      end
    end
  end
end
