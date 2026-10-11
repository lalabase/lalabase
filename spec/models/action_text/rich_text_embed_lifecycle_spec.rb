# frozen_string_literal: true

require 'rails_helper'

# What:  An image embedded in a rich text (ActionText `embeds`) follows the carrier through
#        the deletion chain, the deletion register and the orphan purge.
# Type:  Model/integration guard (spike S1, 2026-08-23).
# Why:   doc/inline_bilder_spike_plan.md, findings F1 to F3: all three already work, but
#        nothing pinned them. Before images become a product feature of ticket texts, the
#        data-protection promises (AVV § 12) need a guard that breaks when one of the
#        three links changes: `has_rich_text` dependent destroy, the RichText carrier
#        resolution in AttachmentDeletionRecorder, and UnattachedBlobPurgeJob's grace period.
RSpec.describe 'Rich text embed lifecycle' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  around do |example|
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = adapter_was
  end

  def image_blob(filename: 'shot.png')
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("\x89PNG\r\n\x1a\n#{'x' * 64}"), filename: filename, content_type: 'image/png'
    )
  end

  def embed_html(blob, text: 'Schritt 1')
    %(<div>#{text}</div><action-text-attachment sgid="#{blob.attachable_sgid}"></action-text-attachment>)
  end

  def ticket_with(blob)
    create(:ticket, project: project, organisation: organisation, content: embed_html(blob))
  end

  describe 'F1: deletion chain' do
    it 'attaches the blob to the rich text as an embed on save' do
      blob = image_blob
      ticket = ticket_with(blob)

      expect(ticket.content.embeds.map(&:blob)).to eq([blob])
    end

    it 'destroys rich text, attachment and blob with the ticket' do
      blob = image_blob
      ticket = ticket_with(blob)
      rich_text_id = ticket.content.id

      perform_enqueued_jobs { ticket.destroy! }

      expect(ActionText::RichText.exists?(rich_text_id)).to be(false)
      expect(ActiveStorage::Attachment.where(blob_id: blob.id)).to be_empty
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    end
  end

  describe 'F2: deletion register' do
    it 'records the embed under the carrier of the rich text, with its organisation' do
      blob = image_blob(filename: 'ablauf.png')
      ticket = ticket_with(blob)

      expect { perform_enqueued_jobs { ticket.destroy! } }
        .to change(AttachmentDeletionRecord, :count).by(1)

      entry = AttachmentDeletionRecord.last
      expect(entry.record_type).to eq('Ticket')
      expect(entry.organisation_id).to eq(organisation.id)
      expect(entry.filename).to eq('ablauf.png')
      expect(entry.storage_key).to eq(blob.key)
    end
  end

  describe 'F3: image removed from the text' do
    it 'leaves an unattached blob that the purge job sweeps after the grace period' do
      blob = image_blob
      ticket = ticket_with(blob)

      ticket.update!(content: '<div>nur noch Text</div>')

      expect(ActiveStorage::Attachment.where(blob_id: blob.id)).to be_empty
      expect(ActiveStorage::Blob.unattached).to include(blob)

      blob.update_column(:created_at, (UnattachedBlobPurgeJob::GRACE_PERIOD + 1.day).ago)
      perform_enqueued_jobs { UnattachedBlobPurgeJob.perform_now }

      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    end

    it 'leaves a freshly removed image alone (open drafts may still reference it)' do
      blob = image_blob
      ticket = ticket_with(blob)
      ticket.update!(content: '<div>nur noch Text</div>')

      perform_enqueued_jobs { UnattachedBlobPurgeJob.perform_now }

      expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
    end
  end
end
