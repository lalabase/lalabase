# frozen_string_literal: true

# What: S1 of doc/fragment_einbettung_entkopplung_plan.md — full-text search must not
#   depend on the AI pipeline.
# Type: Service spec across the WRITE path (EmbeddingProcessingService) and the READ path
#   (CombinedSearchService), because the defect lives in the seam between them and neither
#   side shows it alone.
# Why (philosophy): `create_fragment` runs AFTER `generate_embedding` and wraps the Fragment
#   and its ContentEmbedding sidecar in ONE transaction, justified by the comment "a fragment
#   without a vector is invisible to every reader since PR 4b". That is wrong for the
#   full-text reader: `search_full_text_german` is a pg_search_scope against
#   `plain_text_content` with no join to content_embeddings. The consequence is measured, not
#   theoretical — on 2026-08-30 production held 69 posts with no fragment at all, 43 of them
#   from a transient HTTP 429. A rate limit is a "come back later"; here it permanently cost
#   the post its searchability, on a lane that never needed AI in the first place.
# Contract: content is findable by FULL TEXT whether or not its embedding succeeded, and
#   whether or not the organisation ever opted into AI. The semantic lane keeps its existing
#   fail-soft behaviour: no vector, no semantic hit, no error.
#
# ⚠️ FAILING-FIRST. Every example below is red on the pre-split code and describes the
# behaviour S2/S3 must deliver. Do not "fix" them by weakening the assertion.

require 'rails_helper'

RSpec.describe 'Full-text search survives an AI outage' do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:project) { create(:project, organisation: organisation) }
  let(:standard_role) do
    create(:role, title: 'Standard User', organisation: organisation, is_default: true)
  end
  # A member with real read access to the project, built the way
  # combined_search_service_spec builds one. Without the membership AND the
  # ProjectPermission, CombinedSearchService#apply_access_filter short-circuits to
  # `.none` and every search example here would pass or fail for the wrong reason.
  let(:user) do
    u = create(:user)
    create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    create(:project_permission, user: u, project: project, tickets_access: 'read_only')
    u
  end
  let(:fake_embedding) { Array.new(1536) { rand(-1.0..1.0) } }

  let(:embed_provider) do
    instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil,
                                                   embed_with_usage: { embedding: fake_embedding, total_tokens: 10 },
                                                   provider_name: 'openai',
                                                   default_embedding_model: 'text-embedding-3-small',
                                                   expected_embedding_dims: 1536)
  end

  # The needle is deliberately a word no factory default contains, so a hit can only come
  # from the note this spec wrote.
  let(:needle) { 'Quastenflosser' }

  # ⚠️ `content`, not `plain_text_version`. Note#before_save derives the plain text from
  # the rich text (`self.plain_text_version = content&.to_plain_text`), so a factory value
  # passed to the column is overwritten before it ever reaches the indexer — the first
  # draft of this spec indexed the factory default "Test Content" and every search example
  # failed for a reason that had nothing to do with the code under test.
  def note_with_needle
    create(:note, project: project, organisation: organisation, creator: user,
                  create_embeddings: true,
                  content: "Ein Protokoll über den #{needle} und seine Flossen.")
  end

  # The full-text half of the real search path, with no query embedding — exactly what
  # PowerSearchService passes once Lalabase::QueryEmbedding.embed has failed.
  def fulltext_hits_for(record)
    CombinedSearchService.new(
      organisation: organisation, query: needle, embedding: nil,
      current_user: user, limit: 15
    ).call.select { |fragment| fragment.fragmentable == record }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = user
  end

  around do |example|
    ActsAsTenant.with_tenant(organisation) { example.run }
  end

  describe 'when the embedding provider is rate limiting us (HTTP 429)' do
    before do
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
      allow(embed_provider).to receive(:embed_with_usage)
        .and_raise(Lalabase::Llm::Provider::RateLimitError, 'the server responded with status 429')
    end

    it 'still writes the fragment, so the content stays in the full-text index' do
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      expect(note.fragments.reload).not_to be_empty
    end

    it 'is findable by full text through the real search path' do
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      expect(fulltext_hits_for(note)).not_to be_empty
    end

    # The other half of the contract: the fragment exists WITHOUT a vector, and that is a
    # legitimate state rather than a broken one. If this ever fails, someone re-coupled the
    # two by writing a placeholder vector, which would poison the semantic lane instead.
    it 'writes no sidecar vector for it' do
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      fragment_ids = note.fragments.reload.map(&:id)
      # The `not_to be_empty` first is load-bearing, not decoration: without it this example
      # passes vacuously on the pre-split code, where there is no fragment and therefore
      # trivially no vector. It has to assert the STATE "fragment, no vector", not the
      # absence of both.
      expect(fragment_ids).not_to be_empty
      expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: fragment_ids)).to be_empty
    end

    # A rate limit is not a defect, it is a "come back later". The record has to stay on the
    # pending list so a catch-up picks it up; if it were marked done, the vector would never
    # be written and only a human pressing a button could repair it.
    it 'leaves the record pending rather than marking it processed' do
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      expect(note.reload.embeddings_creation_flag).not_to be(true)
      expect(Embeddings::PendingEmbeddings.relations_by_model[Note]).to include(note)
    end
  end

  describe 'when the organisation never opted into AI' do
    let(:organisation) { create(:organisation, ai_enabled: false) }

    # The larger half of the defect. Extraction is local text processing; nothing leaves the
    # system, so the GDPR opt-in has nothing to say about it. Today the AI gate stops the
    # whole pipeline and such an organisation has no searchable posts or notes at all.
    it 'still indexes the content for full text' do
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      expect(note.fragments.reload).not_to be_empty
    end

    it 'is findable by full text' do
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      expect(fulltext_hits_for(note)).not_to be_empty
    end

    # The gate that must NOT move: no content of an AI-off organisation may reach a provider.
    it 'sends nothing to an embedding provider' do
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      expect(embed_provider).not_to have_received(:embed_with_usage)
    end

    it 'writes no sidecar vector' do
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      fragment_ids = note.fragments.reload.map(&:id)
      # The `not_to be_empty` first is load-bearing, not decoration: without it this example
      # passes vacuously on the pre-split code, where there is no fragment and therefore
      # trivially no vector. It has to assert the STATE "fragment, no vector", not the
      # absence of both.
      expect(fragment_ids).not_to be_empty
      expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: fragment_ids)).to be_empty
    end
  end

  # Review finding 1. The reuse branch decides whether a fragment still needs embedding,
  # and "has a sidecar row" is the WRONG question: Embeddings::NearestNeighbors reads on
  # the full triple AND `indexed`, so a row in a retired space, or one whose `indexed` was
  # cleared, exists while being invisible to every search. Asked the weak way, unchanged
  # text after a model switch re-embeds nothing, the record is marked done, and
  # Embeddings::PendingEmbeddings never hands it out again — a one-way door.
  describe 'when the existing vector cannot actually be read' do
    before { allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider) }

    def embed_once
      note = note_with_needle
      EmbeddingProcessingService.new(note).process
      note
    end

    it 're-embeds a fragment whose only row sits in another vector space' do
      note = embed_once
      ContentEmbedding.where(embeddable_type: 'Fragment',
                             embeddable_id: note.fragments.reload.map(&:id))
                      .update_all(embedding_model: 'text-embedding-3-large')
      note.update_columns(embeddings_creation_flag: false)

      expect { EmbeddingProcessingService.new(note.reload).process }
        .to change(ContentEmbedding, :count).by(note.fragments.count)
      expect(note.reload.embeddings_creation_flag).to be(true)
    end

    # A de-indexed row sits in the SAME (type, id, triple) slot the write targets, so the
    # repair is an update, not an insert. The property is "the fragment ends up readable
    # again", and asserting a row COUNT here would have been asserting the mechanism —
    # it is how the first draft of this example failed against a correct implementation.
    it 'makes a de-indexed row readable again instead of leaving it retired' do
      note = embed_once
      rows = ContentEmbedding.where(embeddable_type: 'Fragment',
                                    embeddable_id: note.fragments.reload.map(&:id))
      rows.update_all(indexed: false)
      note.update_columns(embeddings_creation_flag: false)

      expect { EmbeddingProcessingService.new(note.reload).process }
        .not_to change(ContentEmbedding, :count)
      expect(rows.reload.pluck(:indexed)).to all(be(true))
      expect(note.reload.embeddings_creation_flag).to be(true)
    end

    # The other direction, so the fix cannot be "always re-embed": a readable row in the
    # space we are writing into is still a reason to do nothing.
    it 'leaves a readable row alone' do
      note = embed_once
      note.update_columns(embeddings_creation_flag: false)

      expect { EmbeddingProcessingService.new(note.reload).process }
        .not_to change(ContentEmbedding, :count)
    end
  end

  # Review finding 2. Reuse means two concurrent runs share fragment ids, and
  # idx_content_embeddings_unique_space is unique over (type, id, provider, model, dims)
  # with no model-level validation behind it — so the loser of the race used to get a raw
  # RecordNotUnique, which #handle_embedding_error turned into a permanent red "Es sind
  # Fehler aufgetreten" over a run that had in fact succeeded.
  describe 'when another run embedded the same fragment first' do
    before { allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider) }

    # ⚠️ The first draft of this example stubbed ContentEmbedding.create! and was VACUOUS:
    # #attach_embedding is an upsert and calls save! on an instance, so the stub was never
    # reached. It stayed green when the rescue under test was deleted, which is the exact
    # opposite of what it claims. Stub the seam the code actually uses.
    it 'treats the duplicate as done instead of recording a failure' do
      note = note_with_needle
      EmbeddingProcessingService.new(note).process
      note.update_columns(embeddings_creation_flag: false)
      ContentEmbedding.where(embeddable_type: 'Fragment',
                             embeddable_id: note.fragments.reload.map(&:id)).update_all(indexed: false)

      # The loser of the race: the row it read is gone by the time it saves, because the
      # winner inserted the same (type, id, triple) slot in between.
      allow(ContentEmbedding).to receive(:find_or_initialize_by) do
        instance_double(ContentEmbedding).tap do |row|
          allow(row).to receive(:assign_attributes)
          allow(row).to receive(:save!)
            .and_raise(ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint')
        end
      end

      expect { EmbeddingProcessingService.new(note.reload).process }.not_to raise_error
      expect(note.reload.embedding_creation_error).to be_blank
    end
  end

  # The regression direction: the happy path must keep both halves. A split that forgot to
  # embed would pass every example above and be worse than what it replaced.
  describe 'when everything works' do
    before do
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
    end

    it 'writes the fragment AND its vector' do
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      fragment_ids = note.fragments.reload.map(&:id)
      expect(fragment_ids).not_to be_empty
      expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: fragment_ids)).not_to be_empty
    end

    it 'marks the record processed' do
      note = note_with_needle

      EmbeddingProcessingService.new(note).process

      expect(note.reload.embeddings_creation_flag).to be(true)
    end
  end
end
