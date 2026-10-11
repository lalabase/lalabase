# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::DestroyPost do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, organisation: organisation, project: project, creator: user) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe '#initialize' do
    # The post is looked up in #perform, not the constructor, so building the
    # actor never raises — even for a missing or nil id.
    it 'builds lazily without looking up or raising' do
      expect { described_class.new(id: SecureRandom.uuid) }.not_to raise_error
      expect { described_class.new(id: nil) }.not_to raise_error
      expect(described_class.new(id: 'whatever')).to be_a(described_class)
    end
  end

  describe '#call when the post does not exist' do
    it 'returns a failure (no raise) for a missing id' do
      result = described_class.new(id: SecureRandom.uuid).call

      expect(result).not_to be_success
      expect(result.errors).to include('Post not found')
    end

    it 'returns a failure for a nil id' do
      result = described_class.new(id: nil).call

      expect(result).not_to be_success
      expect(result.errors).to include('Post not found')
    end
  end

  describe '#call' do
    context 'Happy Path: Post ohne Assoziationen' do
      let!(:post) { create(:post, ticket: ticket, user: user, organisation: organisation) }

      subject { described_class.new(id: post.id) }

      it 'löscht den Post' do
        expect { subject.call }.to change(Post, :count).by(-1)
      end

      it 'gibt ein erfolgreiches Result zurück' do
        result = subject.call
        expect(result).to be_success
      end

      it 'gibt resource: nil zurück' do
        result = subject.call
        expect(result.resource).to be_nil
      end

      it 'enthält keine Fehler' do
        result = subject.call
        expect(result.errors).to be_empty
      end
    end

    context 'Post mit Fragments' do
      let!(:post) { create(:post, ticket: ticket, user: user, organisation: organisation) }
      let!(:fragment1) { create(:fragment, :for_post, fragmentable: post, organisation: organisation) }
      let!(:fragment2) { create(:fragment, :for_post, fragmentable: post, organisation: organisation) }

      subject { described_class.new(id: post.id) }

      it 'löscht alle zugehörigen Fragments via dependent: :destroy' do
        expect { subject.call }.to change(Fragment, :count).by(-2)
      end

      it 'löscht den Post' do
        expect { subject.call }.to change(Post, :count).by(-1)
      end

      it 'gibt ein erfolgreiches Result zurück' do
        result = subject.call
        expect(result).to be_success
      end
    end

    context 'Post mit PostDocuments' do
      let!(:post) { create(:post, ticket: ticket, user: user, organisation: organisation) }

      before do
        Prosopite.pause
        2.times do
          pd = PostDocument.new(post: post, organisation: organisation)
          pd.post_document_file.attach(
            io: StringIO.new('test content'),
            filename: 'test.txt',
            content_type: 'text/plain'
          )
          pd.save!
        end
        Prosopite.resume
      end

      subject { described_class.new(id: post.id) }

      it 'löscht alle zugehörigen PostDocuments via dependent: :destroy' do
        expect { subject.call }.to change(PostDocument, :count).by(-2)
      end

      it 'löscht den Post' do
        expect { subject.call }.to change(Post, :count).by(-1)
      end

      it 'gibt ein erfolgreiches Result zurück' do
        result = subject.call
        expect(result).to be_success
      end
    end

    context 'Post mit Fragments und PostDocuments' do
      let!(:post) { create(:post, ticket: ticket, user: user, organisation: organisation) }
      let!(:fragment) { create(:fragment, :for_post, fragmentable: post, organisation: organisation) }

      before do
        pd = PostDocument.new(post: post, organisation: organisation)
        pd.post_document_file.attach(
          io: StringIO.new('test content'),
          filename: 'test.txt',
          content_type: 'text/plain'
        )
        pd.save!
      end

      subject { described_class.new(id: post.id) }

      it 'löscht alles kaskadierend' do
        expect { subject.call }
          .to change(Post, :count).by(-1)
          .and change(Fragment, :count).by(-1)
          .and change(PostDocument, :count).by(-1)
      end

      it 'gibt ein erfolgreiches Result zurück' do
        result = subject.call
        expect(result).to be_success
      end
    end

    # Sidecar-content_embeddings der PostDocument-Fragmente (embedding v2 PR 2,
    # Delete-Matrix §3.5 Zeile 14): the actor deletes PostDocument fragments via a
    # callback-free Fragment.where(...).delete_all, so Fragment's has_many
    # dependent: :delete_all does NOT fire on them — without the explicit
    # ContentEmbedding.purge_for in delete_post_documents_in_batch their sidecar
    # rows would orphan (mirrors the Meeting PII purge). This pins that purge.
    context 'Sidecar-content_embeddings der PostDocument-Fragmente' do
      let!(:post) { create(:post, ticket: ticket, user: user, organisation: organisation) }

      before do
        Prosopite.pause
        pd = PostDocument.new(post: post, organisation: organisation)
        pd.post_document_file.attach(
          io: StringIO.new('doc content'),
          filename: 'doc.txt',
          content_type: 'text/plain'
        )
        pd.save!
        fragment = create(:fragment, fragmentable: pd, organisation: organisation)
        create(:content_embedding, embeddable: fragment, organisation: organisation)
        Prosopite.resume
      end

      subject { described_class.new(id: post.id) }

      it 'löscht das PostDocument-Fragment und purgt seine Sidecar-Zeile synchron' do
        expect { subject.call }
          .to change(PostDocument, :count).by(-1)
          .and change(Fragment, :count).by(-1)
          .and change(ContentEmbedding, :count).by(-1)
      end

      it 'hinterlässt keine verwaiste Sidecar-Zeile' do
        subject.call
        expect(ContentEmbedding.where(embeddable_type: 'Fragment')).not_to exist
      end
    end

    context 'Fragments anderer Posts bleiben erhalten' do
      let!(:post) { create(:post, ticket: ticket, user: user, organisation: organisation) }
      let!(:other_post) { create(:post, ticket: ticket, user: user, organisation: organisation) }
      let!(:post_fragment) { create(:fragment, :for_post, fragmentable: post, organisation: organisation) }
      let!(:other_fragment) { create(:fragment, :for_post, fragmentable: other_post, organisation: organisation) }

      subject { described_class.new(id: post.id) }

      it 'löscht nur die Fragments des betroffenen Posts' do
        subject.call
        expect(Fragment.where(fragmentable: other_post)).to exist
      end

      it 'lässt den anderen Post intakt' do
        subject.call
        expect(Post.find_by(id: other_post.id)).to be_present
      end
    end

    # RecordNotDestroyed and unexpected errors are not domain ActorErrors, so the
    # BaseActor template re-raises them in dev/test (raise_unexpected? == true);
    # production would log and return a failure Result instead.
    context 'wenn destroy! fehlschlägt (Callback-Abort)' do
      let!(:post) { create(:post, ticket: ticket, user: user, organisation: organisation) }

      subject { described_class.new(id: post.id) }

      before do
        allow(Post).to receive(:find_by).with(id: post.id).and_return(post)
        allow(post).to receive(:destroy!).and_raise(
          ActiveRecord::RecordNotDestroyed.new('Failed to destroy Post', post)
        )
      end

      it 'reicht den Fehler in dev/test durch' do
        expect { subject.call }.to raise_error(ActiveRecord::RecordNotDestroyed)
      end

      it 'behält den Post in der Datenbank (Transaktions-Rollback)' do
        expect { subject.call }.to raise_error(ActiveRecord::RecordNotDestroyed)
        expect(Post.where(id: post.id)).to exist
      end
    end

    context 'bei unerwarteten Fehlern' do
      let!(:post) { create(:post, ticket: ticket, user: user, organisation: organisation) }

      subject { described_class.new(id: post.id) }

      it 'reicht einen unerwarteten Fehler in dev/test durch' do
        allow(Post).to receive(:find_by).with(id: post.id).and_return(post)
        allow(post).to receive(:destroy!).and_raise(StandardError, 'DB connection lost')

        expect { subject.call }.to raise_error(StandardError, 'DB connection lost')
      end
    end

    context 'Tenant-Isolation' do
      let(:other_organisation) { create(:organisation) }
      let!(:post) { create(:post, ticket: ticket, user: user, organisation: organisation) }

      it 'findet den Post nur im aktiven Tenant (sonst failure, kein Raise)' do
        ActsAsTenant.current_tenant = other_organisation

        result = described_class.new(id: post.id).call

        expect(result).not_to be_success
        expect(result.errors).to include('Post not found')
      end
    end
  end
end
