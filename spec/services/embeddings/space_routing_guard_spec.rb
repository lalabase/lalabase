# frozen_string_literal: true

require 'rails_helper'

# What this file protects
# -----------------------
# WHICH space each seam resolves — `:active` (what serving reads) vs. `:configured`
# (where new embeddings go). Getting one of them wrong is invisible: no exception, no
# log, just wrong or missing results once the two diverge.
#
# Why it exists (review findings T5/T6/T7, 2026-08-01): swapping `:active` for
# `:configured` in PowerSearchService, SpaceAlignment or JobSupport left the entire
# suite GREEN. Every existing spec stubs the factory to return ONE space for both
# arguments, so the distinction they were written to protect was never exercised. The
# comments in power_search_service.rb and app/services/CLAUDE.md warn about exactly
# this drift — the warning existed, the test did not.
#
# The mechanism here is the point: the factory answers DIFFERENTLY per space, so a
# swapped argument changes the observable result instead of being absorbed.
RSpec.describe 'space routing per seam' do
  let(:organisation) { create(:organisation) }
  let(:active_space) do
    { embedding_provider: 'openai', embedding_model: 'active-model', embedding_dims: 1536 }
  end
  let(:configured_space) do
    { embedding_provider: 'openai', embedding_model: 'configured-model', embedding_dims: 1536 }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
      .with(anything, space: :active).and_return(active_space)
    allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
      .with(anything, space: :configured).and_return(configured_space)
  end

  after { ActsAsTenant.current_tenant = nil }

  def sidecar_row(record, space, indexed: true)
    create(:content_embedding, organisation: organisation, embeddable: record, indexed: indexed,
                               embedding: Array.new(space[:embedding_dims], 0.01), **space)
  end

  # [T5] PowerSearchService resolves the space TWICE — once for the query embedding,
  # once for the re-ranking vectors. Both must be :active, or a similarity is computed
  # between vectors from incompatible spaces: a number without meaning, not an error.
  describe 'PowerSearchService#sidecar_vectors_for' do
    it 'reads vectors from the ACTIVE space' do
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      sidecar_row(fragment, active_space)

      vectors = described_service(fragment)

      expect(vectors.keys).to eq([fragment.id])
    end

    it 'does NOT read vectors from the configured space' do
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      sidecar_row(fragment, configured_space)

      expect(described_service(fragment)).to be_empty
    end

    def described_service(fragment)
      PowerSearchService.new('query', organisation).send(:sidecar_vectors_for, [fragment])
    end
  end

  # [T7] The gate must judge what the READER sees. Pointed at :configured it would
  # report a healthy corpus as broken during a switch — and a broken one as healthy.
  describe 'Embeddings::SpaceAlignment' do
    it 'judges against the ACTIVE space' do
      sidecar_row(create(:fragment, :for_ticket, organisation: organisation), active_space)

      expect(Embeddings::SpaceAlignment.call(organisation: organisation).space).to eq(active_space)
    end
  end

  # [T6] Indexing WRITES, so it must fill the configured space. Pointed at :active it
  # would keep refilling the space being replaced, and the flip's anti-join would never
  # pass — a build that can never finish.
  describe 'Lalabase::Indexer::JobSupport#embedding_provider' do
    it 'resolves the CONFIGURED space' do
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(instance_double(
                                                                             Lalabase::Llm::OpenAiProvider
                                                                           ))
      host = Class.new do
        include Lalabase::Indexer::JobSupport
      end.new

      host.send(:embedding_provider, organisation)

      expect(Lalabase::Llm::Factory).to have_received(:for_embeddings)
        .with(organisation, space: :configured)
    end
  end

  # [R-B, review 2026-08-01] Two more WRITE paths that were still uncovered — the first
  # round of this file only caught the four call sites the review had named.
  #
  # Both are the build side of the staged switch, and pointing either at :active turns
  # the build into a no-op that reports success: EnsureSpace would record a row for the
  # space that is ALREADY serving, build_target would fill it, print "Target space
  # COMPLETE — ready to flip", and the flip would answer `already_active`. The switch
  # never happens and nothing raises.
  describe 'Embeddings::EnsureSpace' do
    it 'records the CONFIGURED triple, not the active one' do
      create(:ai_credential, :active, :embedding_only, provider: 'openai', access_token: 'sk-sys')

      space = Embeddings::EnsureSpace.call(organisation: organisation)

      expect(space.triple).to eq(configured_space)
      expect(space.triple).not_to eq(active_space)
    end
  end

  describe 'Embeddings::OrganisationReindexer#provider' do
    it 'builds its provider for the CONFIGURED space' do
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(instance_double(
                                                                             Lalabase::Llm::OpenAiProvider, provider_name: 'openai',
                                                                                                            default_embedding_model: 'configured-model',
                                                                                                            expected_embedding_dims: 1536
                                                                           ))

      # metered: false — this guard is about which SPACE the provider is built for,
      # not about billing; the unmetered path keeps AiUsage out of the picture.
      Embeddings::OrganisationReindexer.call(organisation: organisation, metered: false)

      expect(Lalabase::Llm::Factory).to have_received(:for_embeddings)
        .with(organisation, space: :configured).at_least(:once)
    end
  end

  # [T6b] Same contract for user content: a post written during a build belongs in the
  # target space, not in the one being retired.
  describe 'EmbeddingProcessingService#embed_provider' do
    it 'resolves the CONFIGURED space' do
      allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(instance_double(
                                                                             Lalabase::Llm::OpenAiProvider
                                                                           ))
      ticket = create(:ticket, project: create(:project, organisation: organisation),
                               organisation: organisation)

      EmbeddingProcessingService.new(ticket).send(:embed_provider)

      expect(Lalabase::Llm::Factory).to have_received(:for_embeddings)
        .with(organisation, space: :configured)
    end
  end
end
