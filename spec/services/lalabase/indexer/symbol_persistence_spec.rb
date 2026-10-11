# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::SymbolPersistence do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:vec) { Array.new(1536, 0.1) }
  let(:embed_provider) do
    instance_double(Lalabase::Llm::OpenAiProvider, provider_name: 'openai',
                                                   default_embedding_model: 'text-embedding-3-small',
                                                   expected_embedding_dims: 1536)
  end

  # The symbol's vector, read where it actually lands since PR 7: the sidecar row
  # keyed to the symbol's pre-generated UUID.
  def sidecar_vector_for(qualified_name)
    symbol = CodeSymbol.find_by(qualified_name: qualified_name)
    ContentEmbedding.find_by(embeddable_type: 'CodeSymbol', embeddable_id: symbol.id).embedding.to_a
  end

  def sym(over = {})
    {
      symbol_type: 'method', name: 'bar', qualified_name: 'Foo#bar', file_path: 'app/foo.rb',
      start_line: 2, end_line: 5, signature: 'def bar; end', language: 'ruby',
      metadata: { 'visibility' => 'public' }
    }.merge(over)
  end

  describe '.persist' do
    it 'returns 0 and makes NO embed/insert call for an empty symbol set' do
      expect(embed_provider).not_to receive(:embed_batch)
      result = nil
      expect { result = described_class.persist(repo: repository, embed_provider: embed_provider, symbols: []) }
        .not_to change(CodeSymbol, :count)
      expect(result).to eq(0)
    end

    it 'embeds the SIGNATURES (not names) and zips embeddings onto rows in order' do
      allow(embed_provider).to receive(:embed_batch).and_return([Array.new(1536, 0.1), Array.new(1536, 0.2)])
      symbols = [sym(qualified_name: 'A', signature: 'sig-A'), sym(qualified_name: 'B', signature: 'sig-B')]

      described_class.persist(repo: repository, embed_provider: embed_provider, symbols: symbols)

      expect(embed_provider).to have_received(:embed_batch).with(texts: %w[sig-A sig-B])
      # The vector reaches the sidecar row keyed to the symbol's pre-generated UUID —
      # the only place it lands since PR 7, so the zip order is proven there.
      expect(sidecar_vector_for('A').first).to eq(0.1)
      expect(sidecar_vector_for('B').first).to eq(0.2)
    end

    it 'maps every contract field onto the row (catches name/qualified_name and provider/model swaps)' do
      allow(embed_provider).to receive(:embed_batch).and_return([vec])
      described_class.persist(repo: repository, embed_provider: embed_provider, symbols: [sym])

      row = CodeSymbol.last
      expect(row).to have_attributes(
        organisation_id: repository.organisation_id,
        project_repository_id: repository.id,
        symbol_type: 'method', name: 'bar', qualified_name: 'Foo#bar',
        file_path: 'app/foo.rb', start_line: 2, end_line: 5,
        signature: 'def bar; end', language: 'ruby'
      )
      expect(row.metadata).to eq('visibility' => 'public')
    end

    it 'defaults metadata to {} when the symbol omits it (NOT NULL / JSONB default contract)' do
      allow(embed_provider).to receive(:embed_batch).and_return([vec])
      described_class.persist(repo: repository, embed_provider: embed_provider, symbols: [sym(metadata: nil)])
      expect(CodeSymbol.last.metadata).to eq({})
    end

    it 'returns the number of rows inserted' do
      allow(embed_provider).to receive(:embed_batch).and_return([vec, vec])
      n = described_class.persist(repo: repository, embed_provider: embed_provider,
                                  symbols: [sym(qualified_name: 'A'), sym(qualified_name: 'B')])
      expect(n).to eq(2)
    end

    it 'scopes inserted rows to the repository organisation (tenant column set explicitly)' do
      allow(embed_provider).to receive(:embed_batch).and_return([vec])
      described_class.persist(repo: repository, embed_provider: embed_provider, symbols: [sym])
      expect(CodeSymbol.last.organisation_id).to eq(repository.organisation_id)
    end

    # Defense in depth: a provider returning fewer vectors than symbols must NOT
    # insert nil-embedding (unsearchable) rows via zip-padding — it must raise.
    it 'raises and inserts nothing when fewer embeddings than symbols are returned' do
      allow(embed_provider).to receive(:embed_batch).and_return([vec]) # 1 vec for 2 symbols
      symbols = [sym(qualified_name: 'A'), sym(qualified_name: 'B')]

      expect { described_class.persist(repo: repository, embed_provider: embed_provider, symbols: symbols) }
        .to raise_error(described_class::EmbeddingCountMismatch)
      expect(CodeSymbol.count).to eq(0)
    end

    # Counterpart to the "fewer" case: MORE vectors than symbols (provider bug /
    # duplication) must also raise, not silently truncate. Pins `!=` against a `<`
    # mutation that would let the over-supply through.
    it 'raises and inserts nothing when MORE embeddings than symbols are returned' do
      allow(embed_provider).to receive(:embed_batch).and_return([vec, vec]) # 2 vecs for 1 symbol
      expect { described_class.persist(repo: repository, embed_provider: embed_provider, symbols: [sym]) }
        .to raise_error(described_class::EmbeddingCountMismatch)
      expect(CodeSymbol.count).to eq(0)
    end
  end

  # Write-both (embedding v2 PR 2): each symbol gets a shadow content_embeddings row.
  describe '.persist sidecar write-both' do
    # The per-symbol read-back loop below issues repeated SELECTs by design.
    before { Prosopite.pause }

    it 'writes one sidecar row per symbol, keyed to the symbol via its pre-generated UUID' do
      allow(embed_provider).to receive(:embed_batch).and_return([Array.new(1536, 0.1), Array.new(1536, 0.2)])
      symbols = [sym(qualified_name: 'A', signature: 'sig-A'), sym(qualified_name: 'B', signature: 'sig-B')]

      expect { described_class.persist(repo: repository, embed_provider: embed_provider, symbols: symbols) }
        .to change(ContentEmbedding, :count).by(2)

      %w[sig-A sig-B].each do |signature|
        symbol = CodeSymbol.find_by(signature: signature)
        row = ContentEmbedding.find_by(embeddable_type: 'CodeSymbol', embeddable_id: symbol.id)
        expect(row).to have_attributes(
          organisation_id: repository.organisation_id,
          embedding_provider: 'openai', embedding_model: 'text-embedding-3-small', embedding_dims: 1536,
          source_hash: ContentEmbedding.source_hash_for(signature), indexed: true
        )
        expect(row.embedded_at).to be_present
        # The pre-generated UUID mapping is what keys each vector to ITS symbol: sig-A
        # got 0.1, sig-B got 0.2, and a swapped mapping would show up right here.
        expect(row.embedding.to_a.first).to eq(signature == 'sig-A' ? 0.1 : 0.2)
      end
    end

    it 'writes no sidecar rows for an empty symbol set' do
      expect { described_class.persist(repo: repository, embed_provider: embed_provider, symbols: []) }
        .not_to change(ContentEmbedding, :count)
    end
  end

  # Dimension parity (embedding v2 PR 7). Until PR 7 the vector had TWO destinations
  # and only one of them could hold 1024 dims: code_symbols.signature_embedding was
  # typed vector(1536), so a 1024-dim org needed a write guard that skipped the inline
  # column (and a 1536 org got the vector in both places). The column is gone — there
  # is one destination left, and these two examples are the control pair proving that
  # 1024 and 1536 now take the SAME path. Reintroducing any dimension branch breaks the
  # 1024 example.
  describe '.persist across dimensions' do
    let(:vec1024) { Array.new(1024, 0.3) }
    let(:embed_provider1024) do
      instance_double(Lalabase::Llm::OpenAiProvider, provider_name: 'openai_compatible',
                                                     default_embedding_model: 'mistral-embed',
                                                     expected_embedding_dims: 1024)
    end

    before do
      Prosopite.pause
      allow(embed_provider1024).to receive(:embed_batch).and_return([vec1024])
    end

    it 'writes a full 1024 sidecar row for a non-1536 space' do
      expect { described_class.persist(repo: repository, embed_provider: embed_provider1024, symbols: [sym]) }
        .to change(CodeSymbol, :count).by(1).and change(ContentEmbedding, :count).by(1)

      row = ContentEmbedding.find_by(embeddable_type: 'CodeSymbol', embeddable_id: CodeSymbol.last.id)
      expect(row).to have_attributes(embedding_provider: 'openai_compatible',
                                     embedding_model: 'mistral-embed', embedding_dims: 1024, indexed: true)
      expect(row.embedding.to_a.length).to eq(1024)
    end

    it 'writes a full 1536 sidecar row for the former inline dimension (same path)' do
      allow(embed_provider).to receive(:embed_batch).and_return([vec])

      expect { described_class.persist(repo: repository, embed_provider: embed_provider, symbols: [sym]) }
        .to change(CodeSymbol, :count).by(1).and change(ContentEmbedding, :count).by(1)

      row = ContentEmbedding.find_by(embeddable_type: 'CodeSymbol', embeddable_id: CodeSymbol.last.id)
      expect(row).to have_attributes(embedding_dims: 1536, indexed: true)
      expect(row.embedding.to_a.length).to eq(1536)
    end
  end
end
