# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CodebaseImport::TagImportService, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:import_session_id) { SecureRandom.uuid }
  let(:service) { described_class.new(organisation, user, import_session_id) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe '#initialize' do
    it 'sets up the service with correct attributes' do
      expect(service.organisation).to eq(organisation)
      expect(service.user).to eq(user)
      expect(service.import_session_id).to eq(import_session_id)
    end
  end

  describe '#parse_tag_string' do
    it 'parses single tag correctly' do
      result = service.send(:parse_tag_string, 'TAG001')
      expect(result).to eq(['tag001'])
    end

    it 'parses multiple tags correctly' do
      result = service.send(:parse_tag_string, 'TAG001 TAG002 TAG003')
      expect(result).to eq(%w[tag001 tag002 tag003])
    end

    it 'handles case insensitive parsing' do
      result = service.send(:parse_tag_string, 'Tag001 TAG002 tag003')
      expect(result).to eq(%w[tag001 tag002 tag003])
    end

    it 'removes duplicates' do
      result = service.send(:parse_tag_string, 'tag001 TAG001 tag001')
      expect(result).to eq(['tag001'])
    end

    it 'handles extra whitespace' do
      result = service.send(:parse_tag_string, '  tag001   tag002  ')
      expect(result).to eq(%w[tag001 tag002])
    end

    it 'handles empty and nil strings' do
      expect(service.send(:parse_tag_string, '')).to eq([])
      expect(service.send(:parse_tag_string, nil)).to eq([])
      expect(service.send(:parse_tag_string, '   ')).to eq([])
    end
  end

  describe '#prepare_tags_from_tickets' do
    let(:tickets_data) do
      [
        { id: '1', subject: 'Ticket 1', tags: 'bug urgent' },
        { id: '2', subject: 'Ticket 2', tags: 'feature nice-to-have' },
        { id: '3', subject: 'Ticket 3', tags: 'bug feature' },
        { id: '4', subject: 'Ticket 4', tags: nil }
      ]
    end

    context 'when no tags exist' do
      it 'creates all new tags' do
        ActsAsTenant.with_tenant(organisation) do
          expect do
            result = service.prepare_tags_from_tickets(tickets_data)

            expect(result).to be_a(CodebaseImport::TagImportResult)
            expect(result.success?).to be true
            expect(result.total_tags_found).to eq(4)
            expect(result.new_tags_created).to eq(4)
            expect(result.existing_tags_reused).to eq(0)
          end.to change(Tag, :count).by(4)
        end
      end

      it 'creates tags with correct attributes' do
        ActsAsTenant.with_tenant(organisation) do
          service.prepare_tags_from_tickets(tickets_data)

          tags = Tag.all
          expect(tags.pluck(:name)).to match_array(%w[bug urgent feature nice-to-have])
          expect(tags.pluck(:organisation_id).uniq).to eq([organisation.id])
        end
      end
    end

    context 'when some tags already exist' do
      let!(:existing_tag) do
        ActsAsTenant.with_tenant(organisation) do
          create(:tag, name: 'bug', organisation: organisation)
        end
      end

      it 'reuses existing tags and creates new ones' do
        ActsAsTenant.with_tenant(organisation) do
          expect do
            result = service.prepare_tags_from_tickets(tickets_data)

            expect(result.success?).to be true
            expect(result.total_tags_found).to eq(4)
            expect(result.new_tags_created).to eq(3) # urgent, feature, nice-to-have
            expect(result.existing_tags_reused).to eq(1) # bug
          end.to change(Tag, :count).by(3)
        end
      end
    end

    context 'with empty ticket data' do
      it 'handles empty array' do
        ActsAsTenant.with_tenant(organisation) do
          result = service.prepare_tags_from_tickets([])

          expect(result.success?).to be true
          expect(result.total_tags_found).to eq(0)
          expect(result.new_tags_created).to eq(0)
        end
      end
    end

    context 'with tickets without tags' do
      let(:tickets_without_tags) do
        [
          { id: '1', subject: 'Ticket 1', tags: nil },
          { id: '2', subject: 'Ticket 2', tags: '' }
        ]
      end

      it 'handles tickets without tags gracefully' do
        ActsAsTenant.with_tenant(organisation) do
          result = service.prepare_tags_from_tickets(tickets_without_tags)

          expect(result.success?).to be true
          expect(result.total_tags_found).to eq(0)
          expect(result.new_tags_created).to eq(0)
        end
      end
    end
  end

  describe '#assign_tags_to_ticket' do
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, organisation: organisation)
      end
    end

    let!(:tags) do
      ActsAsTenant.with_tenant(organisation) do
        [
          create(:tag, name: 'bug', organisation: organisation),
          create(:tag, name: 'urgent', organisation: organisation)
        ]
      end
    end

    before do
      # Build tag cache
      ActsAsTenant.with_tenant(organisation) do
        service.prepare_tags_from_tickets([{ id: '1', tags: 'bug urgent' }])
      end
    end

    it 'assigns tags to ticket correctly' do
      ActsAsTenant.with_tenant(organisation) do
        expect do
          service.assign_tags_to_ticket(ticket, 'bug urgent')
          ticket.reload
        end.to change { ticket.tags.count }.from(0).to(2)

        expect(ticket.tags.pluck(:name)).to match_array(%w[bug urgent])
      end
    end

    it 'handles empty tag string' do
      ActsAsTenant.with_tenant(organisation) do
        expect do
          service.assign_tags_to_ticket(ticket, '')
        end.not_to(change { ticket.tags.count })
      end
    end

    it 'handles nil tag string' do
      ActsAsTenant.with_tenant(organisation) do
        expect do
          service.assign_tags_to_ticket(ticket, nil)
        end.not_to(change { ticket.tags.count })
      end
    end

    it 'logs errors gracefully when ticket assignment fails' do
      ActsAsTenant.with_tenant(organisation) do
        allow(Tagging).to receive(:insert_all!).and_raise(StandardError.new('Assignment failed'))

        # Allow both error log calls
        expect(Rails.logger).to receive(:error).with(/Failed to assign tags/).once
        expect(Rails.logger).to receive(:error).with(/Backtrace:/).once

        service.assign_tags_to_ticket(ticket, 'bug urgent')
      end
    end
  end

  describe '#finalize_tag_tracking' do
    let(:tickets_data) do
      [{ id: '1', subject: 'Ticket 1', tags: 'new-tag existing-tag' }]
    end

    let!(:existing_tag) do
      ActsAsTenant.with_tenant(organisation) do
        create(:tag, name: 'existing-tag', organisation: organisation)
      end
    end

    it 'creates ImportedObject records for newly created tags only' do
      ActsAsTenant.with_tenant(organisation) do
        # Prepare tags (creates new-tag, reuses existing-tag)
        service.prepare_tags_from_tickets(tickets_data)

        # Only for new-tag
        expect do
          result = service.finalize_tag_tracking
          expect(result.success?).to be true
        end.to change(ImportedObject, :count).by(1)

        imported_object = ImportedObject.last
        expect(imported_object.importable_type).to eq('Tag')
        expect(imported_object.importable.name).to eq('new-tag')
        expect(imported_object.import_session_id).to eq(import_session_id)
        expect(imported_object.import_source).to eq('codebase_hq')
        expect(imported_object.metadata['created_during_import']).to be true
      end
    end

    it 'handles case when no new tags were created' do
      ActsAsTenant.with_tenant(organisation) do
        # Only existing tags
        tickets_with_existing_only = [{ id: '1', tags: 'existing-tag' }]
        service.prepare_tags_from_tickets(tickets_with_existing_only)

        expect do
          result = service.finalize_tag_tracking
          expect(result.success?).to be true
        end.not_to change(ImportedObject, :count)
      end
    end
  end

  describe '#import_tags_for_tickets (integration)' do
    let(:tickets_data) do
      [
        { id: '1', subject: 'Ticket 1', tags: 'bug urgent' },
        { id: '2', subject: 'Ticket 2', tags: 'feature' },
        { id: '3', subject: 'Ticket 3', tags: '' }
      ]
    end

    it 'performs complete tag import workflow' do
      ActsAsTenant.with_tenant(organisation) do
        expect do
          result = service.import_tags_for_tickets(tickets_data)

          expect(result).to be_a(CodebaseImport::TagImportResult)
          expect(result.success?).to be true
          expect(result.total_tags_found).to eq(3)
          expect(result.new_tags_created).to eq(3)
        end.to change(Tag, :count).by(3)
                                  .and change(ImportedObject, :count).by(3)
      end
    end
  end

  describe 'error handling' do
    let(:tickets_data) do
      [{ id: '1', subject: 'Ticket 1', tags: 'test-tag' }]
    end

    it 'handles database errors during tag creation' do
      ActsAsTenant.with_tenant(organisation) do
        allow(Tag).to receive(:insert_all!).and_raise(ActiveRecord::RecordInvalid.new)

        expect do
          result = service.prepare_tags_from_tickets(tickets_data)
          expect(result.success?).to be false
          expect(result.has_errors?).to be true
        end.not_to change(Tag, :count)
      end
    end

    it 'handles errors during tracking finalization' do
      ActsAsTenant.with_tenant(organisation) do
        service.prepare_tags_from_tickets(tickets_data)

        allow(ImportedObject).to receive(:insert_all!).and_raise(StandardError.new('Tracking failed'))

        result = service.finalize_tag_tracking
        expect(result.has_errors?).to be true
        expect(result.errors).to include(/Tag tracking finalization failed/)
      end
    end
  end

  describe 'performance characteristics' do
    let(:large_tickets_data) do
      100.times.map do |i|
        {
          id: i.to_s,
          subject: "Ticket #{i}",
          tags: "tag#{i % 10} common-tag special-tag#{i % 5}"
        }
      end
    end

    it 'uses bulk operations for large datasets', :performance do
      ActsAsTenant.with_tenant(organisation) do
        # Mock to verify bulk operations are used
        expect(Tag).to receive(:insert_all!).once
        expect(ImportedObject).to receive(:insert_all!).once

        service.prepare_tags_from_tickets(large_tickets_data)
        service.finalize_tag_tracking
      end
    end
  end
end
