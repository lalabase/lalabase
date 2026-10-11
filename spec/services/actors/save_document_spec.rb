# frozen_string_literal: true

# spec/services/actors/save_document_spec.rb

require 'rails_helper'

RSpec.describe Actors::SaveDocument, type: :service do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:uploaded_file) do
    fixture_file_upload('spec/fixtures/files/test_file.txt', 'text/plain')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  # Standard valid params matching the controller's document_params structure
  let(:valid_params) do
    {
      document_versions_attributes: {
        '0' => {
          'title' => 'Test Document',
          'description' => 'A test description',
          'document_version_file' => uploaded_file,
          'create_summary' => false
        }
      }
    }
  end

  describe '#initialize' do
    it 'builds a document scoped to the project and organisation' do
      actor = described_class.new(project: project, params: valid_params, current_user: user)

      expect(actor.record).to be_a(Document)
      expect(actor.record.project).to eq(project)
      expect(actor.record.organisation).to eq(organisation)
      expect(actor.record).not_to be_persisted
    end
  end

  describe '#record' do
    it 'returns the document before call' do
      actor = described_class.new(project: project, params: valid_params, current_user: user)
      expect(actor.record).to be_a(Document)
    end
  end

  describe '#call' do
    subject(:actor) { described_class.new(project: project, params: valid_params, current_user: user) }

    context 'with valid params (happy path)' do
      before do
        # Stub the job to avoid actual processing
        allow(DocumentVersionProcessingJob).to receive(:perform_later)
      end

      it 'returns a successful Result' do
        result = actor.call

        expect(result).to be_success
        expect(result.errors).to be_empty
      end

      it 'persists the document' do
        expect { actor.call }.to change(Document, :count).by(1)
      end

      it 'persists the document version' do
        expect { actor.call }.to change(DocumentVersion, :count).by(1)
      end

      it 'sets the creator to the current user' do
        actor.call
        expect(actor.record.reload.creator).to eq(user)
      end

      it 'records the current user as the version uploader' do
        actor.call
        expect(actor.record.reload.current_version.user).to eq(user)
      end

      # doc/notizen_immer_indexiert_plan.md: the form sends no flag, and the actor must
      # not assign one either (an explicit nil overrode the column's default of true and
      # every new document skipped indexing; review of #778, P1).
      it 'numbers the first version 1' do
        actor.call
        expect(actor.record.reload.current_version.number).to eq(1)
      end

      it 'indexes the version by default, with no flag in the params' do
        actor.call
        expect(actor.record.reload.current_version.create_embeddings).to be(true)
      end

      it 'restores the previous Current.user after the call' do
        Current.user = nil
        actor.call
        expect(Current.user).to be_nil
      end

      it 'assigns the version attributes correctly' do
        actor.call
        version = actor.record.reload.current_version

        expect(version.title).to eq('Test Document')
        expect(version.description).to eq('A test description')
        expect(version.create_embeddings).to be true
        expect(version.create_summary).to be false
        expect(version.document_version_file).to be_attached
      end

      it 'sets current_version on the document' do
        actor.call
        document = actor.record.reload

        expect(document.current_version).to be_present
        expect(document.current_version).to eq(document.document_versions.first)
      end

      it 'returns the document as resource' do
        result = actor.call
        expect(result.resource).to eq(actor.record)
        expect(result.resource).to be_persisted
      end

      it 'enqueues DocumentVersionProcessingJob' do
        actor.call

        expect(DocumentVersionProcessingJob).to have_received(:perform_later)
          .with(an_instance_of(DocumentVersion))
      end
    end

    context 'with optional fields' do
      before do
        allow(DocumentVersionProcessingJob).to receive(:perform_later)
      end

      it 'succeeds without description' do
        valid_params[:document_versions_attributes]['0'].delete('description')
        result = actor.call

        expect(result).to be_success
        expect(actor.record.reload.current_version.description).to be_nil
      end

      it 'ignores a create_embeddings parameter: the version is indexed anyway' do
        valid_params[:document_versions_attributes]['0']['create_embeddings'] = false
        result = actor.call

        expect(result).to be_success
        expect(actor.record.reload.current_version.create_embeddings).to be true
      end

      it 'succeeds with create_summary true' do
        valid_params[:document_versions_attributes]['0']['create_summary'] = true
        result = actor.call

        expect(result).to be_success
        expect(actor.record.reload.current_version.create_summary).to be true
      end
    end

    context 'when document version validation fails (missing title)' do
      let(:invalid_params) do
        {
          document_versions_attributes: {
            '0' => {
              'title' => '',
              'description' => 'No title',
              'document_version_file' => uploaded_file,
              'create_embeddings' => true,
              'create_summary' => false
            }
          }
        }
      end

      subject(:actor) { described_class.new(project: project, params: invalid_params, current_user: user) }

      it 'returns a failure Result' do
        result = actor.call

        expect(result).not_to be_success
      end

      it 'includes validation error messages' do
        result = actor.call

        expect(result.errors).to be_present
      end

      it 'does not persist the document' do
        expect { actor.call }.not_to change(Document, :count)
      end

      it 'does not persist the document version' do
        expect { actor.call }.not_to change(DocumentVersion, :count)
      end

      it 'does not enqueue the processing job' do
        allow(DocumentVersionProcessingJob).to receive(:perform_later)
        actor.call

        expect(DocumentVersionProcessingJob).not_to have_received(:perform_later)
      end
    end

    context 'when document version validation fails (missing file)' do
      let(:no_file_params) do
        {
          document_versions_attributes: {
            '0' => {
              'title' => 'Document without file',
              'description' => 'No file attached',
              'document_version_file' => nil,
              'create_embeddings' => true,
              'create_summary' => false
            }
          }
        }
      end

      subject(:actor) { described_class.new(project: project, params: no_file_params, current_user: user) }

      it 'returns a failure Result' do
        result = actor.call

        expect(result).not_to be_success
      end

      it 'rolls back the transaction — no document persisted' do
        expect { actor.call }.not_to change(Document, :count)
      end
    end

    context 'when document_versions_attributes key is missing' do
      let(:broken_params) { {} }

      subject(:actor) { described_class.new(project: project, params: broken_params, current_user: user) }

      it 'returns a failure Result with clear error message' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors).to include('Missing document version attributes')
      end

      it 'does not persist anything' do
        expect { actor.call }.not_to change(Document, :count)
        expect { actor.call }.not_to change(DocumentVersion, :count)
      end

      it 'does not enqueue the processing job' do
        allow(DocumentVersionProcessingJob).to receive(:perform_later)
        actor.call

        expect(DocumentVersionProcessingJob).not_to have_received(:perform_later)
      end
    end

    context 'when the nested "0" key is missing' do
      let(:missing_zero_params) do
        { document_versions_attributes: {} }
      end

      subject(:actor) { described_class.new(project: project, params: missing_zero_params, current_user: user) }

      it 'returns a failure Result' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors).to be_present
      end

      it 'does not persist anything' do
        expect { actor.call }.not_to change(Document, :count)
      end
    end

    context 'when params is nil' do
      subject(:actor) { described_class.new(project: project, params: nil, current_user: user) }

      it 'returns a failure Result' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors).to be_present
      end
    end

    context 'transaction integrity' do
      it 'rolls back the entire transaction on version validation failure' do
        params_missing_title = {
          document_versions_attributes: {
            '0' => {
              'title' => '',
              'document_version_file' => uploaded_file,
              'create_embeddings' => true,
              'create_summary' => false
            }
          }
        }

        actor = described_class.new(project: project, params: params_missing_title, current_user: user)

        expect { actor.call }.not_to change(Document, :count)
        expect { actor.call }.not_to change(DocumentVersion, :count)
      end
    end

    context 'side effects' do
      before do
        allow(DocumentVersionProcessingJob).to receive(:perform_later)
      end

      it 'restores Current.user even on failure' do
        Current.user = nil
        broken_actor = described_class.new(project: project, params: {}, current_user: user)
        broken_actor.call

        expect(Current.user).to be_nil
      end

      it 'sets creator even on failure' do
        broken_actor = described_class.new(project: project, params: {}, current_user: user)
        broken_actor.call

        expect(broken_actor.record.creator).to eq(user)
      end
    end
  end

  # Update path: same actor, an `id:` finds the existing document instead of
  # building a new one. title/description delegate to the current version, tags
  # are synced, and no processing job runs (the version content is unchanged).
  describe '#call (update path)' do
    let(:existing_document) do
      doc = create(:document, project: project, organisation: organisation, creator: user)
      version = create(:document_version, document: doc, organisation: organisation,
                                          title: 'Original', description: 'Original description')
      doc.update!(current_version: version)
      doc
    end

    def update_actor(params)
      described_class.new(project: project, params: params, id: existing_document.id, current_user: user)
    end

    it 'finds the existing document (does not build a new one)' do
      existing_document
      expect { update_actor(title: 'x').call }.not_to change(Document, :count)
    end

    it 'writes title and description onto the current version' do
      result = update_actor(title: 'Updated title', description: 'Updated description').call

      expect(result).to be_success
      version = existing_document.reload.current_version
      expect(version.title).to eq('Updated title')
      expect(version.description).to eq('Updated description')
    end

    it 'adds tags from tag_list' do
      update_actor(tag_list: 'alpha, beta').call

      expect(existing_document.reload.tag_list).to contain_exactly('alpha', 'beta')
    end

    it 'removes a tag when tag_list drops it' do
      update_actor(tag_list: 'alpha, beta').call
      update_actor(tag_list: 'alpha').call

      expect(existing_document.reload.tag_list).to contain_exactly('alpha')
    end

    # Boundary: an empty tag_list must clear ALL tags (it flows through the same
    # update path — the historical `if tag_list.present?` guard was a no-op here).
    it 'clears all tags when tag_list is empty' do
      update_actor(tag_list: 'alpha, beta').call
      expect(existing_document.reload.tag_list).not_to be_empty

      update_actor(tag_list: '').call

      expect(existing_document.reload.tag_list).to be_empty
    end

    it 'does not enqueue DocumentVersionProcessingJob on update' do
      allow(DocumentVersionProcessingJob).to receive(:perform_later)

      update_actor(title: 'Updated title').call

      expect(DocumentVersionProcessingJob).not_to have_received(:perform_later)
    end

    context 'when a validation fails (blank title, D6)' do
      it 'returns a failure with code :validation_failed' do
        result = update_actor(title: '').call

        expect(result).not_to be_success
        expect(result.code).to eq(:validation_failed)
      end

      it 'rolls back — the current version keeps its title' do
        update_actor(title: '').call

        expect(existing_document.reload.current_version.title).to eq('Original')
      end
    end

    context 'when the id is foreign or unknown' do
      # find_or_build cannot find it in project.documents, so it builds a NEW
      # document — which, lacking version attributes, fails instead of being
      # created (no silent cross-tenant update, nothing persisted).
      it 'does not update anything and does not persist a new document' do
        actor = described_class.new(project: project, params: { title: 'x' },
                                    id: SecureRandom.uuid, current_user: user)

        expect { actor.call }.not_to change(Document, :count)
        expect(actor.call).not_to be_success
      end
    end
  end
end
