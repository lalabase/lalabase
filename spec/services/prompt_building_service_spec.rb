# frozen_string_literal: true

require 'rails_helper'

# PromptBuildingService had NO spec before embedding v2 PR 4b — which made it the
# one migrated read call site with no behavioural pin at all
# (doc/embedding_v2_pr4b_read_switch_plan.md §6.4). It builds a German assistant
# prompt from the org's semantically closest fragments, and its whole error
# behaviour is one broad `rescue StandardError` that degrades to a context-free
# prompt instead of failing the chat.
#
# Intent per block: that relevant content actually reaches the context (now via the
# content_embeddings sidecar), that the degradation path stays intact (it now also
# catches query-object errors), and that the context never crosses org boundaries —
# this is the only call site with no project or asker gate, so the org filter is its
# ONLY boundary.
RSpec.describe PromptBuildingService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:query_vector) { unit_vector(0) }

  before do
    ActsAsTenant.current_tenant = organisation
    stub_default_embedding_space
    pin_exact_vector_scans
    allow(Lalabase::QueryEmbedding).to receive(:embed).and_return(query_vector)
  end

  after { ActsAsTenant.current_tenant = nil }

  def unit_vector(position)
    Array.new(1536, 0.0).tap { |v| v[position] = 1.0 }
  end

  def vector_with_similarity(similarity)
    Array.new(1536, 0.0).tap do |v|
      v[0] = similarity
      v[1] = Math.sqrt(1.0 - (similarity**2))
    end
  end

  # Fragment as production has it: the record plus the sidecar row the reader queries.
  def embedded_fragment(vector, content, org: organisation, mirror: true)
    ActsAsTenant.with_tenant(org) do
      owner_project = org == organisation ? project : create(:project, organisation: org)
      ticket = create(:ticket, project: owner_project, organisation: org, creator: user)
      fragment = create(:fragment, fragmentable: ticket, organisation: org,
                                   plain_text_content: content)
      seed_sidecar_embedding(fragment, vector: vector) if mirror
      fragment
    end
  end

  def prompt_for(question = 'Wie ist der Stand beim Login-Bug?')
    described_class.new(question, organisation).call
  end

  describe 'happy path (context from the sidecar)' do
    it 'folds the closest fragments into the context section' do
      embedded_fragment(query_vector, 'Reproduktionsschritte fuer den Login-Bug')

      prompt = prompt_for
      expect(prompt).to include('Kontext:')
      expect(prompt).to include('Reproduktionsschritte fuer den Login-Bug')
      expect(prompt).to include('Wie ist der Stand beim Login-Bug?')
    end

    it 'orders the context by distance (closest fragment first)' do
      embedded_fragment(vector_with_similarity(0.3), 'entfernter treffer')
      embedded_fragment(vector_with_similarity(1.0), 'naechster treffer')

      prompt = prompt_for
      expect(prompt.index('naechster treffer')).to be < prompt.index('entfernter treffer')
    end

    it 'caps the context at RELEVANT_FRAGMENTS_LIMIT fragments (n+1 boundary)' do
      (described_class::RELEVANT_FRAGMENTS_LIMIT + 1).times do |i|
        embedded_fragment(vector_with_similarity(1.0 - (i * 0.01)), "treffer #{i}")
      end

      prompt = prompt_for
      included = (0..described_class::RELEVANT_FRAGMENTS_LIMIT).count { |i| prompt.include?("treffer #{i}") }
      expect(included).to eq(described_class::RELEVANT_FRAGMENTS_LIMIT)
    end

    it 'yields an empty context section when nothing is embedded (no crash)' do
      prompt = prompt_for
      expect(prompt).to include('Kontext:')
      expect(prompt).to include('Wie ist der Stand beim Login-Bug?')
    end

    it 'ignores a fragment without a sidecar row (backfill gap, sheet §5.1)' do
      embedded_fragment(query_vector, 'gespiegelt')
      embedded_fragment(vector_with_similarity(0.99), 'nicht gespiegelt', mirror: false)

      prompt = prompt_for
      expect(prompt).to include('gespiegelt')
      expect(prompt).not_to include('nicht gespiegelt')
    end

    it 'locks RELEVANT_FRAGMENTS_LIMIT as contract (was an inline magic number)' do
      expect(described_class::RELEVANT_FRAGMENTS_LIMIT).to eq(15)
    end
  end

  describe 'degradation (the broad rescue must keep chat alive)' do
    it 'falls back to a context-free prompt when the embedding provider raises' do
      allow(Lalabase::QueryEmbedding).to receive(:embed)
        .and_raise(Lalabase::Llm::Provider::AuthError.new('unauthorised'))

      prompt = prompt_for
      expect(prompt).not_to include('Kontext:')
      expect(prompt).to include('Wie ist der Stand beim Login-Bug?')
    end

    it 'falls back when the vector-space resolution has no credential' do
      # embedding_space_for resolves a credential and can raise — after the switch
      # the rescue has to cover the READ too, not only the embedding call.
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .and_raise(Lalabase::Llm::Factory::MissingCredentialError.new('no creds'))

      expect { prompt_for }.not_to raise_error
      expect(prompt_for).not_to include('Kontext:')
    end

    it 'falls back when the org quota is exhausted' do
      allow(Lalabase::QueryEmbedding).to receive(:embed).and_raise(Lalabase::Llm::QuotaExceededError)
      expect(prompt_for).not_to include('Kontext:')
    end
  end

  describe 'organisation isolation (the org filter is the ONLY boundary here)' do
    it 'never pulls a fragment of another organisation into the context' do
      other_org = create(:organisation)
      embedded_fragment(query_vector, 'eigener inhalt')
      embedded_fragment(query_vector, 'fremder inhalt', org: other_org)

      prompt = prompt_for
      expect(prompt).to include('eigener inhalt')
      expect(prompt).not_to include('fremder inhalt')
    end

    it 'keeps the boundary without the acts_as_tenant default scope' do
      other_org = create(:organisation)
      embedded_fragment(query_vector, 'eigener inhalt')
      embedded_fragment(query_vector, 'fremder inhalt', org: other_org)

      prompt = ActsAsTenant.without_tenant { prompt_for }
      expect(prompt).to include('eigener inhalt')
      expect(prompt).not_to include('fremder inhalt')
    end
  end
end
