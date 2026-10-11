# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Duplicate Ticket Import Prevention', type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:import_session_id) { SecureRandom.uuid }

  let(:ticket_data) do
    {
      id: '12345',
      number: 42,
      subject: 'Test Ticket',
      summary: 'Test Summary',
      status_cache: 'Open',
      priority_cache: 'Normal',
      created_at: '2023-01-01T10:00:00Z',
      updated_at: '2023-01-01T10:00:00Z',
      updates: []
    }
  end

  let(:status_mappings) do
    {
      'Open' => 'open'
    }
  end

  let(:priority_mappings) do
    {
      'Normal' => 'normal'
    }
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe 'TicketCreator duplicate prevention' do
    let(:ticket_creator) do
      CodebaseImport::TicketCreator.new(
        project: project,
        organisation: organisation,
        user: user,
        status_mappings: status_mappings,
        priority_mappings: priority_mappings,
        import_session_id: import_session_id
      )
    end

    context 'when ticket has not been imported before' do
      it 'creates a new ticket' do
        expect do
          ticket_creator.create(ticket_data)
        end.to change(Ticket, :count).by(1)
                                     .and change(CodebaseImportMapping, :count).by(1)
      end
    end

    context 'when ticket has already been imported' do
      let!(:existing_ticket) do
        ticket = nil
        expect do
          ticket = ticket_creator.create(ticket_data)
        end.to change(Ticket, :count).by(1)
        ticket
      end

      it 'returns the existing ticket without creating a duplicate' do
        # Create another TicketCreator instance to simulate a second import
        second_creator = CodebaseImport::TicketCreator.new(
          project: project,
          organisation: organisation,
          user: user,
          status_mappings: status_mappings,
          priority_mappings: priority_mappings,
          import_session_id: SecureRandom.uuid # Different session
        )

        expect do
          returned_ticket = second_creator.create(ticket_data)
          expect(returned_ticket.id).to eq(existing_ticket.id)
          expect(returned_ticket.number).to eq(existing_ticket.number)
        end.to change(Ticket, :count).by(0)
                                     .and change(CodebaseImportMapping, :count).by(0)
      end

      it 'logs that the ticket was already imported' do
        allow(Rails.logger).to receive(:debug)

        second_creator = CodebaseImport::TicketCreator.new(
          project: project,
          organisation: organisation,
          user: user,
          status_mappings: status_mappings,
          priority_mappings: priority_mappings,
          import_session_id: SecureRandom.uuid
        )

        second_creator.create(ticket_data)

        expect(Rails.logger).to have_received(:debug).with(/Ticket already imported/)
        expect(Rails.logger).to have_received(:debug).with(/Found existing ticket/)
      end
    end

    context 'when mapping exists but ticket was deleted' do
      let!(:stale_mapping) do
        CodebaseImportMapping.create!(
          codebase_id: ticket_data[:id].to_s,
          entity_type: 'Ticket',
          local_id: SecureRandom.uuid # Non-existent ticket ID
        )
      end

      it 'removes stale mapping and creates new ticket' do
        expect do
          ticket_creator.create(ticket_data)
        end.to change(Ticket, :count).by(1)
                                     .and change(CodebaseImportMapping, :count).by(0) # Deletes one, creates one

        # Verify the stale mapping was replaced
        mapping = CodebaseImportMapping.find_by(
          codebase_id: ticket_data[:id].to_s,
          entity_type: 'Ticket'
        )
        expect(Ticket.exists?(mapping.local_id)).to be true
      end
    end
  end

  describe 'TicketImporter duplicate prevention' do
    let(:import_file) do
      file = create(:codebase_import_file, organisation: organisation, user: user, file_type: 'tickets')
      allow(file).to receive(:parsed_data).and_return(tickets_data)
      file
    end
    let(:tickets_data) { [ticket_data, ticket_data.merge(id: '67890', number: 43, subject: 'Another Ticket')] }

    let(:ticket_importer) do
      CodebaseImport::TicketImporter.new(
        import_file,
        project,
        { 'Open' => { 'action' => 'create' } },
        { 'Normal' => { 'action' => 'create' } },
        user
      )
    end

    it 'skips already imported tickets' do
      # First import
      result1 = ticket_importer.call
      puts "Import failed with error: #{result1.error}" unless result1.success?
      expect(result1.success?).to be true
      expect(Ticket.count).to eq(2)

      # Second import with same data
      result2 = ticket_importer.call
      expect(result2.success?).to be true
      expect(Ticket.count).to eq(2) # No new tickets created

      # Check import summary includes skipped count
      summary = ticket_importer.send(:import_tickets, tickets_data, {
                                       statuses: status_mappings,
                                       priorities: priority_mappings
                                     })
      expect(summary[:skipped_tickets]).to eq(2)
      expect(summary[:imported_tickets]).to eq(0)
    end

    context 'with tag import enabled' do
      let(:ticket_importer_with_tags) do
        CodebaseImport::TicketImporter.new(
          import_file,
          project,
          { 'Open' => { 'action' => 'create' } },
          { 'Normal' => { 'action' => 'create' } },
          user,
          include_tags: true
        )
      end

      let(:tickets_with_tags) do
        [
          ticket_data.merge(tags: 'bug urgent'),
          ticket_data.merge(id: '67890', number: 43, subject: 'Another Ticket', tags: 'feature')
        ]
      end

      it 'skips already imported tickets even with tags' do
        # First import with tags
        result1 = ticket_importer_with_tags.send(:import_tickets_with_tags, tickets_with_tags, {
                                                   statuses: status_mappings,
                                                   priorities: priority_mappings
                                                 })
        expect(result1[:imported_tickets]).to eq(2)
        expect(Tag.count).to eq(3) # bug, urgent, feature

        # Second import should skip all tickets
        result2 = ticket_importer_with_tags.send(:import_tickets_with_tags, tickets_with_tags, {
                                                   statuses: status_mappings,
                                                   priorities: priority_mappings
                                                 })
        expect(result2[:imported_tickets]).to eq(0)
        expect(result2[:skipped_tickets]).to eq(2)
        expect(Ticket.count).to eq(2) # No new tickets
        expect(Tag.count).to eq(3) # No new tags
      end
    end
  end

  describe 'Race condition handling' do
    it 'handles unique constraint violation gracefully' do
      # This simulates what happens when two imports try to create the same mapping
      ticket_creator = CodebaseImport::TicketCreator.new(
        project: project,
        organisation: organisation,
        user: user,
        status_mappings: status_mappings,
        priority_mappings: priority_mappings
      )

      # First create succeeds
      ticket1 = ticket_creator.create(ticket_data)
      expect(ticket1).to be_persisted

      # Simulate race condition by manually creating another mapping with same codebase_id
      # In real scenario, this would be another process trying to import simultaneously
      expect do
        CodebaseImportMapping.create!(
          codebase_id: ticket_data[:id].to_s,
          entity_type: 'Ticket',
          local_id: SecureRandom.uuid
        )
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'a Codebase ticket another organisation imported' do
    it 'is imported for this organisation and leaves the other mapping alone' do
      other = create(:organisation)
      foreign_ticket = ActsAsTenant.with_tenant(other) do
        create(:ticket, organisation: other, project: create(:project, organisation: other), creator: user).tap do |record|
          CodebaseImportMapping.create!(codebase_id: ticket_data[:id], local_id: record.id, entity_type: 'Ticket')
        end
      end
      creator = CodebaseImport::TicketCreator.new(
        project: project, organisation: organisation, user: user,
        status_mappings: status_mappings, priority_mappings: priority_mappings, import_session_id: import_session_id
      )

      ticket = creator.create(ticket_data)

      expect(ticket.project).to eq(project)
      expect(CodebaseImportMapping.find_by!(codebase_id: ticket_data[:id], entity_type: 'Ticket').local_id).to eq(ticket.id)
      ActsAsTenant.with_tenant(other) do
        expect(CodebaseImportMapping.find_local_id(ticket_data[:id], 'Ticket')).to eq(foreign_ticket.id)
      end
    end
  end
end
