# frozen_string_literal: true

require 'rails_helper'

# Actors::DestroyDocumentVersion — deletes ONE version with three success
# outcomes. Intent per test: prove the current_version is preserved for a
# non-current delete, correctly re-hung to the next-newest (created_at desc) when
# the current one goes, and that deleting the LAST version tears the whole
# document down (document_destroyed? true, record nil). A foreign/missing
# version_id must become a :not_found failure (F2), never a raise; a validation
# failure while re-hanging must roll everything back.
RSpec.describe Actors::DestroyDocumentVersion, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # A document with `count` versions ordered oldest -> newest by created_at; the
  # newest is the current_version. created_at is set explicitly on create so
  # "next-newest" is unambiguous even when the rows are built in the same tick.
  # Returns [document, versions_oldest_first, current_version].
  #
  # Prosopite is paused around the CREATION only: making several versions each
  # fires the version's own after_update_commit Turbo broadcast (one blob/doc
  # lookup per version) — a test-setup artifact, not a production path (versions
  # are created one at a time). The actor call under test stays under scrutiny.
  def document_with_versions(count)
    Prosopite.pause
    doc = create(:document, project: project, organisation: organisation, creator: user)
    versions = Array.new(count) do |i|
      # (count - i).days.ago: v1 oldest … vN newest.
      create(:document_version, document: doc, organisation: organisation, title: "v#{i + 1}",
                                created_at: (count - i).days.ago)
    end
    doc.update!(current_version: versions.last)
    [doc, versions, versions.last]
  ensure
    Prosopite.resume
  end

  describe '#call — outcome (a): delete a non-current version' do
    it 'destroys only that version, keeps the current_version and the document' do
      document, versions, = document_with_versions(2)
      non_current = versions.first

      actor = described_class.new(document: document, version_id: non_current.id, current_user: user)
      result = actor.call

      expect(result).to be_success
      expect(actor.document_destroyed?).to be(false)
      expect(actor.record).to eq(document)
      expect(DocumentVersion.where(id: non_current.id)).not_to exist
      expect(document.reload.current_version).to eq(versions.last)
    end
  end

  describe '#call — outcome (b): delete the current version with others present' do
    it 'promotes the next-newest (created_at desc) to current_version, then drops the old one' do
      document, versions, current = document_with_versions(3)

      actor = described_class.new(document: document, version_id: current.id, current_user: user)
      result = actor.call

      expect(result).to be_success
      expect(actor.document_destroyed?).to be(false)
      expect(DocumentVersion.where(id: current.id)).not_to exist
      # versions = [v1(oldest), v2, v3(current)] -> next-newest is v2.
      expect(document.reload.current_version).to eq(versions[1])
    end
  end

  describe '#call — outcome (c): delete the last remaining version' do
    it 'destroys the whole document (document_destroyed? true, record nil)' do
      document, versions, = document_with_versions(1)
      last = versions.first

      actor = described_class.new(document: document, version_id: last.id, current_user: user)
      result = actor.call

      expect(result).to be_success
      expect(actor.document_destroyed?).to be(true)
      expect(actor.record).to be_nil
      expect(Document.where(id: document.id)).not_to exist
      expect(DocumentVersion.where(id: last.id)).not_to exist
    end
  end

  describe '#call — (d): a foreign or missing version_id' do
    it 'fails with :not_found for an unknown id (no raise, nothing deleted)' do
      document, = document_with_versions(2)

      actor = described_class.new(document: document, version_id: SecureRandom.uuid, current_user: user)
      result = actor.call

      expect(result).not_to be_success
      expect(result.code).to eq(:not_found)
      expect(result.errors).to include(I18n.t('services.actors.destroy_document_version.not_found'))
      expect(document.reload.document_versions.count).to eq(2)
    end

    it 'fails with :not_found for a version that belongs to a different document' do
      document, = document_with_versions(1)
      other_doc, other_versions, = document_with_versions(1)

      actor = described_class.new(document: document, version_id: other_versions.first.id, current_user: user)
      result = actor.call

      expect(result).not_to be_success
      expect(result.code).to eq(:not_found)
      # The foreign version is untouched.
      expect(DocumentVersion.where(id: other_versions.first.id)).to exist
      expect(other_doc.reload.current_version).to eq(other_versions.first)
    end
  end

  describe '#call — (e): a validation failure while re-hanging the current version' do
    it 'returns a failure and rolls everything back (nothing deleted)' do
      document, _versions, current = document_with_versions(3)
      # Force the promote step to blow up; the whole transaction must roll back.
      allow(document).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(document))

      actor = described_class.new(document: document, version_id: current.id, current_user: user)
      result = actor.call

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(DocumentVersion.where(document_id: document.id).count).to eq(3)
    end
  end
end
