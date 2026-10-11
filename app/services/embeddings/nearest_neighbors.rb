# frozen_string_literal: true

# Embedding v2 PR 4b — the ONE nearest-neighbour read seam over the
# content_embeddings sidecar (details on the class).
module Embeddings
  # Nearest-neighbour search over the content_embeddings sidecar for ONE record
  # type in the org's CURRENT vector space (PR 6 swaps that resolution to the
  # active-space pointer — one seam, doc/embedding_v2_multidim_plan.md §5.3).
  # Replaces the six scattered `nearest_neighbors` call sites of the inline
  # vector columns (doc/embedding_v2_pr4b_read_switch_plan.md §2.2).
  #
  # The metric is a property of the RECORD TYPE, not of the row (METRICS below) —
  # it must match the opclass of the 4a expression-partial index, or the query
  # silently loses the index.
  #
  # Contract (main plan §3.6):
  #   - M1: ALWAYS inner-joins the embeddable table, so orphaned sidecar rows
  #     (record already deleted, daily Embeddings::OrphanGc not yet run) can never
  #     surface as hits. `scope:` may only ADD filters, never drop that join.
  #   - M2: returns Array<Hit> in ascending distance order; Hit carries the joined
  #     source record, the distance and — with `with_vectors: true` — the sidecar
  #     vector (the two Ruby reranking call sites read it from here instead of
  #     from the inline column, which PR 7 drops).
  #   - Planner match: ORDER BY reproduces the expression-partial index cast +
  #     operator verbatim, and the WHERE states the FULL partial predicate
  #     (embeddable_type + embedding_dims + bare `indexed`). All three are
  #     load-bearing — see the negative controls in
  #     spec/models/content_embedding_ann_index_guard_spec.rb.
  #
  # Provenance: the filter is the FULL triple (provider, model, dims). The minimal
  # variant (type + dims + indexed) is wrong today: Embeddings::OrganisationReindexer
  # leaves the OLD triple rows `indexed: true` on a model switch (retirement lands
  # in PR 6), so a per-record query would return TWO hits from two incompatible
  # vector spaces. With the full triple the unique index
  # (idx_content_embeddings_unique_space) guarantees at most one row per record.
  #
  # NOTE on today's planner reality (sheet §2.1): on pgvector 0.6.0 an org-scoped
  # query does NOT actually use the HNSW index — the planner picks the org b-tree
  # plus an exact sort (perfect recall, fast at current sizes), which is exactly
  # the limit the replaced inline path had. The ANN index becomes the scaling
  # lever after the pgvector >= 0.8.0 upgrade (hnsw.iterative_scan), with no code
  # change here.
  class NearestNeighbors
    Hit = Struct.new(:record, :distance, :vector, keyword_init: true)

    # Metric per embeddable type + the 4a index it has to match.
    METRICS = {
      'Fragment' => :euclidean,            # idx_ce_fragment_1536_l2 (vector_l2_ops)
      'CodeSymbol' => :cosine,             # idx_ce_code_symbol_1536_cos (vector_cosine_ops)
      'ProjectCapability' => :cosine,      # no ANN index — small, exact scan
      'ProjectLayer4Vision' => :cosine     # no ANN index; no caller in 4b (1:1 find_by)
    }.freeze

    # Distance operators are the SAME for vector and halfvec — only the cast differs
    # (INDEX_CAST_TYPE below), which is why 3072 needs no operator branch.
    OPERATORS = { euclidean: '<->', cosine: '<=>' }.freeze

    # The pgvector cast a dimension is INDEXED with, and therefore the cast this query
    # must spell verbatim. Deliberately an explicit map, not a `dims > 2000` threshold:
    # 2000 is pgvector's hnsw index limit — an implementation property of the extension,
    # not domain logic — so spelling it out keeps the mapping greppable and makes a future
    # limit change a one-line edit instead of an arithmetic re-derivation.
    #
    # halfvec (PR 5b) costs fp16 precision INSIDE THE INDEX only: the column stays an
    # untyped `vector` at full precision, re-ranking reads that value, and LIMIT is small
    # (series plan §3.5). A regular vector index on 3072 is not merely slower, it cannot be
    # created at all — "column cannot have more than 2000 dimensions for hnsw index".
    #
    # The migrations spell their DDL out literally and do NOT read this constant: a
    # migration is frozen history, and coupling it to living app code would let a later
    # rename change what `db:migrate` builds from zero. The contract between the two is
    # enforced by a TEST instead — content_embedding_ann_index_guard_spec asserts per lane
    # that the planner actually picks the index for the canonical query, so a divergence
    # turns a CI guard red instead of turning production quietly slow.
    INDEX_CAST_TYPE = { 768 => 'vector', 1024 => 'vector', 1536 => 'vector', 3072 => 'halfvec' }.freeze

    # Deliberately NOT `neighbor_distance`: the neighbor gem stays installed until
    # PR 7 drops the inline columns, and two identically named aliases in one code
    # base invite confusion about which path produced a distance.
    DISTANCE_ALIAS = 'nn_distance'
    VECTOR_ALIAS = 'nn_vector'

    # The three partial-index predicates, verbatim and in the canonical 4a order,
    # so predicate implication is trivially true for the planner. `indexed` is the
    # BARE boolean (not `indexed = TRUE`) — same form as the index definition.
    INDEX_PREDICATE_SQL = 'content_embeddings.embeddable_type = ? AND ' \
                          'content_embeddings.embedding_dims = ? AND ' \
                          'content_embeddings.indexed'

    # @return [Array<Hit>] ascending by distance
    def self.call(**kwargs)
      new(**kwargs).call
    end

    # The relation behind `.call`, public so the EXPLAIN guard spec can assert the
    # REAL generated SQL (`.relation(...).to_sql`) instead of a hand-written copy.
    def self.relation(**kwargs)
      new(**kwargs).relation
    end

    # @param scope [ActiveRecord::Relation, nil] must be a relation on the class
    #   behind `embeddable_type`, and must not carry its own SELECT list.
    # @param with_vectors [Boolean] also transport the sidecar vector (~12 KB/row)
    # @param ef_search [Integer, nil] optional `SET LOCAL hnsw.ef_search`; nil (the
    #   default) keeps today's behaviour. Not used by any 4b call site.
    def initialize(embeddable_type:, organisation:, query_vector:, limit:,
                   scope: nil, with_vectors: false, ef_search: nil)
      # METRICS is also the constantize whitelist — resolve it BEFORE anything
      # touches the DB, so a bogus type can never build a query.
      @metric = METRICS.fetch(embeddable_type) do
        raise ArgumentError,
              "Unsupported embeddable_type #{embeddable_type.inspect} (known: #{METRICS.keys.join(', ')})"
      end
      @embeddable_type = embeddable_type
      @organisation = organisation
      @limit = Integer(limit)
      @scope = scope
      @with_vectors = with_vectors
      @ef_search = ef_search.nil? ? nil : Integer(ef_search)
      # :active — the served space (PR 6a). Row selection and the query embedding
      # (Lalabase::QueryEmbedding) must resolve the SAME space, or a staged switch
      # compares vectors across incompatible spaces.
      @space = ::Lalabase::Llm::Factory.embedding_space_for(organisation, space: :active)
      @query_vector = coerce_query_vector(query_vector)
      validate_scope!
    end

    def call
      records = @ef_search ? with_ef_search { relation.to_a } : relation.to_a
      records.map { |record| build_hit(record) }
    end

    # Built from the SOURCE class (not from ContentEmbedding) so a caller's `scope:`
    # merges naturally — including for_project_context's string joins and
    # includes(:fragmentable) — and the hits materialize as real source records.
    def relation
      (@scope || klass.all)
        # M1: unconditional INNER JOIN — the one structural guarantee of this seam.
        .joins("INNER JOIN content_embeddings ON content_embeddings.embeddable_id = #{klass.table_name}.id")
        .where(INDEX_PREDICATE_SQL, @embeddable_type, dims)
        # Provenance + tenant filters. NOT part of the partial predicate: the
        # index is global, these narrow it afterwards (idx_content_embeddings_org_space
        # supports them).
        .where(content_embeddings: {
                 embedding_provider: @space[:embedding_provider],
                 embedding_model: @space[:embedding_model],
                 organisation_id: @organisation.id
               })
        # Defense-in-depth on the source table, independent of acts_as_tenant's
        # default scope — house style of the call sites this seam replaced.
        .where(klass.table_name => { organisation_id: @organisation.id })
        # reorder, not order: a scope's own ORDER BY must never contaminate the
        # distance ordering, which is part of the M2 contract.
        .reorder(::Arel.sql(order_expression))
        .limit(@limit)
        .select(*select_list)
    end

    private

    def klass
      @klass ||= @embeddable_type.constantize
    end

    def dims
      @space[:embedding_dims]
    end

    def operator
      OPERATORS.fetch(@metric)
    end

    # The cast + operator of the expression index, verbatim — BOTH sides of the operator
    # carry the same cast, because the planner matches the index on the whole expression.
    # `fetch` without a default is intentional: dims comes from the resolved space and is
    # already clamped to SUPPORTED_DIMS, so an unknown dim here is a wiring bug and must
    # be loud rather than silently degrade to an unindexed scan.
    #
    # The literal is assembled ONLY from coerced Floats and embedded via connection.quote,
    # so the raw-SQL ORDER BY carries no injection surface.
    def order_expression
      @order_expression ||= begin
        literal = klass.connection.quote("[#{@query_vector.join(',')}]")
        cast = INDEX_CAST_TYPE.fetch(dims)
        "(content_embeddings.embedding::#{cast}(#{dims})) #{operator} #{literal}::#{cast}(#{dims})"
      end
    end

    def select_list
      list = ["#{klass.table_name}.*", "#{order_expression} AS #{DISTANCE_ALIAS}"]
      # Only on demand: the vector is ~12 KB per candidate row.
      list << "content_embeddings.embedding AS #{VECTOR_ALIAS}" if @with_vectors
      list
    end

    def build_hit(record)
      Hit.new(
        record: record,
        distance: record.read_attribute(DISTANCE_ALIAS),
        vector: (@with_vectors ? deserialize_vector(record.read_attribute(VECTOR_ALIAS)) : nil)
      )
    end

    # ContentEmbedding#embedding is a pgvector column; its Neighbor::Type::Vector
    # casts both the wire string and an already-cast Array to Array<Float>.
    def deserialize_vector(raw)
      ::ContentEmbedding.type_for_attribute('embedding').deserialize(raw)
    end

    # Mirror of Provider#guard_dimensions on the READ side: a vector of the wrong
    # length would silently compare against another vector space (or blow up in PG).
    def coerce_query_vector(query_vector)
      values = Array(query_vector).map do |value|
        Float(value)
      rescue ::TypeError, ::ArgumentError
        raise ArgumentError, "query_vector contains a non-numeric element: #{value.inspect}"
      end
      if values.length != dims
        raise ArgumentError,
              "query_vector has #{values.length} dimensions, the org's vector space expects #{dims}"
      end
      raise ArgumentError, 'query_vector contains non-finite values (NaN/Infinity)' unless values.all?(&:finite?)

      values
    end

    # A foreign relation would let a caller sidestep the M1 join (and the metric).
    def validate_scope!
      return if @scope.nil?
      return if @scope.is_a?(::ActiveRecord::Relation) && @scope.klass == klass

      raise ArgumentError,
            "scope must be an ActiveRecord::Relation on #{klass.name} (got #{@scope.class})"
    end

    # pgvector 0.6.0 has no iterative index scans: an HNSW scan yields ef_search
    # (default 40) candidates and only THEN do join/provenance/org filter, so small
    # orgs can be filtered below `limit`. This knob makes that tunable for the first
    # time; it is deliberately inert in 4b (no call site sets it).
    #
    # SET LOCAL caveat: inside an OUTER transaction (e.g. transactional specs) this
    # runs in a released savepoint and therefore survives until the outer commit.
    # On the real read path there is no ambient transaction, so the scoping is
    # correct; a future caller wrapping this in a transaction must know.
    def with_ef_search(&block)
      klass.transaction do
        klass.connection.execute("SET LOCAL hnsw.ef_search = #{@ef_search}")
        block.call
      end
    end
  end
end
