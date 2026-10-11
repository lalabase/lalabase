# frozen_string_literal: true

require 'rails_helper'

# Schema-level guard for the expression-partial HNSW indexes on content_embeddings
# (embedding v2 PR 4a, migration 20260719160000 = the 1536 lane; PR 5, migration
# 20260731120000 = the 768 and 1024 lanes). This spec is the CI-executable M5 proof:
# it runs against the test DB built by db:schema:load (rails_helper's
# maintain_test_schema! loads schema.rb), so a green run proves the Rails dumper
# round-trips the expression cast + opclass + WHERE + HNSW option losslessly for
# EVERY lane. If a future Rails/schema change ever drops one from the dump,
# db:schema:load stops reproducing it and this guard goes red instead of silently
# losing the ANN index (main plan §9, 4a sheet §4/§8, PR 5 sheet §7.2).
#
# The canonical query form asserted below (exact cast + partial predicate) is
# deliberately duplicated with the SQL that PR 4b's Embeddings::NearestNeighbors
# query object generates (feedback_mark_deliberate_duplication_in_code): 4a
# pins index USABILITY from hand-written SQL; 4b re-pins the same assertion against
# the real query object and may refactor this spec to source its SQL from there, as
# long as the negative controls stay. Caveat: EXPLAIN here proves the index is
# USABLE (with the seq-scan and sort escape hatches closed), NOT that the planner
# picks it on cost grounds in production — on org-scoped queries it demonstrably
# does not (filtered-ANN, see the main plan).
RSpec.describe 'content_embeddings ANN indexes (M5 round-trip guard)' do
  # Fragment → L2, CodeSymbol → cosine (Embeddings::NearestNeighbors::METRICS is the
  # truth per TYPE, not per dim), one lane per SUPPORTED_DIMS value. The 3072 lane is
  # halfvec-cast (PR 5b): pgvector refuses an hnsw index above 2000 dims, so that lane
  # is indexed on a halfvec CAST of the same full-precision column.
  let(:lanes) do
    { 768 => { fragment: 'idx_ce_fragment_768_l2', code_symbol: 'idx_ce_code_symbol_768_cos' },
      1024 => { fragment: 'idx_ce_fragment_1024_l2', code_symbol: 'idx_ce_code_symbol_1024_cos' },
      1536 => { fragment: 'idx_ce_fragment_1536_l2', code_symbol: 'idx_ce_code_symbol_1536_cos' },
      3072 => { fragment: 'idx_ce_fragment_3072_l2', code_symbol: 'idx_ce_code_symbol_3072_cos' } }
  end

  let(:conn) { ActiveRecord::Base.connection }

  it 'covers exactly the shipped dimension allowlist (a new SUPPORTED_DIM needs its own lane)' do
    expect(lanes.keys).to match_array(Organisation::SUPPORTED_DIMS)
  end

  # A vector literal of the given length is untypeable by hand; 0.1 is arbitrary but
  # deliberately != 0 (the null vector is degenerate for cosine, matters if this is
  # ever extended to EXPLAIN ANALYZE — 4a sheet §5.1).
  def query_vector(dims)
    "[#{Array.new(dims) { 0.1 }.join(',')}]"
  end

  # Runs EXPLAIN with both escape hatches closed that would let the planner satisfy
  # the ORDER BY without the ANN index: a seq scan, and a Sort node stacked on any
  # other access path. On today's empty table the ANN index wins on cost even with
  # sorting allowed — but that is a cost decision, and closing the hatch pins these
  # examples to index USABILITY alone, so seeded rows (PR 4b mirrors sidecar rows in
  # its specs) or shifted statistics cannot quietly flip them to btree + Sort. Both
  # settings are penalties, not bans: where no alternative exists Postgres still
  # sorts. The partial predicate is the hard constraint — an unmet one makes the
  # index unusable outright, which is what the negative controls below rest on.
  # SET LOCAL is scoped to the example's transaction (use_transactional_fixtures).
  def explain_plan(sql)
    conn.execute('SET LOCAL enable_seqscan = off')
    conn.execute('SET LOCAL enable_sort = off')
    conn.execute("EXPLAIN (COSTS OFF) #{sql}").map { |row| row['QUERY PLAN'] }.join("\n")
  end

  # The cast a lane is indexed with — read from the SAME constant the query object uses,
  # which is what makes these examples the contract between app code and migration DDL
  # (the migrations spell their DDL out literally and deliberately do NOT read it).
  def cast_for(dims)
    Embeddings::NearestNeighbors::INDEX_CAST_TYPE.fetch(dims)
  end

  # Canonical nearest-neighbour query = exactly the index cast + the full partial
  # predicate. `operator` is <-> (L2) for Fragment, <=> (cosine) for CodeSymbol.
  # `omit:` drops single predicates for the negative controls; `cast:` overrides the
  # correct cast for the PR-5b mismatch control.
  def nearest_neighbour_sql(embeddable_type:, operator:, dims:, omit: [], cast: nil)
    cast ||= cast_for(dims)
    predicates = []
    predicates << "embeddable_type = '#{embeddable_type}'" unless omit.include?(:embeddable_type)
    predicates << "embedding_dims = #{dims}" unless omit.include?(:embedding_dims)
    predicates << 'indexed' unless omit.include?(:indexed)

    <<~SQL.squish
      SELECT id FROM content_embeddings
      WHERE #{predicates.join(' AND ')}
      ORDER BY (embedding::#{cast}(#{dims})) #{operator} '#{query_vector(dims)}'::#{cast}(#{dims})
      LIMIT 15
    SQL
  end

  # Driven off the allowlist itself, not a literal list — a new SUPPORTED_DIM now brings
  # its whole lane suite with it instead of needing this loop edited too.
  Organisation::SUPPORTED_DIMS.each do |dims|
    describe "the #{dims} lane" do
      let(:fragment_index) { lanes[dims][:fragment] }
      let(:code_symbol_index) { lanes[dims][:code_symbol] }

      describe 'existence + structure (via Rails index reflection)' do
        let(:indexes) { conn.indexes('content_embeddings').index_by(&:name) }

        it 'dumps the Fragment index as an HNSW L2 expression index over the full predicate' do
          idx = indexes[fragment_index]
          expect(idx).to be_present, "#{fragment_index} missing — schema.rb did not round-trip it"
          expect(idx.using).to eq(:hnsw)
          expect(idx.columns).to include("::#{cast_for(dims)}(#{dims})")
            .and include("#{cast_for(dims)}_l2_ops")
          expect(idx.where).to include("embeddable_type)::text = 'Fragment'")
            .and include("embedding_dims = #{dims}")
            .and include('indexed')
        end

        it 'dumps the CodeSymbol index as an HNSW cosine expression index over the full predicate' do
          idx = indexes[code_symbol_index]
          expect(idx).to be_present, "#{code_symbol_index} missing — schema.rb did not round-trip it"
          expect(idx.using).to eq(:hnsw)
          expect(idx.columns).to include("::#{cast_for(dims)}(#{dims})")
            .and include("#{cast_for(dims)}_cosine_ops")
          expect(idx.where).to include("embeddable_type)::text = 'CodeSymbol'")
            .and include("embedding_dims = #{dims}")
            .and include('indexed')
        end
      end

      describe 'validity (catches an INVALID leftover from an aborted CONCURRENTLY build)' do
        it 'reports both indexes as valid' do
          invalid = conn.select_values(<<~SQL.squish)
            SELECT c.relname FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            WHERE c.relname IN ('#{fragment_index}', '#{code_symbol_index}') AND NOT i.indisvalid
          SQL
          expect(invalid).to be_empty, "INVALID index(es): #{invalid.join(', ')}"
        end
      end

      describe 'EXPLAIN — the planner can use each partial index for its canonical query' do
        it 'uses the L2 index for the Fragment query' do
          plan = explain_plan(nearest_neighbour_sql(embeddable_type: 'Fragment', operator: '<->', dims: dims))
          expect(plan).to include("Index Scan using #{fragment_index}")
        end

        it 'uses the cosine index for the CodeSymbol query' do
          plan = explain_plan(nearest_neighbour_sql(embeddable_type: 'CodeSymbol', operator: '<=>', dims: dims))
          expect(plan).to include("Index Scan using #{code_symbol_index}")
        end
      end
    end
  end

  # Negative controls: each drops exactly ONE of the three partial predicates, so
  # the index becomes unusable. Together they prove all three are load-bearing and
  # pin the contract PR 4b's query object has to meet — with only the `indexed`
  # control, 4b could omit e.g. `embedding_dims = 1536` and silently lose the index
  # while every positive spec stayed green (4a sheet §5.2/§8.1).
  #
  # Deliberately 1536-ONLY (PR 5): they prove the PRINCIPLE "every predicate carries",
  # which is a property of the index SHAPE and identical across lanes. Repeating them
  # per dim would triple the runtime for no additional information.
  describe 'negative controls (the 1536 lane stands in for all — the shape is identical)' do
    {
      indexed: 'the `indexed` flag',
      embedding_dims: 'the embedding_dims filter',
      embeddable_type: 'the embeddable_type filter'
    }.each do |predicate, description|
      it "does NOT use the index when the query drops #{description}" do
        plan = explain_plan(
          nearest_neighbour_sql(embeddable_type: 'Fragment', operator: '<->', dims: 1536, omit: [predicate])
        )
        expect(plan).not_to include(lanes[1536][:fragment])
      end
    end
  end

  # THE PR-5b control. Everything else here proves an index is usable; this proves the
  # failure mode that motivated 5b, and it is the only example in the file that would
  # stay green if INDEX_CAST_TYPE and the migration DDL drifted apart.
  #
  # Background: pgvector refuses `hnsw` above 2000 dims, so 3072 is indexed on a
  # halfvec CAST. A query that casts to `vector(3072)` instead is not an error — it
  # returns the same rows, just via a full scan, because the expression no longer
  # matches the index. Verified against the real DB while writing the sheet: with
  # enable_seqscan AND enable_sort off, the halfvec form yields "Index Scan using
  # idx_ce_fragment_3072_l2", the vector form a Sort over a Seq Scan.
  #
  # So this pair is positive-and-negative on the SAME lane: the lane loop above asserts
  # the correct cast hits the index, this asserts the wrong one misses it. Without the
  # negative half, reverting order_expression to a hard ::vector(dims) would leave the
  # whole suite green while production quietly stopped using the index.
  describe 'cast match is load-bearing (PR 5b)' do
    it 'does NOT use the 3072 index when the query casts to vector instead of halfvec' do
      plan = explain_plan(
        nearest_neighbour_sql(embeddable_type: 'Fragment', operator: '<->', dims: 3072, cast: 'vector')
      )

      expect(plan).not_to include(lanes[3072][:fragment])
    end
  end

  # Cross-lane control (new with PR 5): with four more indexes that all match
  # "vector expression + partial predicate", a query must still land on ITS lane.
  # Without this the lanes could be mutually substitutable in a plan unnoticed.
  describe 'lane isolation' do
    it 'answers a 1024 Fragment query from the 1024 index, never the 1536 one' do
      plan = explain_plan(nearest_neighbour_sql(embeddable_type: 'Fragment', operator: '<->', dims: 1024))
      expect(plan).to include("Index Scan using #{lanes[1024][:fragment]}")
      expect(plan).not_to include(lanes[1536][:fragment])
    end
  end
end
