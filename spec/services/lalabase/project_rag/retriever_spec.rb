# frozen_string_literal: true

require 'rails_helper'

# What is left of this file after projekt_chat_abbau, and the shape of the cut is the
# point: it used to test FOUR layers, three of which ran on the single-project path
# (Layer 4 Vision, Layer 3 Capabilities, Layer 1 CodeSymbols) and were paid on every
# question in the per-project chat, "hallo" included. That surface is gone and the
# layers went with it -- an ACCEPTED loss, recorded in the plan: the assistant's five
# code tools return the same citation shapes on demand, so the sources under an answer
# are unchanged and the model decides when to pay for them.
#
# The content layer survives, and its own file (retriever_content_spec.rb) covers it
# in full, including the per-area gate, cross-tenant isolation and CONTENT_TOP_K.
# What belongs HERE is what is true of the retriever regardless of layer: the query
# boundary, the provider seam, and the constants.
RSpec.describe Lalabase::ProjectRag::Retriever do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  # ⚠️ An ASKER WITH REACH is required for the boundary examples below to reach the
  # embedding at all, and that is behaviour worth naming: the org path resolves the
  # asker's per-area projects FIRST and returns without embedding anything when the
  # map is empty. No reach, no embedding call, no cost. The single-project path this
  # cut removed embedded first and gated afterwards.
  let(:asker) do
    u = create(:user)
    create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    create(:project_permission, user: u, project: project, tickets_access: 'read_only')
    u
  end

  let(:chat) { build(:chat, organisation: organisation).tap(&:save!) }

  let(:query_embedding) { Array.new(1536, 0.1) }
  let(:embed_provider) do
    instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil,
                                                   embed_with_usage: { embedding: query_embedding, total_tokens: 5 },
                                                   provider_name: 'openai',
                                                   default_embedding_model: 'text-embedding-3-small')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    stub_default_embedding_space
  end

  after { ActsAsTenant.current_tenant = nil }

  describe 'top-level behaviour' do
    it 'returns an empty Result for a blank query (no embedding call)' do
      result = described_class.new(chat: chat, query: '   ', asker: asker, embed_provider: embed_provider).call

      expect(result).to be_empty
      expect(embed_provider).not_to have_received(:embed_with_usage)
    end

    it 'truncates queries longer than MAX_QUERY_LENGTH before embedding (n+1)' do
      huge = 'a' * (described_class::MAX_QUERY_LENGTH + 1)

      described_class.new(chat: chat, query: huge, asker: asker, embed_provider: embed_provider).call

      expect(embed_provider).to have_received(:embed_with_usage)
        .with(hash_including(text: 'a' * described_class::MAX_QUERY_LENGTH))
    end

    it 'passes a query at EXACTLY MAX_QUERY_LENGTH through unchanged (n boundary)' do
      exact = 'a' * described_class::MAX_QUERY_LENGTH

      described_class.new(chat: chat, query: exact, asker: asker, embed_provider: embed_provider).call

      expect(embed_provider).to have_received(:embed_with_usage).with(hash_including(text: exact))
    end

    it 'passes a query at MAX_QUERY_LENGTH - 1 through unchanged (n-1 boundary)' do
      near = 'a' * (described_class::MAX_QUERY_LENGTH - 1)

      described_class.new(chat: chat, query: near, asker: asker, embed_provider: embed_provider).call

      expect(embed_provider).to have_received(:embed_with_usage).with(hash_including(text: near))
    end
  end

  # ⚠️ The pin that keeps the removal removed at THIS level (the architecture guard
  # says the same thing wholesale). Left as a structural assertion rather than a
  # comment, because a resurrected layer would not fail any other example here: it
  # would simply start costing an embedding per question again.
  describe 'the three code layers are gone with the surface that paid for them' do
    it 'defines none of fetch_vision, fetch_capabilities, fetch_symbols' do
      methods = described_class.private_instance_methods(false) + described_class.instance_methods(false)

      expect(methods).not_to include(:fetch_vision, :fetch_capabilities, :fetch_symbols)
      expect(methods).to include(:org_call, :fetch_org_content)
    end

    it 'has no top-K constant for them either' do
      expect(described_class).not_to be_const_defined(:CAPABILITY_TOP_K)
      expect(described_class).not_to be_const_defined(:SYMBOL_TOP_K)
    end
  end

  it 'embeds nothing at all when the asker has no reach (no map, no cost)' do
    stranger = create(:user)
    create(:membership, user: stranger, organisation: organisation, role: standard_role, active: true)

    described_class.new(chat: chat, query: 'q', asker: stranger, embed_provider: embed_provider).call

    expect(embed_provider).not_to have_received(:embed_with_usage)
  end

  describe 'embed_provider injection' do
    it 'falls back to the Llm::Factory when no provider is injected' do
      allow(Lalabase::Llm::Factory).to receive(:for_feature).and_return(embed_provider)

      described_class.new(chat: chat, query: 'q', asker: asker).call

      expect(Lalabase::Llm::Factory).to have_received(:for_feature).with(:semantic_search, anything, hash_including(space: :active))
    end
  end

  describe 'constants locked as contract' do
    it { expect(described_class::CONTENT_TOP_K).to eq(8) }
    it { expect(described_class::MAX_QUERY_LENGTH).to eq(8000) }

    # Still carries the three CODE types although no layer here produces them any
    # more: the assistant's code tools return the same shapes, and this whitelist is
    # what the renderer (CitationListComponent) and the render-gate read.
    it {
      expect(described_class::CITATION_TYPES)
        .to contain_exactly('vision', 'capability', 'symbol', 'ticket', 'note', 'document', 'post', 'documentation',
                            'meeting', 'meeting_analysis', 'time_report', 'help_page')
    }
    it { expect(described_class::CITATION_TYPES).to be_frozen }
  end
end
