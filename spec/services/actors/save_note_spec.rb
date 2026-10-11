# frozen_string_literal: true

# spec/services/actors/save_note_spec.rb

require 'rails_helper'

RSpec.describe Actors::SaveNote, type: :service do
  include ActiveJob::TestHelper

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  let(:valid_params) do
    {
      title: 'Test Note',
      content: 'Some meaningful content for the note',
      description: 'A brief description',
      create_embeddings: false
    }
  end

  describe '#initialize' do
    context 'when creating a new note (no note_id)' do
      it 'builds a note scoped to the project' do
        actor = described_class.new(project: project, params: valid_params, id: nil, current_user: user)

        expect(actor.record).to be_a(Note)
        expect(actor.record.project).to eq(project)
        expect(actor.record).not_to be_persisted
      end

      it 'assigns params to the built note' do
        actor = described_class.new(project: project, params: valid_params, id: nil, current_user: user)

        expect(actor.record.title).to eq('Test Note')
      end
    end

    context 'when updating an existing note (note_id given)' do
      let!(:existing_note) { create(:note, project: project, organisation: organisation, creator: user) }

      it 'finds the existing note by id' do
        actor = described_class.new(project: project, params: valid_params, id: existing_note.id, current_user: user)

        expect(actor.record).to eq(existing_note)
        expect(actor.record).to be_persisted
      end
    end

    context 'when note_id does not match any note' do
      it 'sets record to nil' do
        actor = described_class.new(project: project, params: valid_params, id: SecureRandom.uuid, current_user: user)

        expect(actor.record).to be_nil
      end
    end
  end

  describe '#call' do
    # ─── CREATE (new note) ─────────────────────────────────────────────

    context 'creating a new note with valid params' do
      subject(:actor) { described_class.new(project: project, params: valid_params, id: nil, current_user: user) }

      before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

      it 'returns a successful Result' do
        result = actor.call

        expect(result).to be_success
        expect(result.errors).to be_empty
      end

      it 'persists the note' do
        expect { actor.call }.to change(Note, :count).by(1)
      end

      it 'sets the creator to the current user' do
        actor.call
        expect(actor.record.reload.creator).to eq(user)
      end

      it 'restores the previous Current.user after the call (no leak)' do
        Current.user = nil
        actor.call
        expect(Current.user).to be_nil
      end

      it 'assigns all attributes correctly' do
        actor.call
        note = actor.record.reload

        expect(note.title).to eq('Test Note')
        expect(note.content.to_plain_text).to eq('Some meaningful content for the note')
        expect(note.description).to eq('A brief description')
        expect(note.create_embeddings).to be false
      end

      it 'returns the note as resource' do
        result = actor.call

        expect(result.resource).to eq(actor.record)
        expect(result.resource).to be_persisted
      end

      it 'extracts plain text and word count via before_save callback' do
        actor.call
        note = actor.record.reload

        expect(note.plain_text_version).to be_present
        expect(note.plain_text_word_count).to be > 0
      end
    end

    context 'creating a note with create_embeddings enabled' do
      let(:embedding_params) { valid_params.merge(create_embeddings: true) }

      subject(:actor) { described_class.new(project: project, params: embedding_params, id: nil, current_user: user) }

      it 'enqueues EmbeddingProcessingJob' do
        allow(EmbeddingProcessingJob).to receive(:perform_later)
        actor.call

        expect(EmbeddingProcessingJob).to have_received(:perform_later).with(
          record_class: Note,
          record_id: actor.record.id,
          fragment_association: :fragments
        )
      end
    end

    context 'creating a note with create_embeddings disabled' do
      let(:no_embedding_params) { valid_params.merge(create_embeddings: false) }

      subject(:actor) { described_class.new(project: project, params: no_embedding_params, id: nil, current_user: user) }

      it 'does not enqueue EmbeddingProcessingJob' do
        allow(EmbeddingProcessingJob).to receive(:perform_later)
        actor.call

        expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
      end
    end

    # ─── CREATE validation failures ────────────────────────────────────

    context 'creating a note with missing title' do
      let(:no_title_params) { valid_params.merge(title: '') }

      subject(:actor) { described_class.new(project: project, params: no_title_params, id: nil, current_user: user) }

      it 'returns a failure Result' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors).to be_present
      end

      it 'does not persist the note' do
        expect { actor.call }.not_to change(Note, :count)
      end
    end

    context 'creating a note with missing content' do
      let(:no_content_params) { valid_params.merge(content: '') }

      subject(:actor) { described_class.new(project: project, params: no_content_params, id: nil, current_user: user) }

      it 'returns a failure Result' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors).to be_present
      end

      it 'does not persist the note' do
        expect { actor.call }.not_to change(Note, :count)
      end
    end

    context 'creating a note with both title and content missing' do
      let(:empty_params) { { title: '', content: '' } }

      subject(:actor) { described_class.new(project: project, params: empty_params, id: nil, current_user: user) }

      it 'returns a failure Result with multiple errors' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors.size).to be >= 2
      end
    end

    # ─── UPDATE (existing note) ────────────────────────────────────────

    context 'updating an existing note with valid params' do
      let!(:existing_note) do
        create(:note, title: 'Original Title', project: project,
                      organisation: organisation, creator: other_user)
      end
      let(:update_params) { { title: 'Updated Title', content: 'Updated content' } }

      subject(:actor) { described_class.new(project: project, params: update_params, id: existing_note.id, current_user: user) }

      before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

      it 'returns a successful Result' do
        result = actor.call

        expect(result).to be_success
      end

      it 'updates the note attributes' do
        actor.call
        existing_note.reload

        expect(existing_note.title).to eq('Updated Title')
        expect(existing_note.content.to_plain_text).to eq('Updated content')
      end

      it 'does not change the creator' do
        actor.call
        existing_note.reload

        expect(existing_note.creator).to eq(other_user)
      end

      it 'does not create a new note' do
        expect { actor.call }.not_to change(Note, :count)
      end

      it 'returns the existing note as resource' do
        result = actor.call

        expect(result.resource).to eq(existing_note)
      end
    end

    context 'updating an existing note with invalid params' do
      let!(:existing_note) do
        create(:note, title: 'Original Title', project: project,
                      organisation: organisation, creator: user)
      end
      let(:invalid_update_params) { { title: '' } }

      subject(:actor) { described_class.new(project: project, params: invalid_update_params, id: existing_note.id, current_user: user) }

      it 'returns a failure Result' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors).to be_present
      end

      it 'does not change the original note' do
        actor.call
        existing_note.reload

        expect(existing_note.title).to eq('Original Title')
      end
    end

    context 'updating a note and enabling embeddings' do
      let!(:existing_note) do
        create(:note, project: project, organisation: organisation,
                      creator: user, create_embeddings: false)
      end
      let(:enable_embedding_params) { { create_embeddings: true } }

      subject(:actor) { described_class.new(project: project, params: enable_embedding_params, id: existing_note.id, current_user: user) }

      it 'enqueues EmbeddingProcessingJob' do
        allow(EmbeddingProcessingJob).to receive(:perform_later)
        actor.call

        expect(EmbeddingProcessingJob).to have_received(:perform_later).with(
          record_class: Note,
          record_id: existing_note.id,
          fragment_association: :fragments
        )
      end
    end

    # ─── EDGE CASES ────────────────────────────────────────────────────

    context 'when note_id does not exist in the database' do
      let(:non_existent_id) { SecureRandom.uuid }

      subject(:actor) { described_class.new(project: project, params: valid_params, id: non_existent_id, current_user: user) }

      it 'returns a failure Result with clear error message' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors).to include('Note not found')
      end

      it 'does not persist anything' do
        expect { actor.call }.not_to change(Note, :count)
      end
    end

    context 'when note belongs to a different organisation' do
      let(:other_organisation) { create(:organisation) }
      let(:other_project) { create(:project, organisation: other_organisation) }
      let!(:other_note) do
        ActsAsTenant.with_tenant(other_organisation) do
          create(:note, project: other_project, organisation: other_organisation,
                        creator: user)
        end
      end

      subject(:actor) { described_class.new(project: project, params: valid_params, id: other_note.id, current_user: user) }

      it 'does not find the note (tenant isolation) and returns clear error' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors).to include('Note not found')
      end
    end

    context 'when description is optional' do
      let(:no_description_params) { valid_params.except(:description) }

      subject(:actor) { described_class.new(project: project, params: no_description_params, id: nil, current_user: user) }

      before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

      it 'creates the note successfully without description' do
        result = actor.call

        expect(result).to be_success
        expect(actor.record.reload.description).to be_nil
      end
    end

    # ─── SIDE EFFECTS ──────────────────────────────────────────────────

    context 'side effects' do
      before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

      it 'restores Current.user even on validation failure' do
        Current.user = nil
        failing_actor = described_class.new(project: project, params: { title: '', content: '' }, current_user: user)
        failing_actor.call

        expect(Current.user).to be_nil
      end

      it 'does not enqueue embedding job on validation failure' do
        failing_actor = described_class.new(project: project, params: { title: '', content: '', create_embeddings: true }, current_user: user)
        failing_actor.call

        expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
      end
    end

    # ─── OPTIMISTIC LOCKING (Finding 4) ────────────────────────────────

    context 'when the note changed concurrently (optimistic locking)' do
      let!(:existing_note) { create(:note, project: project, organisation: organisation, creator: user) }

      before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

      it 'returns a specific stale-object error, not a generic failure' do
        # stale loads the note first (lock_version 0) ...
        stale = described_class.new(project: project, params: { title: 'Stale' }, id: existing_note.id, current_user: user)
        # ... a fresh save in between bumps lock_version in the DB ...
        described_class.new(project: project, params: { title: 'Fresh' }, id: existing_note.id, current_user: user).call
        # ... the stale save then hits the changed version.
        result = stale.call

        expect(result).not_to be_success
        expect(result.errors).to include(I18n.t('services.actors.stale_object'))
      end

      # The REAL parallel-tab path: the form renders a hidden lock_version, so the second
      # tab submits the version IT loaded. Without that field permitted/submitted the actor
      # always reloads the current version and last-write-wins silently. This is the test
      # that proves F1 is wired end-to-end (the one above only covers sub-second in-flight
      # saves, which HTTP does not reproduce).
      it 'rejects a save carrying a stale submitted lock_version' do
        loaded_version = existing_note.lock_version # what the user's tab rendered

        # another tab saves first → the DB lock_version moves on
        described_class.new(project: project, params: { title: 'Saved by another tab' },
                            id: existing_note.id, current_user: user).call
        expect(existing_note.reload.lock_version).to be > loaded_version

        result = described_class.new(
          project: project,
          params: { title: 'My overwrite', lock_version: loaded_version },
          id: existing_note.id, current_user: user
        ).call

        expect(result).not_to be_success
        expect(result.errors).to include(I18n.t('services.actors.stale_object'))
        expect(existing_note.reload.title).to eq('Saved by another tab') # no silent overwrite
      end
    end
  end
end
