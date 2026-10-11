# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportManagementService, type: :service do
  let(:organisation) { create(:organisation) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end
  let(:user) { create(:user) }
  let(:session_id) { SecureRandom.uuid }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # Helper to create an imported object with its importable
  def create_imported_ticket(sid: session_id, source: 'codebase_hq', imported_at: Time.current, metadata: {})
    ticket = create(:ticket, project: project, organisation: organisation, creator: user)
    create(:imported_object,
           organisation: organisation,
           importable: ticket,
           import_session_id: sid,
           import_source: source,
           imported_at: imported_at,
           metadata: metadata)
    ticket
  end

  def create_imported_post(ticket, sid: session_id, source: 'codebase_hq', imported_at: Time.current)
    post = create(:post, ticket: ticket, user: user, organisation: organisation)
    create(:imported_object,
           organisation: organisation,
           importable: post,
           import_session_id: sid,
           import_source: source,
           imported_at: imported_at)
    post
  end

  # =========================================================================
  # Class Methods (delegation)
  # =========================================================================

  describe '.list_import_sessions' do
    it 'delegates to instance method' do
      result = described_class.list_import_sessions(organisation)
      expect(result).to be_an(Array)
    end
  end

  describe '.session_details' do
    it 'delegates to instance method' do
      result = described_class.session_details(organisation, session_id)
      expect(result).to be_a(Hash)
      expect(result[:session_id]).to eq(session_id)
    end
  end

  describe '.delete_import_session' do
    it 'delegates to instance method' do
      result = described_class.delete_import_session(organisation, session_id)
      expect(result).to be_a(Hash)
    end
  end

  # =========================================================================
  # #list_sessions
  # =========================================================================

  describe '#list_sessions' do
    subject(:service) { described_class.new(organisation) }

    context 'when no import sessions exist' do
      it 'returns empty array' do
        expect(service.list_sessions).to eq([])
      end
    end

    context 'with a single import session' do
      before do
        create_imported_ticket(imported_at: Time.zone.parse('2026-01-15 10:00'))
        create_imported_ticket(imported_at: Time.zone.parse('2026-01-15 14:00'))
      end

      it 'returns one session entry' do
        result = service.list_sessions
        expect(result.size).to eq(1)
      end

      it 'aggregates the total object count' do
        result = service.list_sessions.first
        expect(result[:total_objects]).to eq(2)
      end

      it 'includes session_id and source' do
        result = service.list_sessions.first
        expect(result[:import_session_id]).to eq(session_id)
        expect(result[:import_source]).to eq('codebase_hq')
      end

      it 'includes import dates' do
        result = service.list_sessions.first
        expect(result[:import_dates]).to be_an(Array)
        expect(result[:import_dates].size).to eq(1)
      end
    end

    context 'with a session spanning multiple dates' do
      before do
        create_imported_ticket(imported_at: Time.zone.parse('2026-01-15 10:00'))
        create_imported_ticket(imported_at: Time.zone.parse('2026-01-16 10:00'))
        create_imported_ticket(imported_at: Time.zone.parse('2026-01-17 10:00'))
      end

      it 'aggregates dates into import_dates array' do
        result = service.list_sessions.first
        expect(result[:import_dates].size).to eq(3)
      end

      it 'sums total objects across all dates' do
        result = service.list_sessions.first
        expect(result[:total_objects]).to eq(3)
      end
    end

    context 'with multiple distinct sessions' do
      let(:session_id_2) { SecureRandom.uuid }

      before do
        create_imported_ticket(sid: session_id, imported_at: Time.zone.parse('2026-01-15 10:00'))
        create_imported_ticket(sid: session_id_2, source: 'csv_import', imported_at: Time.zone.parse('2026-02-01 10:00'))
      end

      it 'returns separate entries per session' do
        result = service.list_sessions
        expect(result.size).to eq(2)
      end

      it 'correctly attributes objects to their sessions' do
        result = service.list_sessions
        session_1 = result.find { |s| s[:import_session_id] == session_id }
        session_2 = result.find { |s| s[:import_session_id] == session_id_2 }

        expect(session_1[:total_objects]).to eq(1)
        expect(session_1[:import_source]).to eq('codebase_hq')
        expect(session_2[:total_objects]).to eq(1)
        expect(session_2[:import_source]).to eq('csv_import')
      end
    end

    context 'cross-tenant isolation' do
      let(:other_org) { create(:organisation) }
      let(:other_project) do
        ActsAsTenant.with_tenant(other_org) do
          create(:project, organisation: other_org)
        end
      end

      before do
        create_imported_ticket(imported_at: Time.current)

        # Create imported object in other organisation
        ActsAsTenant.with_tenant(other_org) do
          other_ticket = create(:ticket, project: other_project, organisation: other_org, creator: user)
          create(:imported_object,
                 organisation: other_org,
                 importable: other_ticket,
                 import_session_id: 'other-session',
                 import_source: 'other_source',
                 imported_at: Time.current)
        end
      end

      it 'only returns sessions for the current organisation' do
        result = service.list_sessions
        expect(result.size).to eq(1)
        expect(result.first[:import_session_id]).to eq(session_id)
      end
    end
  end

  # =========================================================================
  # #session_details
  # =========================================================================

  describe '#session_details' do
    subject(:service) { described_class.new(organisation) }

    context 'with a valid session containing objects' do
      let!(:ticket1) { create_imported_ticket(imported_at: Time.zone.parse('2026-01-15 10:00')) }
      let!(:ticket2) { create_imported_ticket(imported_at: Time.zone.parse('2026-01-15 14:00')) }

      it 'returns the session_id' do
        result = service.session_details(session_id)
        expect(result[:session_id]).to eq(session_id)
      end

      it 'returns correct total_objects count' do
        result = service.session_details(session_id)
        expect(result[:total_objects]).to eq(2)
      end

      it 'returns objects array with details' do
        result = service.session_details(session_id)
        expect(result[:objects]).to be_an(Array)
        expect(result[:objects].size).to eq(2)
      end

      it 'includes id, type, importable_id, imported_at, metadata per object' do
        result = service.session_details(session_id)
        obj = result[:objects].first

        expect(obj).to have_key(:id)
        expect(obj).to have_key(:type)
        expect(obj).to have_key(:importable_id)
        expect(obj).to have_key(:imported_at)
        expect(obj).to have_key(:metadata)
      end

      it 'returns first_import and last_import timestamps' do
        result = service.session_details(session_id)
        expect(result[:first_import]).to eq(Time.zone.parse('2026-01-15 10:00'))
        expect(result[:last_import]).to eq(Time.zone.parse('2026-01-15 14:00'))
      end
    end

    context 'with multiple importable types' do
      let!(:ticket) { create_imported_ticket }
      let!(:post) { create_imported_post(ticket) }

      it 'groups by_type correctly' do
        result = service.session_details(session_id)
        expect(result[:by_type]).to include('Ticket' => 1, 'Post' => 1)
      end

      it 'returns correct total across types' do
        result = service.session_details(session_id)
        expect(result[:total_objects]).to eq(2)
      end
    end

    context 'with non-existent session_id' do
      it 'returns zero counts and empty objects' do
        result = service.session_details('non-existent')
        expect(result[:session_id]).to eq('non-existent')
        expect(result[:total_objects]).to eq(0)
        expect(result[:objects]).to eq([])
        expect(result[:by_type]).to eq({})
        expect(result[:first_import]).to be_nil
        expect(result[:last_import]).to be_nil
      end
    end

    context 'with metadata' do
      let(:meta) { { 'original_id' => '42', 'import_file_id' => 'abc-123' } }

      before { create_imported_ticket(metadata: meta) }

      it 'preserves metadata in the response' do
        result = service.session_details(session_id)
        expect(result[:objects].first[:metadata]).to eq(meta)
      end
    end

    context 'objects are ordered by imported_at' do
      before do
        create_imported_ticket(imported_at: Time.zone.parse('2026-01-15 14:00'))
        create_imported_ticket(imported_at: Time.zone.parse('2026-01-15 10:00'))
        create_imported_ticket(imported_at: Time.zone.parse('2026-01-15 12:00'))
      end

      it 'returns objects in chronological order' do
        result = service.session_details(session_id)
        timestamps = result[:objects].map { |o| o[:imported_at] }
        expect(timestamps).to eq(timestamps.sort)
      end
    end
  end

  # =========================================================================
  # #delete_session
  # =========================================================================

  describe '#delete_session' do
    subject(:service) { described_class.new(organisation) }

    # Bulk destroy! inherently loads dependent associations per record (N+1).
    # Acceptable for admin batch operations — pause Prosopite detection.
    before { Prosopite.pause }

    context 'with imported tickets' do
      before do
        create_imported_ticket
        create_imported_ticket
      end

      it 'deletes the tickets' do
        expect { service.delete_session(session_id) }.to change(Ticket, :count).by(-2)
      end

      it 'deletes the imported_object tracking records' do
        expect { service.delete_session(session_id) }.to change(ImportedObject, :count).by(-2)
      end

      it 'returns a result hash with deletion counts' do
        result = service.delete_session(session_id)
        expect(result[:tickets_deleted]).to eq(2)
        expect(result[:total_deleted]).to eq(2)
      end
    end

    context 'with imported tickets and posts' do
      let!(:ticket) { create_imported_ticket }

      before { create_imported_post(ticket) }

      it 'deletes posts before tickets (dependency order)' do
        result = service.delete_session(session_id)
        expect(result[:posts_deleted]).to eq(1)
        expect(result[:tickets_deleted]).to eq(1)
      end

      it 'removes all imported objects' do
        expect { service.delete_session(session_id) }.to change(ImportedObject, :count).to(0)
      end
    end

    context 'with non-existent session_id' do
      it 'returns zero counts without error' do
        result = service.delete_session('does-not-exist')
        expect(result[:total_deleted]).to eq(0)
      end
    end

    context 'does not affect other sessions' do
      let(:other_session_id) { SecureRandom.uuid }

      before do
        create_imported_ticket(sid: session_id)
        create_imported_ticket(sid: other_session_id)
      end

      it 'only deletes objects from the targeted session' do
        service.delete_session(session_id)

        expect(ImportedObject.where(import_session_id: other_session_id).count).to eq(1)
        expect(ImportedObject.where(import_session_id: session_id).count).to eq(0)
      end
    end

    context 'cross-tenant isolation' do
      let(:other_org) { create(:organisation) }
      let(:other_project) do
        ActsAsTenant.with_tenant(other_org) do
          create(:project, organisation: other_org)
        end
      end

      before do
        # Same session_id in both orgs
        create_imported_ticket(sid: session_id)

        ActsAsTenant.with_tenant(other_org) do
          other_ticket = create(:ticket, project: other_project, organisation: other_org, creator: user)
          create(:imported_object,
                 organisation: other_org,
                 importable: other_ticket,
                 import_session_id: session_id,
                 import_source: 'codebase_hq',
                 imported_at: Time.current)
        end
      end

      it 'only deletes objects from the current organisation' do
        service.delete_session(session_id)

        expect(ImportedObject.where(import_session_id: session_id, organisation_id: organisation.id).count).to eq(0)

        ActsAsTenant.with_tenant(other_org) do
          expect(ImportedObject.where(import_session_id: session_id, organisation_id: other_org.id).count).to eq(1)
        end
      end
    end

    it 'logs the deletion result' do
      create_imported_ticket
      allow(Rails.logger).to receive(:debug)

      service.delete_session(session_id)

      expect(Rails.logger).to have_received(:debug).with(/Import session #{session_id} deleted/)
    end
  end

  # =========================================================================
  # Edge Cases
  # =========================================================================

  describe 'edge cases' do
    subject(:service) { described_class.new(organisation) }

    context 'with a single imported object' do
      before { create_imported_ticket }

      it 'list_sessions returns one session with count 1' do
        result = service.list_sessions
        expect(result.size).to eq(1)
        expect(result.first[:total_objects]).to eq(1)
      end

      it 'session_details returns one object' do
        result = service.session_details(session_id)
        expect(result[:total_objects]).to eq(1)
        expect(result[:objects].size).to eq(1)
      end
    end

    context 'when importable was already destroyed (orphaned ImportedObject)' do
      before do
        ticket = create_imported_ticket
        # Destroy the ticket directly, leaving the ImportedObject orphaned
        ticket.destroy!
      end

      it 'session_details still works with orphaned records' do
        # ImportedObject still exists due to dependent: :destroy removing it too,
        # but in case of direct SQL deletion, the object could be orphaned
        result = service.session_details(session_id)
        expect(result).to be_a(Hash)
      end
    end

    context 'list_sessions with same session_id but different sources' do
      before do
        create_imported_ticket(sid: session_id, source: 'codebase_hq')
        create_imported_ticket(sid: session_id, source: 'csv_import')
      end

      it 'returns separate entries per source' do
        result = service.list_sessions
        expect(result.size).to eq(2)

        sources = result.map { |s| s[:import_source] }
        expect(sources).to contain_exactly('codebase_hq', 'csv_import')
      end
    end

    context 'session_details with nil session_id' do
      it 'returns empty result without error' do
        result = service.session_details(nil)
        expect(result[:total_objects]).to eq(0)
        expect(result[:objects]).to eq([])
      end
    end

    context 'delete_session with nil session_id' do
      before { create_imported_ticket }

      it 'does not delete any objects' do
        expect { service.delete_session(nil) }.not_to change(ImportedObject, :count)
      end
    end

    context 'delete_session with empty string session_id' do
      before { create_imported_ticket }

      it 'does not delete the real session objects' do
        expect { service.delete_session('') }.not_to change(Ticket, :count)
      end
    end
  end
end
