# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImport::TimeSessionImporter, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:import_file) do
    create(:codebase_import_file,
           organisation: organisation,
           user: user,
           project: project,
           file_type: 'time_tracking',
           status: 'uploaded',
           metadata: {})
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  # Helper to build time session data hashes matching parsed_data format
  def build_time_session_data(overrides = {})
    {
      id: SecureRandom.random_number(10_000).to_s,
      project_id: '100',
      user_id: '200',
      occurred_on: '2025-06-15',
      minutes: 90,
      summary: 'Worked on feature X',
      ticket_id: nil,
      repository_id: nil,
      commit_ref: nil,
      created_at: '2025-06-15T10:00:00Z',
      updated_at: '2025-06-15T11:30:00Z',
      billed_group_id: nil,
      cached_name: 'Test User',
      cached_email: 'test@example.com',
      ticket_update_id: nil
    }.merge(overrides)
  end

  # ─── INITIALIZATION ────────────────────────────────────────────────

  describe '#initialize' do
    it 'stores import_file, project, organisation, user' do
      importer = described_class.new(import_file, project, user)

      expect(importer.import_file).to eq(import_file)
      expect(importer.project).to eq(project)
      expect(importer.organisation).to eq(organisation)
      expect(importer.user).to eq(user)
    end

    it 'generates a unique import_session_id' do
      importer = described_class.new(import_file, project, user)

      expect(importer.import_session_id).to be_present
      expect(importer.import_session_id).to match(/\A[0-9a-f-]{36}\z/)
    end

    context 'validation errors' do
      it 'raises ValidationError when import_file is nil' do
        expect do
          described_class.new(nil, project, user)
        end.to raise_error(CodebaseImport::TimeSessionImporter::ValidationError)
      end

      it 'raises ValidationError when project is nil' do
        expect do
          described_class.new(import_file, nil, user)
        end.to raise_error(CodebaseImport::TimeSessionImporter::ValidationError)
      end

      it 'raises ValidationError when user is nil' do
        expect do
          described_class.new(import_file, project, nil)
        end.to raise_error(CodebaseImport::TimeSessionImporter::ValidationError)
      end
    end
  end

  # ─── CALL: HAPPY PATH ─────────────────────────────────────────────

  describe '#call' do
    subject(:importer) { described_class.new(import_file, project, user) }

    context 'with a single valid time session' do
      let(:ts_data) { [build_time_session_data(id: '1001', user_id: '200')] }

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        # Create user mapping so the importer can resolve codebase user_id → local user
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'returns a successful ImportResult' do
        result = importer.call

        expect(result).to be_success
        expect(result.imported_count).to eq(1)
        expect(result.skipped_count).to eq(0)
        expect(result.error_count).to eq(0)
      end

      it 'creates a TimeSession' do
        expect { importer.call }.to change(TimeSession, :count).by(1)
      end

      it 'maps attributes correctly' do
        importer.call
        ts = TimeSession.last

        expect(ts.duration).to eq(90)
        expect(ts.description).to eq('Worked on feature X')
        expect(ts.occurred_on.to_date).to eq(Date.parse('2025-06-15'))
        expect(ts.project).to eq(project)
        expect(ts.organisation).to eq(organisation)
        expect(ts.creator).to eq(user)
      end

      it 'creates a CodebaseImportMapping for the time session' do
        expect { importer.call }.to change {
          CodebaseImportMapping.where(entity_type: 'TimeSession').count
        }.by(1)

        mapping = CodebaseImportMapping.find_by(codebase_id: '1001', entity_type: 'TimeSession')
        expect(mapping).to be_present
        expect(mapping.local_id).to eq(TimeSession.last.id)
      end

      it 'creates an ImportedObject for rollback tracking' do
        expect { importer.call }.to change(ImportedObject, :count).by(1)

        imported = ImportedObject.last
        expect(imported.importable).to eq(TimeSession.last)
        expect(imported.import_source).to eq('codebase_time_sessions')
      end
    end

    context 'with multiple time sessions' do
      let(:ts_data) do
        [
          build_time_session_data(id: '1001', user_id: '200', minutes: 30, summary: 'Task A'),
          build_time_session_data(id: '1002', user_id: '200', minutes: 60, summary: 'Task B'),
          build_time_session_data(id: '1003', user_id: '200', minutes: 120, summary: 'Task C')
        ]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'imports all time sessions' do
        result = importer.call

        expect(result).to be_success
        expect(result.imported_count).to eq(3)
      end

      it 'creates 3 TimeSession records' do
        expect { importer.call }.to change(TimeSession, :count).by(3)
      end
    end

    # ─── TICKET ASSOCIATION ────────────────────────────────────────────

    context 'with ticket association' do
      let(:ticket) { create(:ticket, project: project, organisation: organisation) }
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '200', ticket_id: '500')]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
        create(:codebase_import_mapping,
               codebase_id: '500', local_id: ticket.id, entity_type: 'Ticket')
      end

      it 'links the time session to the ticket' do
        importer.call
        ts = TimeSession.last

        expect(ts.ticket).to eq(ticket)
      end
    end

    context 'with ticket_id but no ticket mapping' do
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '200', ticket_id: '999')]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'creates the time session without a ticket' do
        importer.call
        ts = TimeSession.last

        expect(ts.ticket_id).to be_nil
      end

      it 'still returns success' do
        result = importer.call
        expect(result).to be_success
      end
    end

    # ─── BILLED GROUP ──────────────────────────────────────────────────

    context 'with billed_group_id (new group)' do
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '200', billed_group_id: '77')]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'creates a new TimeSessionGroup' do
        expect { importer.call }.to change(TimeSessionGroup, :count).by(1)

        group = TimeSessionGroup.last
        expect(group.name).to eq('Import Group 77')
        expect(group.organisation).to eq(organisation)
      end

      it 'creates a mapping for the new group' do
        importer.call

        mapping = CodebaseImportMapping.find_by(codebase_id: '77', entity_type: 'TimeSessionGroup')
        expect(mapping).to be_present
      end

      it 'creates an ImportedObject for the group' do
        importer.call

        group = TimeSessionGroup.last
        imported = ImportedObject.find_by(importable: group)
        expect(imported).to be_present
        expect(imported.import_source).to eq('codebase_time_sessions')
      end

      it 'links the time session to the new group' do
        importer.call
        ts = TimeSession.last

        expect(ts.time_session_group).to eq(TimeSessionGroup.last)
      end
    end

    context 'with billed_group_id (already mapped)' do
      let(:existing_group) do
        create(:time_session_group, organisation: organisation, creator: user)
      end
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '200', billed_group_id: '77')]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
        create(:codebase_import_mapping,
               codebase_id: '77', local_id: existing_group.id, entity_type: 'TimeSessionGroup')
      end

      it 'reuses the existing group instead of creating a new one' do
        expect { importer.call }.not_to change(TimeSessionGroup, :count)
      end

      it 'links the time session to the existing group' do
        importer.call
        ts = TimeSession.last

        expect(ts.time_session_group).to eq(existing_group)
      end
    end

    context 'with multiple sessions sharing the same billed_group_id' do
      let(:ts_data) do
        [
          build_time_session_data(id: '1001', user_id: '200', billed_group_id: '77'),
          build_time_session_data(id: '1002', user_id: '200', billed_group_id: '77')
        ]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'creates only one TimeSessionGroup for the shared group' do
        expect { importer.call }.to change(TimeSessionGroup, :count).by(1)
      end

      it 'links both sessions to the same group' do
        importer.call
        sessions = TimeSession.last(2)

        expect(sessions.map(&:time_session_group_id).uniq.size).to eq(1)
      end
    end

    # ─── USER MAPPING FALLBACK ─────────────────────────────────────────

    context 'when user mapping is not found' do
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '999')]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        # No user mapping for '999'
      end

      it 'falls back to the import user as creator' do
        importer.call
        ts = TimeSession.last

        expect(ts.creator).to eq(user)
      end

      it 'still returns success' do
        result = importer.call
        expect(result).to be_success
      end
    end

    # ─── DUPLICATE PREVENTION ──────────────────────────────────────────

    context 'when a time session was already imported (duplicate)' do
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '200')]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
        # Simulate already-imported time session
        create(:codebase_import_mapping,
               codebase_id: '1001', local_id: SecureRandom.uuid, entity_type: 'TimeSession')
      end

      it 'skips the duplicate' do
        result = importer.call

        expect(result).to be_success
        expect(result.imported_count).to eq(0)
        expect(result.skipped_count).to eq(1)
      end

      it 'does not create a new TimeSession' do
        expect { importer.call }.not_to change(TimeSession, :count)
      end
    end

    context 'mix of new and already-imported sessions' do
      let(:ts_data) do
        [
          build_time_session_data(id: '1001', user_id: '200'),
          build_time_session_data(id: '1002', user_id: '200')
        ]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
        # Only 1001 was already imported
        create(:codebase_import_mapping,
               codebase_id: '1001', local_id: SecureRandom.uuid, entity_type: 'TimeSession')
      end

      it 'imports only the new one and skips the duplicate' do
        result = importer.call

        expect(result.imported_count).to eq(1)
        expect(result.skipped_count).to eq(1)
      end
    end

    # ─── DATE/DATETIME PARSING ─────────────────────────────────────────

    context 'with invalid date format' do
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '200', occurred_on: 'not-a-date')]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'falls back to Date.current' do
        importer.call
        ts = TimeSession.last

        expect(ts.occurred_on.to_date).to eq(Date.current)
      end
    end

    context 'with blank occurred_on' do
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '200', occurred_on: '')]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'sets occurred_on to nil which causes a validation error counted as error' do
        result = importer.call

        expect(result.error_count).to eq(1)
      end
    end

    context 'with invalid datetime for created_at' do
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '200', created_at: 'garbage')]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'falls back to Time.current and still imports' do
        result = importer.call

        expect(result).to be_success
        expect(result.imported_count).to eq(1)
      end
    end

    context 'with blank summary' do
      let(:ts_data) do
        [build_time_session_data(id: '1001', user_id: '200', summary: nil)]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'uses the default description' do
        importer.call
        ts = TimeSession.last

        expect(ts.description).to eq('Imported from CodebaseHQ')
      end
    end

    # ─── STATUS UPDATES ───────────────────────────────────────────────

    context 'import file status lifecycle' do
      let(:ts_data) { [build_time_session_data(id: '1001', user_id: '200')] }

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'sets status to processed on success' do
        importer.call
        import_file.reload

        expect(import_file.status).to eq('processed')
        expect(import_file.processing_started_at).to be_present
        expect(import_file.processing_completed_at).to be_present
      end

      it 'stores import summary' do
        importer.call
        import_file.reload

        expect(import_file.import_summary).to be_a(Hash)
        expect(import_file.import_summary['imported_time_sessions']).to eq(1)
      end
    end

    # ─── ERROR HANDLING ────────────────────────────────────────────────

    context 'when parsed_data is blank' do
      before do
        allow(import_file).to receive(:parsed_data).and_return([])
      end

      it 'returns a failure ImportResult' do
        result = importer.call

        expect(result).to be_failure
        expect(result.error).to be_present
      end

      it 'sets import file status to failed' do
        importer.call
        import_file.reload

        expect(import_file.status).to eq('failed')
      end
    end

    context 'when parsed_data is nil' do
      before do
        allow(import_file).to receive(:parsed_data).and_return(nil)
      end

      it 'returns a failure ImportResult' do
        result = importer.call

        expect(result).to be_failure
      end
    end

    context 'when individual session creation fails' do
      let(:ts_data) do
        [
          build_time_session_data(id: '1001', user_id: '200', minutes: 90),
          build_time_session_data(id: '1002', user_id: '200', minutes: 0), # invalid: duration must be > 0
          build_time_session_data(id: '1003', user_id: '200', minutes: 60)
        ]
      end

      before do
        allow(import_file).to receive(:parsed_data).and_return(ts_data)
        create(:codebase_import_mapping,
               codebase_id: '200', local_id: user.id, entity_type: 'User')
      end

      it 'continues importing after an error and counts correctly' do
        result = importer.call

        expect(result).to be_success
        expect(result.imported_count).to eq(2)
        expect(result.error_count).to eq(1)
        expect(result.errors).to be_present
      end

      it 'persists the valid sessions' do
        expect { importer.call }.to change(TimeSession, :count).by(2)
      end
    end

    context 'when a general exception occurs during call' do
      before do
        allow(import_file).to receive(:parsed_data).and_raise(StandardError, 'Unexpected DB error')
      end

      it 'returns a failure ImportResult' do
        result = importer.call

        expect(result).to be_failure
        expect(result.error).to eq('Unexpected DB error')
      end

      it 'sets import file status to failed' do
        importer.call
        import_file.reload

        expect(import_file.status).to eq('failed')
        expect(import_file.error_message).to eq('Unexpected DB error')
      end
    end

    # ─── IMPORT RESULT VALUE OBJECT ────────────────────────────────────

    context 'ImportResult' do
      it 'success? returns true when successful' do
        result = described_class::ImportResult.new(success: true, imported_count: 5)

        expect(result).to be_success
        expect(result).not_to be_failure
      end

      it 'failure? returns true when failed' do
        result = described_class::ImportResult.new(success: false, error: 'boom')

        expect(result).to be_failure
        expect(result).not_to be_success
      end

      it 'errors? returns true when error_count > 0' do
        result = described_class::ImportResult.new(success: true, error_count: 2, errors: %w[a b])

        expect(result).to be_errors
      end

      it 'errors? returns false when no errors' do
        result = described_class::ImportResult.new(success: true)

        expect(result).not_to be_errors
      end

      it 'exposes all count attributes' do
        result = described_class::ImportResult.new(
          success: true, imported_count: 10, skipped_count: 3, error_count: 1
        )

        expect(result.imported_count).to eq(10)
        expect(result.skipped_count).to eq(3)
        expect(result.error_count).to eq(1)
      end
    end
  end
  # A Codebase export imported by two organisations carries the same ids. The
  # mappings of one organisation must never resolve in the other: not the
  # ticket, not the billing group, not the user, not the "already imported".
  describe 'mappings of another organisation' do
    let(:other_organisation) { create(:organisation) }
    let!(:foreign) do
      ActsAsTenant.with_tenant(other_organisation) do
        other_user = create(:user)
        other_project = create(:project, organisation: other_organisation)
        records = {
          user: other_user,
          ticket: create(:ticket, organisation: other_organisation, project: other_project, creator: other_user),
          group: create(:time_session_group, organisation: other_organisation, creator: other_user)
        }
        CodebaseImportMapping.create!(codebase_id: '500', local_id: records[:ticket].id, entity_type: 'Ticket')
        CodebaseImportMapping.create!(codebase_id: '77', local_id: records[:group].id, entity_type: 'TimeSessionGroup')
        CodebaseImportMapping.create!(codebase_id: '200', local_id: other_user.id, entity_type: 'User')
        CodebaseImportMapping.create!(codebase_id: '1001', local_id: SecureRandom.uuid, entity_type: 'TimeSession')
        records
      end
    end

    before do
      allow(import_file).to receive(:parsed_data).and_return(
        [build_time_session_data(id: '1001', user_id: '200', ticket_id: '500', billed_group_id: '77')]
      )
    end

    it 'imports the booking without linking it to the other organisation' do
      result = described_class.new(import_file, project, user).call

      expect(result.imported_count).to eq(1)
      booking = TimeSession.find_by!(project: project)
      expect(booking.ticket_id).to be_nil
      expect(booking.creator).to eq(user)
      expect(booking.time_session_group_id).not_to eq(foreign[:group].id)
      expect(booking.time_session_group.organisation).to eq(organisation)
      expect(CodebaseImportMapping.where(codebase_id: '1001', entity_type: 'TimeSession').pluck(:local_id)).to eq([booking.id])
    end
  end
end
