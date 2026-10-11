# frozen_string_literal: true

# Embedding v2 PR 3 — daily orphan reclamation for embedding rows (details on the class).
module Embeddings
  # Daily reclamation of embedding rows whose owner no longer exists (embedding
  # v2 PR 3, main plan §6.2 point 1 — M4). Three sweeps:
  #   1. sidecar orphans  — content_embeddings rows whose embeddable is gone
  #      (parent delete_all / bulk purges are callback-free by design, PR-2 §3.5)
  #   2. fragment orphans — fragments whose polymorphic fragmentable is gone
  #      (EPS destroy-mid-run race leftovers; their sidecar rows are NOT orphans
  #      in sense 1, so sweep 1 alone would never reclaim them)
  #   3. retention      — whole vector SPACES an org no longer needs (PR 6b): the
  #      rows of every held space beyond organisations.embedding_retention_limit,
  #      plus the embedding_spaces row itself. Unlike 1/2 this sweep is ORG-BOUND
  #      and policy-driven — retention is a per-org setting, not global tidying —
  #      and it deletes INTACT vectors (the roll-back net), not rows whose owner is
  #      provably gone. That difference is why it carries its OWN safety switch
  #      (`retention_dry_run`, EMBEDDINGS_RETENTION_ENFORCE on the job): arming the
  #      orphan sweep must not silently arm the deletion of whole spaces.
  # GDPR: the daily cadence bounds how long derived vectors + source hashes of
  # DELETED content persist to ≤ 24h (PII paths purge synchronously and never
  # wait for this job).
  #
  # SCOPE — `organisation: nil` (the recurring job's default) runs ONE GLOBAL sweep
  # across every org via ActsAsTenant.without_tenant. This is a DELIBERATE exception
  # to the "without_tenant only in admin, never user-facing" rule: a system
  # maintenance job with no user-facing read path, deleting ONLY rows whose owner is
  # DB-provably gone (owner ids are globally-unique UUID PKs, so the NOT EXISTS
  # anti-join is correct cross-org) — tenant-agnostic and safe. `organisation: org`
  # keeps the org-scoped path (with_tenant) that `rake embeddings:gc[org_id]` and the
  # status probe rely on. Either way, reclaimed counts are logged PER ORG (GDPR
  # deletion attribution — a global run must not collapse to one anonymous total).
  class OrphanGc
    BATCH_SIZE = 5_000

    # Sweep 1 targets — the embeddable types that carry sidecar rows: the SAME four
    # inline tables the backfill copies (ONE source: the reindexer TARGETS). A
    # reflection spec pins this against `has_many :content_embeddings, as: :embeddable`
    # so a new embeddable type cannot silently escape the sweep.
    EMBEDDABLE_SOURCES = OrganisationReindexer::TARGETS.map { |target| target[:model] }.freeze

    # Sweep 2 targets — every polymorphic fragmentable owner (`has_many :fragments,
    # as: :fragmentable`). A dead owner leaves its fragments (+ their sidecar) behind
    # only via a race / callback-free bulk delete; a reflection spec pins this list
    # too, so a NEW owner type breaks the spec instead of leaking PII past the GC.
    FRAGMENTABLE_SOURCES = %w[
      Note Meeting MeetingAnalysis Ticket DocumentationPage
      Post PostDocument TicketDocument DocumentVersion
    ].freeze

    Result = Struct.new(:orphan_embeddings, :orphan_fragments, :retention_spaces,
                        :retention_embeddings, :retention_skipped, :errors, keyword_init: true)

    def self.call(organisation: nil, dry_run: false, retention_dry_run: dry_run, logger: Rails.logger)
      new(organisation:, dry_run:, retention_dry_run:, logger:).call
    end

    # @param retention_dry_run [Boolean] the SEPARATE switch for sweep 3. Defaults to
    #   `dry_run`, so an explicit caller (the rake task, the status probe) keeps saying
    #   what it means with ONE argument. Only the daily job sets it apart, because only
    #   there does the difference matter: arming orphan reclamation and arming the
    #   deletion of whole vector spaces are two different decisions about two very
    #   different blast radii.
    def initialize(organisation: nil, dry_run: false, retention_dry_run: dry_run, logger: Rails.logger)
      @organisation = organisation
      @dry_run = dry_run
      @retention_dry_run = retention_dry_run
      @logger = logger
      @errors = 0
      @retention_skipped = 0
    end

    # @return [Result] reclaimed (or, when dry_run, would-reclaim) counts + error tally
    def call
      if @organisation
        ActsAsTenant.with_tenant(@organisation) { run_sweeps }
      else
        # Global maintenance mode — see the SCOPE note on the class. without_tenant
        # lifts require_tenant thread-locally AND unscopes the queries so a single
        # sweep spans every org (DueDateBackfillService precedent).
        ActsAsTenant.without_tenant { run_sweeps }
      end
    end

    private

    def run_sweeps
      # Schema-level probe: runs ONCE per invocation, not per org — it inspects the
      # type column (a schema property), not tenant data.
      warn_unknown_types
      # Sweep 2 BEFORE Sweep 1: should a fragment purge ever leave a sidecar row
      # behind, Sweep 1 catches it in the SAME run.
      orphan_fragments = sweep_fragment_orphans
      orphan_embeddings = sweep_sidecar_orphans
      # Sweep 3 LAST: it walks live spaces, so it should see a corpus the orphan
      # sweeps have already cleaned — an orphan row in an old space would otherwise
      # inflate the row count this sweep reports for it.
      retention_spaces, retention_embeddings = sweep_retention
      # AFTER all three sweeps, for the same reason sweep 3 runs last: the warning
      # reports what SURVIVES this run. Emitted first, it would count orphan rows in
      # unregistered triples that sweep 1 deletes moments later — an operator would
      # chase residue that is already gone. Run last it also names, in the SAME run,
      # rows a just-collected space left behind (a concurrent insert racing the
      # batched delete) instead of one night later.
      warn_unregistered_spaces
      log_error_summary
      Result.new(orphan_embeddings:, orphan_fragments:, retention_spaces:,
                 retention_embeddings:, retention_skipped: @retention_skipped, errors: @errors)
    end

    def sweep_sidecar_orphans
      sweep_each_type('sidecar', EMBEDDABLE_SOURCES) do |klass|
        orphans = ContentEmbedding.where(embeddable_type: klass.name).where(<<~SQL.squish)
          NOT EXISTS (SELECT 1 FROM #{klass.table_name} t
                      WHERE t.id = content_embeddings.embeddable_id)
        SQL
        reclaim_per_org('sidecar', klass.name, orphans) { |batch| delete_in_batches(batch) }
      end
    end

    def sweep_fragment_orphans
      sweep_each_type('fragment', FRAGMENTABLE_SOURCES) do |klass|
        orphans = Fragment.where(fragmentable_type: klass.name).where(<<~SQL.squish)
          NOT EXISTS (SELECT 1 FROM #{klass.table_name} t
                      WHERE t.id = fragments.fragmentable_id)
        SQL
        reclaim_per_org('fragment', klass.name, orphans) { |batch| purge_fragments_in_batches(batch) }
      end
    end

    # Sweep 3 — retention (PR 6b). Per ORG, and per org ISOLATED: a failure on org 3 of
    # 200 must not cost the remaining 197 their cleanup, the same reason sweeps 1/2
    # isolate per type.
    #
    # @return [Array(Integer, Integer)] [spaces collected, sidecar rows collected]
    def sweep_retention
      spaces = 0
      rows = 0
      retention_organisations.find_each do |organisation|
        collected_spaces, collected_rows = collect_spaces_for(organisation)
        spaces += collected_spaces
        rows += collected_rows
      rescue StandardError => e
        report_retention_error(organisation.id, nil, e)
      end
      [spaces, rows]
    end

    # Only orgs holding MORE than one space are examined. For an org whose single space
    # IS its active one (production's steady state) there is nothing to decide, and the
    # filter also keeps the sweep from resolving a configured space (a provider build,
    # and a possible raise) where the answer cannot matter. KNOWN EXEMPTION (review
    # NEW-3): an org holding exactly ONE space with a NULL pointer (build_target run but
    # never flipped, or a pointer the on-delete FK nullified) is skipped too, even
    # though that space can be a legal candidate at limit = 1 — accepted, it errs in
    # the conservative direction (keep, not delete), the fail-safe stance of this sweep.
    def retention_organisations
      counts = scoped_spaces.group(:organisation_id).count
      Organisation.where(id: counts.select { |_org_id, count| count > 1 }.keys)
    end

    # The retention decision for ONE org. Two protections, and their ORDER is the whole
    # point (main plan §6.2, m3):
    #
    #   - The ACTIVE space is never a candidate, not even at limit = 1. At 1 the keep
    #     list is simply empty and everything else goes.
    #   - A space UNDER CONSTRUCTION is removed BEFORE the keep list is taken, not
    #     after, so it does not consume one of the retained slots. Taken after, a build
    #     at the default limit of 2 would evict exactly the old space that the A/B
    #     comparison exists to compare against.
    #
    # "Under construction" = the org's CONFIGURED triple while it is not the active one
    # (main plan §11.3 rejected a status table, and a timestamp heuristic would age a
    # quota-paused build out of its own protection). Known and accepted consequence:
    # after a roll-back, configured ≠ active PERMANENTLY, so the rolled-back-from space
    # stays protected until an operator moves the configuration back. That is the
    # conservative direction of the error.
    #
    # KNOWN GAP (review F3, accepted 2026-08-02): while `embeddings:rollback` runs its
    # first two steps (reactivation + delta reindex — corpus-length work), the rollback
    # TARGET is temporarily neither active nor configured and is therefore a legal
    # candidate here (reachable at limit >= 3, or when this sweep overlaps that
    # window). The ops doc tells operators to keep rollbacks out of the GC window; the
    # 6c admin flow, which orchestrates rollback, closes this structurally.
    #
    # The org is RE-READ first (review C2): find_each hands this method an instance
    # loaded up to a whole batch earlier, so its pointer can be minutes stale — and the
    # flip NULLs retired_at on the space it activates, which under a stale reject list
    # would sort the freshly serving space to the FRONT of the doomed list.
    def collect_spaces_for(stale_organisation)
      organisation = Organisation.find_by(id: stale_organisation.id)
      return [0, 0] if organisation.nil?

      configured = configured_triple(organisation)
      if configured.nil?
        @retention_skipped += 1
        return [0, 0]
      end

      active_id = organisation.active_embedding_space_id
      candidates = ordered_spaces(organisation).reject do |space|
        space.id == active_id || space.triple == configured
      end
      collect_doomed(organisation, candidates.drop(retention_slots(organisation)))
    end

    # Per-SPACE isolation, mirroring the per-org isolation one level up: a failure on
    # space 2 of 3 must neither abort space 3 nor discard space 1's counts — the Result
    # feeds the GDPR attribution the rake task prints, and rows that WERE deleted must
    # not report as zero because a later space raised (review F6).
    def collect_doomed(organisation, doomed)
      spaces = 0
      rows = 0
      doomed.each do |space|
        collected_spaces, collected_rows = collect_space(space)
        spaces += collected_spaces
        rows += collected_rows
      rescue StandardError => e
        report_retention_error(organisation.id, space, e)
      end
      [spaces, rows]
    end

    # The limit counts the ACTIVE space too ("keep the active one plus N−1 older"), so
    # the candidate list keeps limit − 1 of them.
    def retention_slots(organisation)
      [organisation.embedding_retention_limit - 1, 0].max
    end

    def ordered_spaces(organisation)
      EmbeddingSpace.where(organisation_id: organisation.id).by_retirement_recency.to_a
    end

    # Fail-SAFE, not fail-open: without the configured triple this sweep cannot tell a
    # space under construction from an abandoned one, and guessing would collect a space
    # that is being built RIGHT NOW. An org whose embedding configuration does not
    # resolve (no credential, unknown provider, undecryptable token) is skipped entirely
    # and named in the log — the same stance Embeddings::SpaceAlignment takes on the
    # same failure. Not tallied as an ERROR (it is a state of the org, not a bug here),
    # but the decision-phase skip IS counted in Result#retention_skipped (review F5):
    # without that, a fleet-wide resolution failure — a factory signature change, AI
    # disabled everywhere — would read as spaces=0, indistinguishable from "nothing to
    # do", and retention would be a permanent silent no-op.
    #
    # @return [Hash, nil] the configured triple, or nil when it does not resolve
    def configured_triple(organisation)
      ::Lalabase::Llm::Factory.embedding_space_for(organisation, space: :configured)
    rescue StandardError => e
      @logger.warn("[embeddings:gc] org=#{organisation.id} sweep=retention SKIPPED — configured space " \
                   "not resolvable (#{e.class}: #{e.message})")
      nil
    end

    # @return [Array(Integer, Integer)] [spaces collected (0/1), sidecar rows collected
    #   (or, in dry-run, that would be)]. A spared space counts 0 — but rows a spare at
    #   destroy time could no longer save are reported honestly, not hidden.
    def collect_space(space)
      rows = space.content_embeddings
      if @retention_dry_run
        count = rows.count
        log_retention(space, count)
        return [1, count]
      end

      unless still_doomed?(space)
        @logger.info("[embeddings:gc] org=#{space.organisation_id} sweep=retention " \
                     "space=#{space.label} SPARED before delete — became active or configured " \
                     'since the sweep decided')
        return [0, 0]
      end

      deleted = delete_in_batches(rows)
      unless destroy_space_if_still_doomed(space)
        @logger.warn("[embeddings:gc] org=#{space.organisation_id} sweep=retention " \
                     "space=#{space.label} SPARED at destroy — became active or configured " \
                     "mid-collect; #{deleted} rows were already removed, a delta reindex restores them")
        return [0, deleted]
      end

      log_retention(space, deleted)
      [1, deleted]
    end

    # Cheap re-check before the expensive part (review C2): the decision in
    # #collect_spaces_for read a fresh org row, but earlier spaces' batched deletes run
    # between that decision and this space's turn. One single-row read plus one local
    # provider build per doomed space buys that window back. Not a race-proof
    # guarantee — the authoritative check is #destroy_space_if_still_doomed under the
    # org row lock; this one keeps the batch delete from emptying a space that has
    # visibly stopped being doomed.
    def still_doomed?(space)
      organisation = Organisation.find_by(id: space.organisation_id)
      return false if organisation.nil?
      return false if organisation.active_embedding_space_id == space.id

      fresh_configured = configured_triple(organisation)
      !fresh_configured.nil? && fresh_configured != space.triple
    end

    # The authoritative half of the C2 re-check, under the SAME row lock the flip and
    # RetireSpaceJob take (R1/R5) — this sweep is the third participant in that
    # protocol, and the only one that DELETES. Deciding again inside the lock turns
    # "GC deletes the serving space" into "GC leaves a partially emptied space behind",
    # which the next build/delta reindex repairs; the on_delete: :nullify FK would have
    # made the wrong outcome SILENT (pointer nulled, org-wide zero hits, no error).
    # Rows FIRST, space row second stays the order: interrupted in between, the space is
    # simply a candidate again next run; the reverse order would strand its rows in a
    # triple no space row names any more. The fresh configured re-check also closes the
    # EnsureSpace window (review NEW-4): a build re-adopting this triple mid-collect
    # keeps its just-refreshed row instead of losing it. NOT claimed: a two-connection
    # race proof — the specs pin the mechanics only.
    def destroy_space_if_still_doomed(space)
      ActiveRecord::Base.transaction do
        locked = Organisation.lock.find_by(id: space.organisation_id)
        # Org gone: the FK cascade removed the space with it; nothing left to destroy.
        next false if locked.nil?
        next false if locked.active_embedding_space_id == space.id

        fresh_configured = configured_triple(locked)
        # nil = the configuration stopped resolving mid-run: fail-safe, keep the space.
        next false if fresh_configured.nil? || fresh_configured == space.triple

        space.destroy!
        true
      end
    end

    # Sidecar rows whose triple belongs to NO embedding_spaces row of their org. No
    # sweep can see them: their record is alive (not an orphan) and no space row names
    # their triple (not a retention candidate). They are the residue of every model
    # switch that happened BEFORE spaces existed — on production the bulk of what
    # `embeddings:status` reports as `stale`.
    #
    # COUNTED AND WARNED, never deleted, exactly like #warn_unknown_types. A triple
    # without a space row is not proof of abandonment: it is also what a freshly
    # configured target looks like in the window before `embeddings:build_target`
    # registers it, so deleting on that suspicion would race a build. Naming them keeps
    # the honest expectation — this GC does NOT reclaim them — from having to be
    # rediscovered during an incident.
    def warn_unregistered_spaces
      held = scoped_spaces.pluck(:organisation_id, :embedding_provider, :embedding_model, :embedding_dims).to_set
      scoped_embeddings.group(:organisation_id, :embedding_provider, :embedding_model, :embedding_dims)
                       .count.each do |key, count|
        next if held.include?(key)

        org_id, provider, model, dims = key
        @logger.warn("[embeddings:gc] org=#{org_id} UNREGISTERED space #{provider}/#{model}/#{dims} " \
                     "rows=#{count} — no embedding_spaces row holds this triple, so no sweep reclaims it")
      end
    end

    def scoped_spaces
      @organisation ? EmbeddingSpace.where(organisation_id: @organisation.id) : EmbeddingSpace.all
    end

    def scoped_embeddings
      @organisation ? ContentEmbedding.where(organisation_id: @organisation.id) : ContentEmbedding.all
    end

    # Per-TYPE isolation (#2): each type sweeps inside its own begin/rescue, so one
    # broken type (bad constant, SQL error) neither aborts the remaining types nor
    # the other sweep. The failure is reported with exception class + backtrace (this
    # app's error-reporter convention — Rails.logger, ScheduledDeletionJob precedent;
    # there is no Sentry/Rails.error.report here) and TALLIED; the run finishes and
    # surfaces the count in the Result.
    def sweep_each_type(sweep, types)
      types.sum do |type|
        yield(type.constantize)
      rescue StandardError => e
        report_sweep_error(sweep, type, e)
        0
      end
    end

    # Reclaims a type's orphans in ONE batched pass over the whole scope, but logs the
    # reclaimed counts PER ORG (GDPR deletion attribution — a global run must not
    # collapse to a single anonymous total). The per-org breakdown is a GROUP BY taken
    # BEFORE the delete (best-effort attribution); in dry_run nothing is deleted and
    # the counts equal a real run (no silent caps). Deliberately a single global delete
    # rather than a per-org delete loop — same reclaimed rows, one pass, no per-tenant
    # N+1.
    # @return [Integer] total reclaimed (or would-reclaim) across all orgs for this type
    def reclaim_per_org(sweep, type, scope)
      per_org = scope.group(:organisation_id).count.reject { |_org_id, count| count.zero? }
      per_org.each { |org_id, count| log(sweep, type, org_id, count) }
      return per_org.values.sum if @dry_run

      yield(scope)
    end

    def delete_in_batches(scope)
      deleted = 0
      scope.in_batches(of: BATCH_SIZE) { |batch| deleted += batch.delete_all }
      deleted
    end

    def purge_fragments_in_batches(scope)
      deleted = 0
      scope.in_batches(of: BATCH_SIZE) do |batch|
        ActiveRecord::Base.transaction do
          # Sidecar first — the subselect needs the fragment rows (purge_for
          # contract); the fragments' has_many cascade does NOT fire on delete_all.
          ContentEmbedding.purge_for(embeddable_type: 'Fragment', embeddable_ids: batch.select(:id))
          deleted += batch.delete_all
        end
      end
      deleted
    end

    # Defensive: a fragmentable/embeddable type present in the DB but NOT in the maps
    # above is COUNTED and WARNED, never deleted — a new owner type must be added
    # deliberately, not swept on a guess.
    def warn_unknown_types
      Fragment.where.not(fragmentable_type: FRAGMENTABLE_SOURCES).group(:fragmentable_type).count
              .each { |type, count| warn_unknown('fragmentable_type', type, count, 'FRAGMENTABLE_SOURCES') }
      ContentEmbedding.where.not(embeddable_type: EMBEDDABLE_SOURCES).group(:embeddable_type).count
                      .each { |type, count| warn_unknown('embeddable_type', type, count, 'EMBEDDABLE_SOURCES') }
    end

    def warn_unknown(column, type, count, constant)
      @logger.warn("[embeddings:gc] UNKNOWN #{column}=#{type} count=#{count} — not swept (add it to #{constant})")
    end

    def report_sweep_error(sweep, type, error)
      @errors += 1
      @logger.error("[embeddings:gc] sweep=#{sweep} type=#{type} FAILED: #{error.class}: #{error.message}")
      @logger.error(error.backtrace&.first(5)&.join("\n"))
    end

    # Sweep 3's error reporter: same tally + backtrace contract as #report_sweep_error,
    # but sweeps 1/2's `type=` slot would here carry an organisation UUID — misleading
    # in the exact log an operator greps during an incident. `space` is nil when the
    # DECISION phase failed (before any space was touched).
    def report_retention_error(org_id, space, error)
      @errors += 1
      label = space ? " space=#{space.label}" : ''
      @logger.error("[embeddings:gc] sweep=retention org=#{org_id}#{label} FAILED: " \
                    "#{error.class}: #{error.message}")
      @logger.error(error.backtrace&.first(5)&.join("\n"))
    end

    def log_error_summary
      return unless @errors.positive?

      @logger.error("[embeddings:gc] completed with #{@errors} failed sweep type(s) — see errors above")
    end

    def log(sweep, type, org_id, count)
      verb = @dry_run ? 'orphans' : 'reclaimed'
      @logger.info("[embeddings:gc] org=#{org_id} #{type} sweep=#{sweep} #{verb}=#{count}")
    end

    # Per-org attribution for sweep 3, same GDPR reason as #log: a run must never
    # collapse into one anonymous total. The space LABEL travels with it because
    # "which space did we just delete" is the question an operator asks afterwards.
    def log_retention(space, count)
      verb = @retention_dry_run ? 'would-collect' : 'collected'
      @logger.info("[embeddings:gc] org=#{space.organisation_id} sweep=retention " \
                   "space=#{space.label} #{verb}=#{count}")
    end
  end
end
