# frozen_string_literal: true

require 'rails_helper'

# What: The deletion register of AVV § 12 Abs. 7 — one entry per attachment that
#       leaves the production system.
# Type: Service + integration spec (the hook is exercised through real destroys,
#       not by calling the service directly, because the hook IS the contract).
# Why:  Two opposite failures are expensive. A missing entry breaks a promise the
#       contract makes to a controller; a raising recorder would create files that
#       can no longer be deleted at all. Both directions are pinned here.
RSpec.describe AttachmentDeletionRecorder do
  let(:organisation) { create(:organisation) }
  # The factory attaches this file itself — deliberately used as-is rather than
  # attaching a second one, because on has_one_attached that would REPLACE the
  # first and produce a deletion of its own.
  let(:document) { create(:ticket_document, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'the entry that Rails automatism produces' do
    it 'records a deletion when the carrier is destroyed' do
      key = document.ticket_document_file.blob.key

      expect { document.destroy! }.to change(AttachmentDeletionRecord, :count).by(1)

      entry = AttachmentDeletionRecord.last
      expect(entry.storage_key).to eq(key)
      expect(entry.filename).to eq('test_document.txt')
      expect(entry.content_type).to eq('text/plain')
      expect(entry.byte_size).to eq('test file content'.bytesize)
      expect(entry.record_type).to eq('TicketDocument')
      expect(entry.deleted_at).to be_present
    end

    it 'records the organisation by id AND by name' do
      document.destroy!

      entry = AttachmentDeletionRecord.last
      expect(entry.organisation_id).to eq(organisation.id)
      expect(entry.organisation_name).to eq(organisation.name)
    end

    it 'never stores file content — only metadata' do
      document.destroy!

      values = AttachmentDeletionRecord.last.attributes.values.map(&:to_s)
      expect(values).to all(satisfy { |value| !value.include?('test file content') })
    end

    # Replacing a file on has_one_attached destroys the old attachment. That is a
    # deletion from the production system like any other and must be recorded.
    it 'records the replaced file when an attachment is overwritten' do
      document

      expect do
        document.ticket_document_file.attach(
          io: StringIO.new('neu'), filename: 'neu.txt', content_type: 'text/plain'
        )
      end.to change(AttachmentDeletionRecord, :count).by(1)

      expect(AttachmentDeletionRecord.last.filename).to eq('test_document.txt')
    end
  end

  # The whole point of the loose reference: the proof must outlive the customer
  # it concerns, because end of contract is exactly when it gets requested.
  describe 'when the organisation itself is deleted' do
    it 'keeps the entry and its denormalised name' do
      document.destroy!
      name = organisation.name

      ActsAsTenant.without_tenant { organisation.destroy }

      entry = AttachmentDeletionRecord.last
      expect(entry).to be_present
      expect(entry.organisation_name).to eq(name)
    end
  end

  describe 'carriers that are out of scope' do
    it 'does not record operator documents (AiCredentialDocument)' do
      credential_document = create(:ai_credential_document)
      credential_document.file.attach(
        io: StringIO.new('dpa'), filename: 'dpa.pdf', content_type: 'application/pdf'
      )

      expect { credential_document.destroy! }.not_to change(AttachmentDeletionRecord, :count)
    end

    it 'keeps the exclusion in ONE place (negative list, not scattered checks)' do
      expect(described_class::EXCLUDED_RECORD_TYPES).to eq(%w[AiCredentialDocument])
    end
  end

  # Rails allows several attachments to share a blob; only the last one going
  # away actually removes the file.
  describe 'when a second attachment holds the same blob' do
    it 'records nothing for the first one' do
      first = document
      blob = first.ticket_document_file.blob
      second = create(:ticket_document, organisation: organisation)
      second.ticket_document_file.attach(blob)

      expect { first.destroy! }.not_to change(AttachmentDeletionRecord, :count)
    end

    it 'records the deletion once the last reference goes' do
      first = document
      blob = first.ticket_document_file.blob
      second = create(:ticket_document, organisation: organisation)
      second.ticket_document_file.attach(blob)
      first.destroy!

      expect { second.destroy! }.to change(AttachmentDeletionRecord, :count).by(1)
    end
  end

  # The defect this register exists to document must not be recreated BY it.
  describe 'when recording fails' do
    it 'still deletes the attachment' do
      document
      allow(AttachmentDeletionRecord).to receive(:create!).and_raise('register unreachable')

      expect { document.destroy! }.not_to raise_error
      expect(TicketDocument.exists?(document.id)).to be(false)
    end

    it 'logs the failure instead of swallowing it silently' do
      document
      allow(AttachmentDeletionRecord).to receive(:create!).and_raise('register unreachable')
      allow(Rails.logger).to receive(:error)

      document.destroy!

      expect(Rails.logger).to have_received(:error).with(/\[deletion_register\] FAILED/)
    end
  end

  describe 'a carrier without a resolvable organisation' do
    it 'writes an entry without one rather than blocking the deletion' do
      export = create(:user_data_export, :completed)

      expect { export.destroy! }.to change(AttachmentDeletionRecord, :count).by(1)

      entry = AttachmentDeletionRecord.last
      expect(entry.organisation_id).to be_nil
      expect(entry.user_id).to eq(export.user_id)
      expect(entry.record_type).to eq('UserDataExport')
    end
  end
end
