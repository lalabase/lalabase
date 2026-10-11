# frozen_string_literal: true

require 'rails_helper'

# Actors::DestroyDocument — destroys a document with ALL of its versions.
#
# Intent per test: prove the cascade (versions + fragments + attachments) runs
# through the version callbacks (no delete_all shortcut that would orphan blobs),
# that current_version is nulled first so the FK does not block the delete, and
# that any mid-cascade failure rolls the whole delete back (nothing deleted).
RSpec.describe Actors::DestroyDocument, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # Destroying a document with several attached versions fans out one attachment
  # blob purge + PurgeJob per version at commit time (ActiveStorage's own
  # dependent: :purge_later — a wanted callback per D4: few versions, no batch).
  # That bounded fanout fires in an after_commit stack we do not own, so Prosopite
  # is paused around the destroy: these examples assert the cascade BEHAVIOUR, not
  # a query budget. Mirrors the Prosopite.pause the DestroyPost spec uses for the
  # equivalent bounded attachment fanout.
  def call_and_settle(actor)
    Prosopite.pause
    actor.call
  ensure
    Prosopite.resume
  end

  # A document with two versions; the newer one is the current_version.
  def build_document_with_versions
    doc = create(:document, project: project, organisation: organisation, creator: user)
    old_version = create(:document_version, document: doc, organisation: organisation, title: 'v1')
    current = create(:document_version, document: doc, organisation: organisation, title: 'v2')
    doc.update!(current_version: current)
    [doc, old_version, current]
  end

  describe '#record' do
    it 'is nil — a destroy leaves no surviving primary record' do
      doc, = build_document_with_versions
      expect(described_class.new(document: doc, current_user: user).record).to be_nil
    end
  end

  describe '#call' do
    context 'happy path' do
      subject(:actor) { described_class.new(document: document, current_user: user) }

      let!(:setup) { build_document_with_versions }
      let(:document) { setup[0] }

      it 'destroys the document' do
        expect { call_and_settle(actor) }.to change(Document, :count).by(-1)
      end

      it 'destroys ALL of its versions (current + old)' do
        expect { call_and_settle(actor) }.to change(DocumentVersion, :count).by(-2)
      end

      it 'returns a successful Result with resource nil' do
        result = call_and_settle(actor)
        expect(result).to be_success
        expect(result.resource).to be_nil
        expect(result.errors).to be_empty
      end
    end

    context 'with fragments on a version (embedding cleanup via callbacks)' do
      subject(:actor) { described_class.new(document: document, current_user: user) }

      let(:setup) { build_document_with_versions }
      let(:document) { setup[0] }

      before do
        current = setup[2]
        create(:fragment, fragmentable: current, organisation: organisation)
        create(:fragment, fragmentable: current, organisation: organisation)
      end

      it 'destroys the version fragments via dependent: :destroy (no delete_all orphans)' do
        expect { call_and_settle(actor) }.to change(Fragment, :count).by(-2)
      end
    end

    context 'with an attached version file' do
      subject(:actor) { described_class.new(document: document, current_user: user) }

      let!(:setup) { build_document_with_versions }
      let(:document) { setup[0] }

      it 'purges the version attachments (records removed, blob purge scheduled)' do
        # The factory attaches a file to each version, so destroying both
        # versions must remove both attachment rows.
        expect { call_and_settle(actor) }.to change(ActiveStorage::Attachment, :count).by(-2)
      end
    end

    context 'rollback when the final destroy fails' do
      subject(:actor) { described_class.new(document: document, current_user: user) }

      let(:setup) { build_document_with_versions }
      let(:document) { setup[0] }

      before do
        # The versions are destroyed inside the transaction BEFORE the document
        # itself; failing the document destroy must roll everything back — the
        # already-destroyed versions and the current_version nulling included.
        # RecordNotDestroyed is an unexpected error, so BaseActor re-raises it in
        # dev/test.
        allow(document).to receive(:destroy!).and_raise(
          ActiveRecord::RecordNotDestroyed.new('boom', document)
        )
      end

      it 're-raises the unexpected error in dev/test' do
        expect { call_and_settle(actor) }.to raise_error(ActiveRecord::RecordNotDestroyed)
      end

      it 'leaves the document and every version intact (full rollback)' do
        expect { call_and_settle(actor) }.to raise_error(ActiveRecord::RecordNotDestroyed)

        expect(Document.where(id: document.id)).to exist
        expect(DocumentVersion.where(document_id: document.id).count).to eq(2)
        expect(document.reload.current_version).to be_present
      end
    end
  end
end
