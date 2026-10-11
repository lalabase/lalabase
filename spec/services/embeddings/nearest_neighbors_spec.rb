# frozen_string_literal: true

require 'rails_helper'

# Contract unit for the ONE nearest-neighbour read seam (embedding v2 PR 4b,
# doc/embedding_v2_pr4b_read_switch_plan.md §6.1). Every call site that used to
# run `nearest_neighbors` on an inline vector column now goes through here, so
# this spec pins the guarantees those call sites silently relied on:
#
#   * the METRIC per record type (wrong operator = the 4a ANN index is bypassed),
#   * M1, the unconditional INNER JOIN (an orphaned sidecar row must never become
#     a hit — that would be a NEW false positive the inline path could not produce),
#   * M2, the return shape (ascending distance, distance value, opt-in vector),
#   * vector-space isolation (the reindexer leaves OLD triple rows indexed: true
#     until PR 6, so a weaker filter would return duplicates from two spaces),
#   * tenant isolation, scope hardening and input hardening,
#   * that the read is deliberately GATE-FREE (a local DB read is neither data
#     egress nor spend, so ai_enabled/quota must not switch retrieval off).
RSpec.describe Embeddings::NearestNeighbors do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:repo) { create(:project_repository, project: project, organisation: organisation) }

  # Query = unit vector on axis 0. For unit vectors the L2 distance grows
  # monotonically with the angle, so the constructed candidates below have a
  # strict, tie-free ordering under both metrics.
  let(:query_vector) { unit_vector(0) }

  before do
    ActsAsTenant.current_tenant = organisation
    stub_default_embedding_space
    pin_exact_vector_scans
  end

  after { ActsAsTenant.current_tenant = nil }

  def unit_vector(position)
    Array.new(1536, 0.0).tap { |v| v[position] = 1.0 }
  end

  # Normalized vector with cosine similarity `similarity` to the query.
  def vector_with_similarity(similarity)
    Array.new(1536, 0.0).tap do |v|
      v[0] = similarity
      v[1] = Math.sqrt(1.0 - (similarity**2))
    end
  end

  # A fragment as production has it: the record plus the sidecar row the seam reads.
  def embedded_fragment(vector, mirror: true, content: 'projektwissen')
    ticket = create(:ticket, project: project, organisation: organisation, creator: user)
    fragment = create(:fragment, fragmentable: ticket, organisation: organisation,
                                 plain_text_content: content)
    seed_sidecar_embedding(fragment, vector: vector) if mirror
    fragment
  end

  def embedded_symbol(vector, **attrs)
    symbol = create(:code_symbol, project_repository: repo, organisation: organisation, **attrs)
    seed_sidecar_embedding(symbol, vector: vector)
    symbol
  end

  def call_for_fragments(**overrides)
    described_class.call(embeddable_type: 'Fragment', organisation: organisation,
                         query_vector: query_vector, limit: 10, **overrides)
  end

  describe 'metric per record type (must match the 4a index opclass)' do
    it 'orders Fragment by euclidean distance (<->, idx_ce_fragment_1536_l2)' do
      sql = described_class.relation(embeddable_type: 'Fragment', organisation: organisation,
                                     query_vector: query_vector, limit: 5).to_sql
      expect(sql).to include('<->')
      expect(sql).not_to include('<=>')
    end

    it 'orders CodeSymbol by cosine distance (<=>, idx_ce_code_symbol_1536_cos)' do
      sql = described_class.relation(embeddable_type: 'CodeSymbol', organisation: organisation,
                                     query_vector: query_vector, limit: 5).to_sql
      expect(sql).to include('<=>')
      expect(sql).not_to include('<->')
    end

    it 'orders ProjectCapability by cosine distance (no ANN index — metric is the contract)' do
      sql = described_class.relation(embeddable_type: 'ProjectCapability', organisation: organisation,
                                     query_vector: query_vector, limit: 5).to_sql
      expect(sql).to include('<=>')
    end

    it 'declares a metric for every embeddable that carries a vector column' do
      expect(described_class::METRICS.keys)
        .to contain_exactly('Fragment', 'CodeSymbol', 'ProjectCapability', 'ProjectLayer4Vision')
    end
  end

  # The three predicates the 4a index is partial on. Dropping ANY of them makes
  # the index unusable — see the negative controls in
  # spec/models/content_embedding_ann_index_guard_spec.rb.
  describe 'partial-index predicates in the WHERE clause' do
    let(:sql) do
      described_class.relation(embeddable_type: 'Fragment', organisation: organisation,
                               query_vector: query_vector, limit: 5).to_sql
    end

    it 'states the embeddable_type filter' do
      expect(sql).to include("content_embeddings.embeddable_type = 'Fragment'")
    end

    it 'states the embedding_dims filter' do
      expect(sql).to include('content_embeddings.embedding_dims = 1536')
    end

    it 'states `indexed` as the bare boolean (same form as the index predicate)' do
      expect(sql).to include('content_embeddings.indexed')
      expect(sql).not_to match(/content_embeddings\.indexed\s*=/)
    end

    it 'casts the ordering expression exactly like the index expression' do
      expect(sql).to include('(content_embeddings.embedding::vector(1536))')
      expect(sql).to include('::vector(1536)')
    end
  end

  describe 'M1: the unconditional INNER JOIN hides orphaned sidecar rows' do
    it 'does not return a Fragment whose row was deleted callback-free (sidecar orphan)' do
      keeper = embedded_fragment(query_vector)
      doomed = embedded_fragment(vector_with_similarity(0.99))
      # delete_all skips the dependent: :delete_all callback — exactly how the five
      # parent-purge paths produce orphans until the daily OrphanGc runs.
      Fragment.where(id: doomed.id).delete_all

      expect(ContentEmbedding.where(embeddable_id: doomed.id)).to exist
      expect(call_for_fragments.map { |hit| hit.record.id }).to eq([keeper.id])
    end

    it 'does not return a CodeSymbol whose row was deleted callback-free' do
      keeper = embedded_symbol(query_vector, qualified_name: 'Keep#me')
      doomed = embedded_symbol(query_vector, qualified_name: 'Gone#now')
      CodeSymbol.where(id: doomed.id).delete_all

      hits = described_class.call(embeddable_type: 'CodeSymbol', organisation: organisation,
                                  query_vector: query_vector, limit: 10)
      expect(hits.map { |hit| hit.record.id }).to eq([keeper.id])
    end
  end

  describe 'M2: return shape' do
    it 'returns Hits in ASCENDING distance order' do
      near = embedded_fragment(vector_with_similarity(1.0))
      mid = embedded_fragment(vector_with_similarity(0.9))
      far = embedded_fragment(vector_with_similarity(0.2))

      hits = call_for_fragments
      expect(hits.map { |hit| hit.record.id }).to eq([near.id, mid.id, far.id])
      expect(hits.map(&:distance)).to eq(hits.map(&:distance).sort)
    end

    it 'reports the real euclidean distance (0 for an identical vector)' do
      embedded_fragment(query_vector)
      expect(call_for_fragments.first.distance).to be_within(1e-9).of(0.0)
    end

    it 'reports the euclidean distance of a constructed candidate' do
      # Two unit vectors with cosine s have L2 distance sqrt(2 - 2s).
      embedded_fragment(vector_with_similarity(0.5))
      expect(call_for_fragments.first.distance).to be_within(1e-6).of(Math.sqrt(2 - (2 * 0.5)))
    end

    it 'yields fully usable source records (not bare ids)' do
      fragment = embedded_fragment(query_vector, content: 'echter inhalt')
      hit = call_for_fragments.first
      expect(hit.record).to be_a(Fragment)
      expect(hit.record.plain_text_content).to eq('echter inhalt')
      expect(hit.record.fragmentable_id).to eq(fragment.fragmentable_id)
    end

    it 'returns the sidecar vector with with_vectors: true' do
      vector = vector_with_similarity(0.95)
      embedded_fragment(vector)
      hit = call_for_fragments(with_vectors: true).first
      expect(hit.vector).to be_an(Array)
      expect(hit.vector.length).to eq(1536)
      expect(hit.vector.first).to be_within(1e-6).of(vector.first)
    end

    it 'neither exposes nor SELECTs the vector without the flag (no 12 KB blind transport)' do
      embedded_fragment(query_vector)
      expect(call_for_fragments.first.vector).to be_nil
      expect(call_for_fragments(limit: 1).first.vector).to be_nil

      sql = described_class.relation(embeddable_type: 'Fragment', organisation: organisation,
                                     query_vector: query_vector, limit: 5).to_sql
      expect(sql).not_to include('nn_vector')
    end

    it 'caps at the requested limit (n+1 boundary)' do
      3.times { |i| embedded_fragment(vector_with_similarity(1.0 - (i * 0.05))) }
      expect(call_for_fragments(limit: 2).size).to eq(2)
    end

    it 'returns an empty Array when nothing is embedded' do
      expect(call_for_fragments).to eq([])
    end
  end

  describe 'vector-space isolation (provenance triple)' do
    it 'returns exactly ONE hit when a stale second space row exists for the same record' do
      # Embeddings::OrganisationReindexer upserts the NEW triple on a model switch
      # and leaves the OLD row indexed: true (retirement lands in PR 6). A filter on
      # (type, dims, indexed) alone would return this record twice, from two
      # incompatible vector spaces.
      fragment = embedded_fragment(query_vector)
      create(:content_embedding, embeddable: fragment, organisation: organisation,
                                 embedding: unit_vector(5), embedding_model: 'other-model',
                                 indexed: true)

      hits = call_for_fragments
      expect(hits.size).to eq(1)
      expect(hits.first.record.id).to eq(fragment.id)
    end

    it 'ignores a row from another PROVIDER in the same dimension' do
      fragment = embedded_fragment(query_vector, mirror: false)
      create(:content_embedding, embeddable: fragment, organisation: organisation,
                                 embedding: query_vector, embedding_provider: 'openai_compatible',
                                 indexed: true)
      expect(call_for_fragments).to be_empty
    end

    it 'ignores a NOT-indexed row of the current space' do
      fragment = embedded_fragment(query_vector, mirror: false)
      create(:content_embedding, embeddable: fragment, organisation: organisation,
                                 embedding: query_vector, indexed: false)
      expect(call_for_fragments).to be_empty
    end

    it 'ignores a row of a different dimension' do
      fragment = embedded_fragment(query_vector, mirror: false)
      create(:content_embedding, embeddable: fragment, organisation: organisation,
                                 embedding: Array.new(1024, 0.01), embedding_dims: 1024,
                                 indexed: true)
      expect(call_for_fragments).to be_empty
    end
  end

  # The mirror image of the example above, one per lane unlocked in PR 5: with the
  # org's CURRENT space at 768/1024 the seam must FIND that row and ignore the
  # record's 1536 leftover (which stays indexed: true until PR 6 retires it). This is
  # the end-to-end proof that the read seam is genuinely dim-agnostic — the 1536-only
  # examples above would stay green even with a dimension hardcoded somewhere.
  describe 'non-1536 spaces (embedding v2 PR 5)' do
    [768, 1024].each do |dims|
      context "with the org's current space at #{dims} dims" do
        let(:space) { stub_embedding_space(dims: dims) }
        let(:short_vector) { Array.new(dims, 0.0).tap { |v| v[0] = 1.0 } }

        def call_in_space(vector)
          described_class.call(embeddable_type: 'Fragment', organisation: organisation,
                               query_vector: vector, limit: 5)
        end

        it "finds the #{dims} row and ignores the record's 1536 leftover" do
          fragment = embedded_fragment(query_vector) # write-both state: + a 1536 sidecar row
          create(:content_embedding, embeddable: fragment, organisation: organisation,
                                     embedding: short_vector, indexed: true, **space)

          hits = call_in_space(short_vector)

          expect(hits.map { |hit| hit.record.id }).to eq([fragment.id])
          expect(hits.first.distance).to be_within(1e-6).of(0.0)
        end

        it 'returns nothing when only the 1536 leftover exists (stranded, not readable)' do
          embedded_fragment(query_vector) # mirrored at 1536 only
          space # resolve the stub before the call

          expect(call_in_space(short_vector)).to be_empty
        end
      end
    end
  end

  describe 'multi-tenancy' do
    it 'never returns a hit from another organisation, even for an identical vector' do
      mine = embedded_fragment(query_vector)
      other_org = create(:organisation)
      foreign = nil
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        other_ticket = create(:ticket, project: other_project, organisation: other_org, creator: create(:user))
        foreign = create(:fragment, fragmentable: other_ticket, organisation: other_org)
        seed_sidecar_embedding(foreign, vector: query_vector)
      end

      hits = call_for_fragments
      expect(hits.map { |hit| hit.record.id }).to eq([mine.id])
    end

    it 'keeps the org filter even without the acts_as_tenant default scope' do
      # The explicit organisation_id clauses are the LAST defense: strip the default
      # scope and a missing clause would leak immediately.
      mine = embedded_fragment(query_vector)
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        other_ticket = create(:ticket, project: other_project, organisation: other_org, creator: create(:user))
        foreign = create(:fragment, fragmentable: other_ticket, organisation: other_org)
        seed_sidecar_embedding(foreign, vector: query_vector)
      end

      hits = ActsAsTenant.without_tenant { call_for_fragments }
      expect(hits.map { |hit| hit.record.id }).to eq([mine.id])
    end
  end

  describe 'scope:' do
    it 'narrows the candidate set (project scope through for_project_context)' do
      in_project = embedded_fragment(query_vector)
      other_project = create(:project, organisation: organisation)
      other_ticket = create(:ticket, project: other_project, organisation: organisation, creator: user)
      elsewhere = create(:fragment, fragmentable: other_ticket, organisation: organisation)
      seed_sidecar_embedding(elsewhere, vector: query_vector)

      hits = call_for_fragments(scope: Fragment.for_project_context(project))
      expect(hits.map { |hit| hit.record.id }).to eq([in_project.id])
    end

    it 'rejects a relation of a FOREIGN class (a caller must not bypass the M1 join)' do
      expect { call_for_fragments(scope: CodeSymbol.all) }
        .to raise_error(ArgumentError, /Relation on Fragment/)
    end

    it 'rejects a non-relation scope' do
      expect { call_for_fragments(scope: [1, 2, 3]) }.to raise_error(ArgumentError)
    end

    it "lets the distance order win over a scope's own ORDER BY (reorder, not order)" do
      near = embedded_fragment(vector_with_similarity(1.0))
      far = embedded_fragment(vector_with_similarity(0.2))
      # created_at DESC would put `far` (created last) first.
      hits = call_for_fragments(scope: Fragment.order(created_at: :desc))
      expect(hits.map { |hit| hit.record.id }).to eq([near.id, far.id])
    end

    it 'keeps a scope preload alive (includes survives the merge)' do
      embedded_fragment(query_vector)
      hits = call_for_fragments(scope: Fragment.includes(:fragmentable))
      expect(hits.first.record.association(:fragmentable)).to be_loaded
    end
  end

  describe 'input hardening' do
    it 'rejects an unknown embeddable_type before touching the DB' do
      expect { call_for_fragments }.not_to raise_error
      expect do
        described_class.call(embeddable_type: 'Organisation', organisation: organisation,
                             query_vector: query_vector, limit: 5)
      end.to raise_error(ArgumentError, /Unsupported embeddable_type/)
    end

    it 'rejects a query_vector of the wrong length (the space expects 1536)' do
      expect { call_for_fragments(query_vector: Array.new(768, 0.1)) }
        .to raise_error(ArgumentError, /1536/)
    end

    it 'rejects a non-numeric element' do
      vector = unit_vector(0)
      vector[3] = 'nope'
      expect { call_for_fragments(query_vector: vector) }
        .to raise_error(ArgumentError, /non-numeric/)
    end

    it 'rejects non-finite values (NaN/Infinity would poison the ORDER BY)' do
      vector = unit_vector(0)
      vector[3] = Float::INFINITY
      expect { call_for_fragments(query_vector: vector) }
        .to raise_error(ArgumentError, /non-finite/)
    end

    it 'rejects a nil query_vector' do
      expect { call_for_fragments(query_vector: nil) }.to raise_error(ArgumentError)
    end

    it 'does not let a crafted vector element inject SQL (literal is Float-built + quoted)' do
      expect { call_for_fragments(query_vector: ["0.1']; DROP TABLE fragments; --"] * 1536) }
        .to raise_error(ArgumentError, /non-numeric/)
      expect(ActiveRecord::Base.connection.table_exists?('fragments')).to be true
    end
  end

  # §3.4: the ai_enabled gate protects data EGRESS to a provider, the quota gate
  # protects SPEND. A local sidecar read is neither, and retrieval must keep
  # serving while a quota is exhausted — otherwise an exhausted budget silently
  # degrades search to "no results" instead of "no new embeddings".
  describe 'gate-free space resolution' do
    let(:system_credential) do
      build_stubbed(:ai_credential, provider: 'openai', enabled: true, access_token: 'sk-system')
    end

    before do
      # Deliberately NOT stub_default_embedding_space: this example must exercise
      # the REAL Lalabase::Llm::Factory.embedding_space_for resolution.
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for).and_call_original
      allow(AiCredential).to receive(:active_for_provider).with('openai').and_return(system_credential)
    end

    it 'still serves hits when the org quota is exhausted' do
      allow(Lalabase::Llm::Gate).to receive(:ensure_within_quota!)
        .and_raise(Lalabase::Llm::QuotaExceededError)
      fragment = embedded_fragment(query_vector)
      expect(call_for_fragments.map { |hit| hit.record.id }).to eq([fragment.id])
    end

    it 'still serves hits when the org has AI disabled' do
      fragment = embedded_fragment(query_vector)
      organisation.update!(ai_enabled: false)
      expect(call_for_fragments.map { |hit| hit.record.id }).to eq([fragment.id])
    end

    it 'resolves the same triple the write paths stamp (no drift by construction)' do
      space = Lalabase::Llm::Factory.embedding_space_for(organisation, space: :active)
      expect(space).to eq(embedding_provider: 'openai', embedding_model: 'text-embedding-3-small',
                          embedding_dims: 1536)
    end
  end

  describe 'ef_search (m2 — prepared, not armed in 4b)' do
    def captured_sql(&block)
      statements = []
      callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql].to_s }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
      statements
    end

    it 'issues SET LOCAL hnsw.ef_search when a value is given' do
      embedded_fragment(query_vector)
      statements = captured_sql { call_for_fragments(ef_search: 64) }
      expect(statements.join("\n")).to include('SET LOCAL hnsw.ef_search = 64')
    end

    it 'issues no SET at all by default' do
      embedded_fragment(query_vector)
      statements = captured_sql { call_for_fragments }
      expect(statements.join("\n")).not_to include('hnsw.ef_search')
    end

    it 'coerces the value to an Integer (no raw string reaches the GUC)' do
      embedded_fragment(query_vector)
      statements = captured_sql { call_for_fragments(ef_search: '40; SELECT 1') }
      expect(statements.join("\n")).not_to include('SELECT 1')
    rescue ArgumentError
      # Integer('40; SELECT 1') raises — that is the same protection, stated loudly.
      expect(true).to be true
    end

    it 'still returns the correct hits with ef_search set' do
      fragment = embedded_fragment(query_vector)
      expect(call_for_fragments(ef_search: 40).map { |hit| hit.record.id }).to eq([fragment.id])
    end
  end
end
