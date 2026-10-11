# frozen_string_literal: true

require 'rails_helper'

# EXPLAIN guard for the REAL SQL of the read seam (embedding v2 PR 4b,
# doc/embedding_v2_pr4b_read_switch_plan.md §6.2). Where the 4a guard
# (spec/models/content_embedding_ann_index_guard_spec.rb) asserts a HAND-WRITTEN
# canonical query, this one asserts what Embeddings::NearestNeighbors actually
# generates — via `.relation(...).to_sql`, so no copy can drift from the code.
#
# WHAT THIS PROVES — and what it explicitly does NOT:
# It runs EXPLAIN with `SET LOCAL enable_seqscan = off` AND `SET LOCAL
# enable_sort = off`, i.e. with both escape hatches closed that would let the
# planner satisfy the distance ORDER BY without the ANN index. A green run
# therefore proves the seam's SQL form keeps the expression-partial index USABLE
# (cast + operator + full partial predicate still match). It says NOTHING about
# whether production picks that index: on org-scoped queries against pgvector
# 0.6.0 it demonstrably does not (filtered-ANN; the planner takes the org b-tree
# plus an exact sort — sheet §2.1). This guard is a PIN AGAINST SQL-FORM DRIFT,
# NOT a performance proof.
#
# DELIBERATE DUPLICATION with the 4a guard (feedback_mark_deliberate_duplication_in_code):
# 4a keeps the hand-written form AND the three negative controls (each dropping
# ONE partial predicate). Those controls are NOT reproducible from this query
# object — it always emits the full triple, which is exactly the contract it must
# meet. Do not refactor the 4a spec to source its SQL from here, and do not weaken
# its controls. If a THIRD place asserts this SQL shape, unify then.
#
# No fixture rows are needed (4a finding: an empty index still yields an Index
# Scan) — with the caveat that this therefore makes no statement about cost
# behaviour at real data volumes.
#
# Parametrised per DIMENSION since PR 5: the seam derives cast, operator and index
# predicate from the RESOLVED space (`@space[:embedding_dims]`), so every lane needs
# its own proof that the derivation still meets its index. A hardcoded 1536 anywhere
# in the seam would pass the 1536 examples and fail the other two.
RSpec.describe 'Embeddings::NearestNeighbors — generated SQL keeps the ANN indexes usable' do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:dims) { 1536 }
  let(:fragment_index) { "idx_ce_fragment_#{dims}_l2" }
  let(:code_symbol_index) { "idx_ce_code_symbol_#{dims}_cos" }
  let(:query_vector) { Array.new(dims) { 0.1 } }
  let(:conn) { ActiveRecord::Base.connection }

  before do
    ActsAsTenant.current_tenant = organisation
    stub_embedding_space(dims: dims)
  end

  after { ActsAsTenant.current_tenant = nil }

  # SET LOCAL is scoped to the example's transaction (use_transactional_fixtures).
  # Both settings are penalties, not bans — where no alternative path exists
  # Postgres still sorts. The partial predicate is the hard constraint.
  def explain_plan(sql)
    conn.execute('SET LOCAL enable_seqscan = off')
    conn.execute('SET LOCAL enable_sort = off')
    conn.execute("EXPLAIN (COSTS OFF) #{sql}").map { |row| row['QUERY PLAN'] }.join("\n")
  end

  def seam_sql(embeddable_type:, scope: nil)
    Embeddings::NearestNeighbors.relation(
      embeddable_type: embeddable_type, organisation: organisation,
      query_vector: query_vector, limit: 15, scope: scope
    ).to_sql
  end

  Organisation::SUPPORTED_DIMS.each do |supported_dims|
    context "in a #{supported_dims}-dimensional space" do
      let(:dims) { supported_dims }

      # The verbatim half of the contract (PR 5b): the plan assertions below prove the
      # index is USABLE, this proves the seam spells the cast the index was BUILT with.
      # Both are needed — a seam that hardcoded ::vector(dims) would still satisfy every
      # plan assertion up to 1536 and only miss on 3072, where the cast is halfvec.
      it 'casts to exactly the type this lane is indexed with' do
        cast = Embeddings::NearestNeighbors::INDEX_CAST_TYPE.fetch(dims)
        wrong = cast == 'vector' ? 'halfvec' : 'vector'

        sql = seam_sql(embeddable_type: 'Fragment')

        expect(sql).to include("::#{cast}(#{dims})")
        expect(sql).not_to include("::#{wrong}(#{dims})")
      end

      describe 'Fragment (euclidean / vector_l2_ops)' do
        it 'lets the planner use the L2 partial index' do
          plan = explain_plan(seam_sql(embeddable_type: 'Fragment'))
          expect(plan).to include("Index Scan using #{fragment_index}")
        end

        # The heaviest real scope: for_project_context drags in ten LEFT JOINs plus a
        # polymorphic WHERE. Pins that this join ballast does not break the match.
        it 'still uses the index with the for_project_context scope merged in' do
          plan = explain_plan(seam_sql(embeddable_type: 'Fragment',
                                       scope: Fragment.for_project_context(project)))
          expect(plan).to include("Index Scan using #{fragment_index}")
        end
      end

      describe 'CodeSymbol (cosine / vector_cosine_ops)' do
        it 'lets the planner use the cosine partial index' do
          plan = explain_plan(seam_sql(embeddable_type: 'CodeSymbol'))
          expect(plan).to include("Index Scan using #{code_symbol_index}")
        end
      end
    end
  end

  describe 'ProjectCapability (no ANN index by design — small set, exact scan)' do
    it 'uses NEITHER idx_ce_ index' do
      plan = explain_plan(seam_sql(embeddable_type: 'ProjectCapability',
                                   scope: ProjectCapability.where(project_id: project.id)))
      expect(plan).not_to include('idx_ce_')
    end
  end
end
