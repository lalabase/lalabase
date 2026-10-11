# frozen_string_literal: true

# Re-embeds an organisation's corpus into a target vector space — the build step of the
# staged switch, and the healing step after content drift (details on the class).
module Embeddings
  # Re-embeds every stored vector of an organisation with its CURRENT embedding
  # provider (Factory.for_embeddings), across the four embedded tables. Needed
  # after an org switches its embedding SPACE — the full triple (provider, model,
  # dims) since PR 5, not just provider/model: the old vectors live in an
  # incompatible space and must be recomputed.
  #
  # Idempotent: records that already have a sidecar row in the target TRIPLE are
  # skipped (#stale), so a re-run after a partial failure is cheap and a no-op once
  # done. Per-table counts are logged (no silent caps).
  #
  # Since PR 7 the sidecar is the ONLY destination: the four inline vector columns
  # and their provenance pairs are gone, and with them the 1536-only special case
  # that used to leave a stale inline vector behind under a fresh provenance stamp.
  #
  # METERED since KI-Pakete P4a+ (doc/ki_pakete_p4_plan.md E6): one AiUsage row per
  # run, document_indexing. Before P4a only an operator could reach this class (rake);
  # P4a hands the trigger to the customer, and an unbilled path that a customer can
  # start is a bill nobody can attribute.
  class OrganisationReindexer
    # Embedding endpoints accept large input arrays; 100 keeps memory/latency sane.
    BATCH_SIZE = 100

    # Each embedded table: the model and its source-text column. The `vector:` key
    # died with the inline columns in PR 7 — where the vector LANDS is no longer a
    # per-table property, it is one sidecar row keyed by embeddable_type.
    TARGETS = [
      { model: 'CodeSymbol',          text: :signature },
      { model: 'ProjectCapability',   text: :description },
      { model: 'ProjectLayer4Vision', text: :content },
      { model: 'Fragment',            text: :plain_text_content }
    ].freeze

    Result = Struct.new(:reindexed, :skipped, :total, :stale_reembedded, keyword_init: true)

    # Per-model count of records with NO readable row in the given space — the ONE
    # anti-join behind three consumers: this class's own skip logic, the flip
    # validation (Actors::FlipEmbeddingModel) and `rake embeddings:status`.
    #
    # Deliberately NOT a count comparison ("target rows >= records", M3): orphaned
    # sidecar rows would let a partially built space pass as complete. An anti-join
    # asks the only question that matters — is there a SOURCE RECORD the reader cannot
    # reach in that space — and orphans cannot forge an answer to it.
    #
    # @param space [Hash] the triple {embedding_provider:, embedding_model:, embedding_dims:}
    # @param require_indexed [Boolean] whether a row must be READABLE (indexed) to count.
    #   false answers the different question "does a row EXIST at all" — the two together
    #   tell an INCOMPLETE space (rows missing) from a merely RETIRED one (rows present but
    #   de-indexed), which need opposite repairs (Actors::FlipEmbeddingModel).
    # @return [Hash{String => Integer}] per-model missing count
    def self.missing_in_space(organisation:, space:, require_indexed: true)
      TARGETS.to_h do |target|
        klass = target[:model].constantize
        scope = klass.where(organisation_id: organisation.id)
        [target[:model], scope.where(missing_readable_row_sql(klass, require_indexed:), *space.values_at(
          :embedding_provider, :embedding_model, :embedding_dims
        )).count]
      end
    end

    # "No readable row in the target triple" — readable means the FULL triple AND
    # `indexed`, i.e. exactly the three predicates Embeddings::NearestNeighbors filters
    # on (what Embeddings::SpaceAlignment calls `stranded`). The `indexed` term became
    # load-bearing with PR 6a: retirement is the first writer that clears the flag, and
    # without it a retired row would read as a finished re-index while the read seam
    # cannot see it.
    def self.missing_readable_row_sql(klass, require_indexed: true)
      <<~SQL.squish
        NOT EXISTS (
          SELECT 1 FROM content_embeddings ce
          WHERE ce.embeddable_type = #{klass.connection.quote(klass.name)}
            AND ce.embeddable_id   = #{klass.table_name}.id
            AND ce.embedding_provider = ?
            AND ce.embedding_model    = ?
            AND ce.embedding_dims     = ?
            #{'AND ce.indexed' if require_indexed}
        )
      SQL
    end

    # Entry point per the app/services convention (CLAUDE.md): keyword args only.
    # Migrated off the positional-argument legacy allowlist in PR 6a, which changed this
    # file substantially — the Boy-Scout rule asks for the migration at that point rather
    # than a bigger one later.
    # @return [Hash{String => Result}] per-model summary
    def self.call(**kwargs)
      new(**kwargs).call
    end

    # @param force [Boolean] re-embed EVERY row (heals pre-backfill source_hash drift)
    # @param delta [Boolean] additionally re-embed rows whose SOURCE TEXT has drifted
    #   since they were embedded (source_hash mismatch) — the roll-back and healing
    #   mode (PR 6a, sheet §4.6). A SUPERSET of the default, not an alternative to it:
    #   a mode that found only drift would skip exactly the records created since the
    #   switch, which is the bulk of what a roll-back has to catch up on.
    # @param target_space [EmbeddingSpace, nil] re-embed into THIS held space instead of
    #   the org's configured one — the roll-back path (PR 6a). Its provider is built
    #   from the space's own credential snapshot (B2), and its TRIPLE is taken from the
    #   row rather than derived from the provider: OpenAiProvider and
    #   GoogleVertexProvider answer #default_embedding_model from a constant, so
    #   deriving it would stamp rows into today's space while claiming to rebuild an
    #   older one (sheet §0.1, the same trap as on the read side).
    # @param metered [Boolean] does this run go on the ORGANISATION's bill? REQUIRED,
    #   deliberately without a default — the same reasoning that keeps `space:`
    #   defaultless one layer down (app/services/lalabase/CLAUDE.md §4): both
    #   possible defaults fail SILENTLY, an ArgumentError does not.
    #
    #   `true` is the customer-triggered switch (Actors::SelectAiPackage → the job):
    #   they chose the package, they pay for the re-embedding (E6).
    #   `false` is every OPERATOR path — the rake tasks and DefaultModelMigrator's
    #   ada-002 rollout. Those runs happen because WE changed something; billing a
    #   customer's monthly quota for our own migration would also push them into the
    #   quota gate, i.e. break their chat and search as a side effect of our repair.
    #   Unmetered still means unmetered, not free: the spend is real, it is simply
    #   not attributed to the org's budget.
    def initialize(organisation:, metered:, provider: nil, force: false, delta: false, target_space: nil,
                   logger: Rails.logger)
      raise ArgumentError, 'force and delta are mutually exclusive (force is the superset)' if force && delta

      # Cross-tenant guard (review finding R4), same reason as in
      # Lalabase::Llm::Factory.for_embedding_space: a foreign space would supply its
      # credentials and its triple to THIS org's rows.
      if target_space && target_space.organisation_id != organisation.id
        raise ArgumentError,
              "target_space #{target_space.id} does not belong to organisation #{organisation.id}"
      end

      @organisation = organisation
      @metered = metered
      @provider = provider
      @force = force
      @delta = delta
      @target_space = target_space
      @logger = logger
      # Both summed across ALL four tables, not per table: the booking is ONE row per
      # run (E6), so its counters have the run's lifetime too. They are accumulated
      # rather than derived from the per-table results because the booking has to
      # survive an ABORT, where those results do not exist (see #call).
      @total_tokens = 0
      @reindexed = 0
    end

    # @return [Hash{String => Result}] per-model summary
    def call
      ActsAsTenant.with_tenant(@organisation) do
        TARGETS.to_h { |target| [target[:model], reindex_target(target)] }
      ensure
        # ensure, not a trailing call: a run that dies on table 4 has already PAID
        # for tables 1-3. Booking only on the happy path would drop that spend
        # silently — and P4d's watcher re-drives an unfinished switch, so the same
        # tokens would be lost again on every attempt. Exactly the blind cost path
        # this slice exists to close, reintroduced through the error case.
        #
        # It stays ONE write path (not a second one in a rescue) precisely because
        # the counters above are accumulators.
        record_run_usage
      end
    end

    private

    def provider
      # :configured — the reindexer BUILDS the target space (PR 6a). Reading :active
      # here would make it re-embed into the space it is supposed to replace, and the
      # flip's anti-join would then never pass. With target_space: the provider comes
      # from THAT space's credential snapshot instead (roll-back, B2).
      @provider ||= if @target_space
                      Lalabase::Llm::Factory.for_embedding_space(@target_space, @organisation)
                    else
                      Lalabase::Llm::Factory.for_embeddings(@organisation, space: :configured)
                    end
    end

    # The space being written to. With target_space: the ROW is the authority; without
    # it the provider is (the configured space's triple is only known once built).
    # See the note on #initialize for why the row must not be re-derived.
    def target_triple
      @target_triple ||= @target_space&.triple ||
                         Lalabase::Indexer::EmbeddingColumns.from(provider)
    end

    def target_provider_name
      target_triple[:embedding_provider]
    end

    def target_model
      target_triple[:embedding_model]
    end

    def target_dims
      target_triple[:embedding_dims]
    end

    def reindex_target(target)
      klass = target[:model].constantize
      total = scope(klass).count
      reindexed = 0
      drifted = 0
      candidates(klass).find_in_batches(batch_size: BATCH_SIZE) do |records|
        batch, batch_drifted = select_for_embedding(records, target)
        drifted += batch_drifted
        next if batch.empty?

        reindexed += reembed_batch(batch, target)
      end

      Result.new(reindexed: reindexed, skipped: total - reindexed, total: total,
                 stale_reembedded: @delta ? drifted : nil).tap do |result|
        @logger.info("[embeddings:reindex] #{klass.name} org=#{@organisation.id} " \
                     "reindexed=#{result.reindexed} skipped=#{result.skipped} total=#{result.total} " \
                     "stale_reembedded=#{result.stale_reembedded.inspect} mode=#{mode_label} " \
                     "target=#{target_provider_name}/#{target_model}/#{target_dims}")
      end
    end

    # Splits a batch into "must be embedded" and counts how many of those are DRIFT
    # (as opposed to plain build work). Outside delta mode nothing is filtered and the
    # drift count is 0 — the concept does not apply there.
    #
    # In delta mode the SQL candidate set is the whole corpus (see #candidates), so the
    # decision happens here, against ONE batched lookup of the target rows: no readable
    # target row → build; row present but its source_hash no longer matches the current
    # text → drift; otherwise skip.
    #
    # @return [Array(Array<ActiveRecord::Base>, Integer)] [records to embed, drift count]
    def select_for_embedding(records, target)
      return [records, 0] unless @delta

      hashes = target_source_hashes(records)
      drifted = 0
      to_embed = records.select do |record|
        stored = hashes[record.id]
        next true if stored.nil? # no readable row in the target space → build

        current = ContentEmbedding.source_hash_for(record.public_send(target[:text]))
        drifted += 1 if stored != current
        stored != current
      end
      [to_embed, drifted]
    end

    # source_hash of the READABLE target-space row per record id, in one query over
    # idx_content_embeddings_unique_space. `indexed` is part of the filter for the same
    # reason it is part of #stale: a retired row is not one the reader can see, so a
    # matching hash on it must not count as "already done".
    def target_source_hashes(records)
      ContentEmbedding.where(embeddable_type: records.first.class.name,
                             embeddable_id: records.map(&:id),
                             organisation_id: @organisation.id,
                             indexed: true,
                             embedding_provider: target_provider_name,
                             embedding_model: target_model,
                             embedding_dims: target_dims)
                      .pluck(:embeddable_id, :source_hash).to_h
    end

    def mode_label
      return 'force' if @force

      @delta ? 'delta' : 'build'
    end

    def scope(klass)
      klass.where(organisation_id: @organisation.id)
    end

    # The SQL candidate set per mode:
    #
    #   force  → every row. Heals PRE-BACKFILL source_hash drift that even delta mode
    #            cannot see: the one-off inline→sidecar backfill (PR 3, removed in
    #            PR 7) stamped the CURRENT-text hash onto already-embedded rows, so
    #            their hash matches while their vector is old (main plan §5.2 / §4.4).
    #            The backfill is gone; the rows it stamped are not.
    #   delta  → every row as well, because the drift question is not expressible in
    #            SQL (SHA-256 over the exact Ruby string). #select_for_embedding makes
    #            the per-record decision against one batched hash lookup; the scan is
    #            over rows, not over embeddings, and only true drift costs tokens.
    #   build  → only records with no readable row in the target space.
    def candidates(klass)
      @force || @delta ? scope(klass) : stale(klass)
    end

    # A record is stale when it has no READABLE sidecar row in the TARGET triple —
    # the exact question the read seam asks. Readable is what
    # Embeddings::SpaceAlignment calls `stranded` (space_alignment.rb:22-23): the
    # full triple AND `indexed`. The `indexed` predicate is load-bearing even though
    # no writer sets it to false TODAY — PR 6 (retention, pointer flips) turns
    # exactly this flag, and without it a retired row would look like a finished
    # re-index while the read seam cannot see it: "reindexed 0" against a red gate,
    # the very failure mode §3.3 exists to kill.
    #
    # Anti-join over idx_content_embeddings_unique_space. A corpus with no sidecar
    # rows is re-embedded in full — correct (without them it has been unreadable
    # since PR 4b), but it costs tokens. For an aligned org the switch BACK stays
    # cheap: the old space's rows are still there, so only records created since the
    # switch are re-embedded.
    #
    # ONE source with .missing_in_space (PR 6a): the flip validation asks the very same
    # question against the target space, and two hand-written copies of a predicate
    # that must agree with the read seam forever is how they stop agreeing.
    def stale(klass)
      scope(klass).where(self.class.missing_readable_row_sql(klass),
                         target_provider_name, target_model, target_dims)
    end

    def reembed_batch(records, target)
      # model: is passed explicitly for the same reason Lalabase::QueryEmbedding passes
      # it (sheet §0.1): OpenAiProvider and GoogleVertexProvider ignore the configured
      # model and answer #default_embedding_model from a constant. On the configured
      # path this is a no-op (the triple was derived from that very provider); on the
      # roll-back path it is what makes the vectors actually belong to the space they
      # are stamped with.
      # The METERING variant since P4a+ (E6): P4a makes this path customer-
      # triggerable, and until now it spent tokens on the system credential
      # without writing an AiUsage row at all (plan §2.4 finding 1). Tokens are
      # summed here and booked ONCE in #record_run_usage — record_embedding is
      # built for one row per run (usage_tracking.rb), not one per batch.
      result = provider.embed_batch_with_usage(
        texts: records.map { |record| record.public_send(target[:text]) }, model: target_model
      )
      vectors = result[:embeddings]
      # Counted BEFORE the size check on purpose: a provider that returned the wrong
      # number of vectors still burned the tokens. #call books from an `ensure`, so
      # this count survives the raise below instead of being lost with the run.
      @total_tokens += result[:total_tokens].to_i
      raise count_mismatch(vectors, records, target) unless vectors.size == records.size

      triple = target_triple
      sidecar_rows = records.zip(vectors).map do |record, vector|
        {
          organisation_id: record.organisation_id,
          embeddable_type: record.class.name, embeddable_id: record.id,
          **triple,
          embedding: vector,
          source_hash: ContentEmbedding.source_hash_for(record.public_send(target[:text])),
          indexed: true, embedded_at: Time.current
        }
      end
      # Upsert (not insert): the record's write path may already have created the
      # triple row, so re-embedding UPDATES it (vector/source_hash/embedded_at)
      # rather than colliding on the unique index.
      #
      # No explicit transaction since PR 7: this batch used to write TWO places (the
      # inline update_columns and the sidecar), and the m1 bracket held them together.
      # One upsert_all is atomic by itself. embed_batch still runs ABOVE this, so the
      # API latency never holds row locks; a restart stays idempotent via the stale skip.
      ContentEmbedding.upsert_all(sidecar_rows, unique_by: :idx_content_embeddings_unique_space) if sidecar_rows.any?
      @reindexed += records.size
      records.size
    end

    # ONE AiUsage row for the whole reindex (E6, decision 2026-08-03: the CUSTOMER's
    # switch is both RECORDED and CHARGED against the org's monthly quota). Mirrors
    # EmbeddingProcessingService#record_run_usage — same action, same "one row per
    # run" contract, so the reindex shows up in the same aggregation as ordinary
    # indexing instead of as a category of its own.
    #
    # An UNMETERED run writes nothing at all. The alternative — book the row but
    # exempt it from the quota — would need a second action key and a second
    # costing rule, and would put an operator's migration into the customer's usage
    # view as if they had caused it. What an operator spends belongs in operator
    # tooling (`rake embeddings:status`), not on the customer's bill.
    #
    # Even for a metered run, whether the credits COUNT is decided further in, by
    # the credential of the space that served the call (AiUsage#quota_counted hangs
    # on included_in_quota): a BYOK org is logged but not billed. That asymmetry is
    # inherited from the bestand and is the right one — we are not paying for their
    # tokens.
    #
    # Skipped on a zero-token run so an already aligned org — the idempotent
    # re-run, and the COMMON case once P4d's watcher re-drives an unfinished
    # switch — does not leave a stream of empty usage rows behind.
    #
    # It does NOT save the provider build: #stale resolves the target triple
    # through #provider on every run, no-op included. The guard is about the row,
    # not about the credential resolution.
    def record_run_usage
      return unless @metered
      return if @total_tokens.zero?

      Lalabase::Llm::UsageTracking.record_embedding(
        organisation: @organisation, provider: provider, total_tokens: @total_tokens,
        action: Lalabase::Llm::ActionRegistry::DOCUMENT_INDEXING,
        model: target_model, subject: @organisation, call_type: 'organisation_reindex',
        # The parameter is named for its first caller (document fragments); here it
        # carries the reindexed RECORD count across the four tables. Same meaning —
        # how many items this run embedded — so it stays one metadata key rather
        # than a second one that means the same thing.
        fragment_count: @reindexed
      )
    end

    def count_mismatch(vectors, records, target)
      "embed_batch returned #{vectors.size} vectors for #{records.size} #{target[:model]} rows"
    end
  end
end
