# frozen_string_literal: true

# Embedding v2 gate — does the vector space the READ path resolves still match the
# space the stored sidecar rows were stamped with? (full mechanics on the class).
module Embeddings
  # Compares an organisation's stored content_embeddings provenance triples with the
  # vector space Embeddings::NearestNeighbors will actually query
  # (Lalabase::Llm::Factory.embedding_space_for).
  #
  # Why this exists (production incident 2026-07-30): the read seam filters on the
  # FULL triple (provider, model, dims) plus `indexed`. When the resolved triple and
  # the stamped triple diverge — rows stamped openai/text-embedding-ada-002/1536
  # while the factory resolves openai/text-embedding-3-small/1536 — every retrieval
  # query matches ZERO rows, silently. A completeness probe cannot see this: an
  # anti-join asks whether a record HAS a row, never whether that row is the one the
  # reader asks for. (Until PR 7 the inline→sidecar backfill carried exactly such a
  # probe, and it reported green through the incident.) From PR 5 on (768/1024 dims) a
  # model switch is routine, so this turns a one-off incident into a check that runs
  # before and after each switch.
  #
  # FIVE buckets, and exactly one of them is the finding:
  #
  #   aligned  — readable: the record HAS a row carrying the resolved triple AND
  #              `indexed` (the reader's third predicate).
  #   stale    — not readable, but the record also has a readable row. The normal
  #              aftermath of every reindex: OrganisationReindexer writes the new
  #              space and LEAVES the old rows behind. Since PR 6a the retirement takes
  #              them out of the INDEX (indexed -> false), so this count does not shrink
  #              at retirement. A check failing on those would stay red after exactly
  #              the repair it recommends.
  #              DELETED they are by the PR-6b retention GC — but ONLY where an
  #              embedding_spaces row still holds their triple. Rows left by a switch
  #              that predates spaces have no such row, so no sweep reclaims them and
  #              the GC logs them as UNREGISTERED rather than deleting on the suspicion
  #              (a triple without a space row is also what a fresh target looks like
  #              in the window before embeddings:build_target registers it).
  #   pending_flip — not readable in the ACTIVE space, but readable in the CONFIGURED
  #              one: content written during a staged switch (PR 6a). It reaches the
  #              reader the moment the flip happens, so it is NOT a finding — and
  #              counting it as stranded would make the gate red for the entire build
  #              window while recommending a reindex that does nothing (the row is
  #              already in the target space: "reindexed 0" against a red gate). Same
  #              reasoning that keeps `stale` out of the verdict.
  #              Out of the VERDICT, but NOT silent: it lifts severity to :warning, and
  #              the printed text names BOTH repairs. The identical data occurs after a
  #              ROLL-BACK, where the content stays unreachable and the flip would undo
  #              the roll-back — nothing in the schema tells the two apart, so this must
  #              not recommend one of them (review F-A).
  #   stranded — not readable, and not pending either: content the reader cannot reach
  #              and no flip will fix. THIS decides the verdict.
  #   orphan   — the row's record is gone entirely (callback-free `delete_all`, until
  #              the daily Embeddings::OrphanGc runs). Counted on its own and part of
  #              NONE of the four above: the read seam inner-joins the embeddable
  #              table (M1), so such a row is structurally invisible to it, and no
  #              reindex can repair it — the reindexer only walks LIVE records.
  #              Counted as stranded it would redden the gate forever while the
  #              printed fix is a no-op; counted as aligned it would inflate the
  #              healthy number. Its remedy is `rake "embeddings:gc[ORG]"`.
  #
  # The VERDICT additionally reads organisation.ai_enabled?, because the same finding
  # means different things depending on whether the org can act on it at all:
  #
  #   ai on  + stranded rows -> ERROR   repairable — reindex
  #   ai off + stranded rows -> WARNING a reindex raises AiDisabledError
  #                                     (Factory.for_embeddings gates); enable AI first
  #   ai on  + no space      -> ERROR   NearestNeighbors#initialize raises on EVERY
  #                                     query, PromptBuildingService rescues it and
  #                                     answers context-free with a log warning —
  #                                     the silent failure this object exists to catch
  #   ai off + no credential -> WARNING nothing reads these rows today
  #   any misconfiguration   -> ERROR   see SOFT_RESOLUTION_ERROR
  #
  # Read-only. The remedy for a misalignment is always a reindex
  # (`rake "embeddings:reindex[ORG]"`), never a relabel of the stamp: the stored
  # vectors really do belong to the old model.
  class SpaceAlignment
    # The ONE benign resolution failure: no credential at all, neither BYOK nor an
    # active system AiCredential.
    #
    # Note what an unresolvable space does NOT mean, because the obvious reading is
    # wrong: embedding_space_for is deliberately gate-free — it never looks at
    # ai_enabled, it only resolves a CREDENTIAL. Wherever an active system credential
    # exists (the production state) the space resolves for EVERY org, AI switched off
    # or not. Getting here therefore means "this installation has no embedding
    # credential", not "this org has AI turned off".
    #
    # Every OTHER failure — a provider that cannot embed at all
    # (Provider::NotSupportedError, e.g. an org whose embedding_provider is
    # 'anthropic'), an unknown provider name, a credential that fails to decrypt — is
    # a misconfiguration and must be seen, never filed under "AI is simply off".
    SOFT_RESOLUTION_ERROR = ::Lalabase::Llm::Factory::MissingCredentialError

    # "The record has a READABLE row in the space named by the binds" — readable meaning
    # the full triple AND `indexed`, all three predicates of Embeddings::NearestNeighbors,
    # none dropped. Since PR 6a the retirement is the writer that clears `indexed`; the
    # column default is FALSE and lalabase/indexer/symbol_persistence writes via a bare
    # insert_all, so the flag has always been part of the question.
    #
    # Used twice with different binds: negated against the ACTIVE space (is the record
    # unreachable?) and, for those rows, affirmatively against the CONFIGURED space (is it
    # merely waiting for the flip? — #pending_flip_groups).
    #
    # Bound parameters, no interpolation. The organisation_id correlation is explicit
    # because raw SQL bypasses the acts_as_tenant scope of the outer query — UUID keys
    # make a cross-org collision impossible today, and this keeps it that way without
    # relying on that.
    SIBLING_SQL = <<~SQL.squish
      EXISTS (
        SELECT 1 FROM content_embeddings sibling
        WHERE sibling.embeddable_type      = content_embeddings.embeddable_type
          AND sibling.embeddable_id        = content_embeddings.embeddable_id
          AND sibling.organisation_id      = content_embeddings.organisation_id
          AND sibling.embedding_provider   = :provider
          AND sibling.embedding_model      = :model
          AND sibling.embedding_dims       = :dims
          AND sibling.indexed
      )
    SQL
    NO_ACTIVE_SIBLING_SQL = "NOT #{SIBLING_SQL}".freeze

    # One (type, provider, model, dims, indexed) bucket of the org's sidecar rows —
    # the same grouping `rake embeddings:status` already prints (plus `indexed`, which
    # that listing reports as a second number), so the verdict below and that listing
    # can never tell different stories.
    #
    # `row_count`, not `count`: a Struct member named `count` would override
    # Struct#count (Enumerable) and make `group.count` mean something other than it
    # reads (Lint/StructNewOverride).
    Group = Struct.new(:embeddable_type, :embedding_provider, :embedding_model,
                       :embedding_dims, :indexed, :row_count, keyword_init: true) do
      # The provenance triple in the EXACT shape Factory.embedding_space_for returns,
      # so alignment is a plain Hash comparison and no key can drift apart. `indexed`
      # is deliberately NOT part of it: the triple names a SPACE, the flag says
      # whether the reader looks at the row (Result#readable? combines both).
      def triple
        { embedding_provider: embedding_provider, embedding_model: embedding_model,
          embedding_dims: embedding_dims }
      end

      # The unindexed suffix matters in the output: without it a row sitting in the
      # ACTIVE space would appear in the misaligned listing under a label identical
      # to the resolved space — and read as a bug in this check.
      def space_label
        label = "#{embedding_provider}/#{embedding_model}/#{embedding_dims}"
        indexed ? label : "#{label} [indexed=false]"
      end
    end

    # `status` is WHAT WAS FOUND, `severity` is WHAT THE GATE DOES about it. The split
    # is the point: an org that cannot be repaired must not fail a check whose printed
    # fix it is unable to run, and an org whose reads are broken must not pass one.
    #
    # Three states on purpose, not two. `:unresolved` (the factory could not resolve a
    # space at all) is NOT `:aligned` — nothing was compared — and NOT `:misaligned` —
    # nothing is proven wrong.
    # Ordering for #severity, which is the WORST of two independent judgements (the
    # triples and the credential) rather than a single case-branch.
    SEVERITY_RANK = { ok: 0, warning: 1, error: 2 }.freeze

    Result = Struct.new(:organisation, :space, :configured_space, :error, :error_class,
                        :credential_error, :credential_error_class,
                        :ai_enabled, :groups, :orphan_groups, :stranded_groups,
                        :pending_flip_groups, :pointer_state, keyword_init: true) do
      # True when configuration and serving name DIFFERENT spaces — an ongoing staged
      # switch. nil configured_space (unresolvable) counts as "no switch": without a
      # target space nothing can be pending for it.
      #
      # ⚠️ Structurally FALSE while #pointer_resolved? is false — both sides then come
      # from the same fallback derivation. That is not a bug in this predicate but the
      # reason #pointer_state exists next to it.
      def switch_in_progress?
        !configured_space.nil? && configured_space != space
      end

      def resolved?
        !space.nil?
      end

      # Whether `space` above came from the org's POINTER or from the fallback.
      #
      # #resolved? cannot answer this: embedding_space_for falls back to the configured
      # triple when no pointer row resolves, so it is true either way. The distinction
      # matters because an org serving off the fallback is fully functional TODAY and
      # still incapable of a staged switch — the failure only appears when it changes
      # package, at which point reads jump to the new empty space and no flip ever ends
      # it (KI-Pakete P4b precondition 3).
      #
      # nil means "not determined" (a Result built by hand in a spec), and reads as ok —
      # this must never turn an unrelated example red.
      def pointer_resolved?
        pointer_state.nil? || pointer_state == :resolved
      end

      # See SOFT_RESOLUTION_ERROR: only a missing credential is benign. Via
      # #ancestors, not `<=`: Module#<= answers nil (not false) for an unrelated
      # class, and a nil here would read as "not soft" only by accident.
      def soft_error?
        return false if error_class.nil?

        error_class.ancestors.include?(SOFT_RESOLUTION_ERROR)
      end

      # :misaligned hangs on STRANDED rows only — see the bucket list on the class for
      # why neither the broader misaligned_count nor the orphans may decide this.
      def status
        return :unresolved unless resolved?

        stranded_count.zero? ? :aligned : :misaligned
      end

      # @return [Symbol] :ok, :warning or :error — the matrix in the class comment.
      #
      # The WORSE of two independent judgements. #status only ever speaks about TRIPLES;
      # a space can name the right one and still be unservable because its credential is
      # gone. Folding the credential into #status instead would make an org "misaligned"
      # whose rows are all exactly where they belong, and send the operator into a
      # reindex that repairs nothing.
      def severity
        [space_severity, credential_severity].max_by { |level| SEVERITY_RANK.fetch(level) }
      end

      def space_severity
        case status
        when :aligned then aligned_severity
        when :misaligned then ai_enabled ? :error : :warning
        else unresolved_severity
        end
      end

      # The pin's own failure mode (P0): the serving space resolves, but the credential
      # it addresses is deleted, disabled or belongs to another provider, so every query
      # embedding raises MissingCredentialError. Same ai_enabled asymmetry as everywhere
      # else here — with AI off nothing reads, and an org with no rows has nothing to
      # lose either.
      def credential_severity
        return :ok if credential_error.nil?
        return :error if ai_enabled

        total_count.zero? ? :ok : :warning
      end

      # Aligned, but with content sitting in the configured space: NOT plain :ok
      # (review F-A, 2026-08-01).
      #
      # Configuration and serving diverge in two situations that look IDENTICAL in the
      # data — a switch on its way to the configured space, and a ROLL-BACK that
      # deliberately left it behind (the roll-back task says so itself: "the org
      # CONFIGURATION still points at the space you rolled away from"). In the first the
      # flip is the answer; in the second the flip would undo the roll-back, and the
      # answer is to put the configuration back.
      #
      # Nothing in the schema records which of the two it is, so this must not guess.
      # What it must not do either is report a green "ALIGNED" while content is
      # unreachable — which is what plain :ok did. :warning says "look at this" without
      # failing the gate on a legitimate intermediate state; the printed text names both
      # repairs (EmbeddingsRakeHelpers#pending_flip_note).
      def aligned_severity
        pending_flip_count.zero? ? :ok : :warning
      end

      # No space at all. Benign ONLY when the cause is a missing credential AND
      # nothing currently reads: with AI enabled a missing space means every
      # retrieval query raises (and gets swallowed), and any non-soft error is a
      # configuration fault whatever the AI switch says.
      def unresolved_severity
        return :error unless soft_error?
        return :error if ai_enabled

        total_count.zero? ? :ok : :warning
      end

      # The ONE authority for the gate's exit code.
      def blocking?
        severity == :error
      end

      # Strict: an unresolvable space is not proof of alignment. Callers that need to
      # tell the three cases apart read #status, callers that gate read #blocking?.
      def aligned?
        status == :aligned
      end

      # Exactly the reader's predicates: right space AND indexed.
      def readable?(group)
        group.indexed && group.triple == space
      end

      def aligned_groups
        resolved? ? groups.select { |group| readable?(group) } : []
      end

      # Every row the reader will not look at — another space, or the active space
      # with `indexed` cleared. Includes the harmless post-reindex leftovers, so this
      # is NOT the gate criterion.
      def misaligned_groups
        resolved? ? groups.reject { |group| readable?(group) } : []
      end

      # LIVE rows only; the orphans are counted separately and on purpose.
      def total_count
        groups.sum(&:row_count)
      end

      def aligned_count
        aligned_groups.sum(&:row_count)
      end

      def misaligned_count
        misaligned_groups.sum(&:row_count)
      end

      # The decisive number: rows the reader cannot see whose record has NO readable
      # row anywhere — not in the active space, and not waiting in the target space of
      # a running switch. Every one of them is content that silently returns nothing
      # and that no flip will rescue.
      def stranded_count
        stranded_groups.sum(&:row_count)
      end

      # Content written during a staged switch: unreadable TODAY, readable the moment
      # the flip happens. Reported, never part of the verdict — see the bucket list on
      # the class for why counting it as stranded would break the gate.
      def pending_flip_count
        pending_flip_groups.sum(&:row_count)
      end

      # Not readable, but the record also HAS a readable row: dead weight from an
      # earlier space, invisible to the reader, de-indexed by the PR-6a retirement.
      # The PR-6b retention GC deletes them ONLY where an embedding_spaces row still
      # holds their triple; otherwise they persist and the GC logs them as
      # UNREGISTERED (see the class comment above).
      def stale_count
        misaligned_count - stranded_count - pending_flip_count
      end

      # Rows whose record no longer exists. Reported, never part of the verdict.
      def orphan_count
        orphan_groups.sum(&:row_count)
      end

      def space_label
        return nil unless resolved?

        "#{space[:embedding_provider]}/#{space[:embedding_model]}/#{space[:embedding_dims]}"
      end
    end

    # "The row's owner still exists", per embeddable type, assembled from the SAME
    # type list Embeddings::OrphanGc sweeps — so the gate and the reclaimer can never
    # disagree about what an orphan is. Built lazily because the table names come from
    # constantize, which needs the app loaded.
    #
    # A type that is NOT on that list (an embeddable added without extending the GC)
    # falls through to TRUE: it counts as LIVE and stays in the census, where a real
    # misalignment still reddens the gate. Guessing it to be an orphan would silently
    # drop rows out of the check — the one failure mode worth avoiding here.
    def self.live_record_sql
      @live_record_sql ||= begin
        branches = OrphanGc::EMBEDDABLE_SOURCES.map do |type|
          klass = type.constantize
          "WHEN #{ContentEmbedding.connection.quote(klass.name)} THEN " \
            "EXISTS (SELECT 1 FROM #{klass.table_name} t WHERE t.id = content_embeddings.embeddable_id)"
        end
        "CASE content_embeddings.embeddable_type #{branches.join(' ')} ELSE TRUE END"
      end
    end

    # @return [Result]
    def self.call(organisation:)
      new(organisation: organisation).call
    end

    def initialize(organisation:)
      @organisation = organisation
    end

    # @return [Result]
    def call
      # Inside the tenant block like the read seam it mirrors: resolve_space touches
      # the org's credentials, and doing that under a different ambient tenant than
      # the counting is a difference with no reason to exist.
      ActsAsTenant.with_tenant(@organisation) do
        space, error = resolve_space
        configured = resolve_configured_space
        live = live_rows
        unreadable = space.nil? ? nil : live.where(NO_ACTIVE_SIBLING_SQL, binds_for(space))
        credential_error = resolve_credential_error(space)
        Result.new(organisation: @organisation, space: space, configured_space: configured,
                   error: error && error_label(error), error_class: error&.class,
                   credential_error: credential_error && error_label(credential_error),
                   credential_error_class: credential_error&.class,
                   ai_enabled: @organisation.ai_enabled?,
                   groups: build_groups(live.count),
                   orphan_groups: build_groups(orphan_rows.count),
                   stranded_groups: stranded_groups(unreadable, space, configured),
                   pending_flip_groups: pending_flip_groups(unreadable, space, configured),
                   pointer_state: resolve_pointer_state)
      end
    end

    private

    # embedding_space_for is gate-free (no ai_enabled, no quota — see Factory), but it
    # still resolves a CREDENTIAL and therefore raises.
    #
    # Reported, not raised — including the UNEXPECTED: a sweep over all orgs must not
    # die on org 3 of 200, and the realistic killer is not a Provider::Error but
    # ActiveRecord::Encryption::Errors::Decryption while reading
    # credential.access_token. Rescuing only the expected family would have made the
    # blanket "keeps sweeping" promise false in exactly the case it was written for.
    # Nothing is swallowed: an unexpected error is not soft, so it blocks the gate.
    #
    # @return [Array(Hash, nil), Array(nil, StandardError)]
    def resolve_space
      [::Lalabase::Llm::Factory.embedding_space_for(@organisation, space: :active), nil]
    rescue StandardError => e
      [nil, e]
    end

    # Did `space` come from the POINTER or from the fallback? Two distinct faults that
    # #resolve_space cannot tell apart, because the fallback makes both look resolved.
    #
    #   :missing  — no pointer at all. Repairable, and normal for an org activated
    #               before this was written (or one whose credentials did not resolve
    #               at activation time). `embeddings:backfill_spaces` fixes it.
    #   :dangling — a pointer naming a row that is gone. A DATA FAULT: the FK nullifies
    #               on delete, so reaching this needs a lost UPDATE or a cross-org id.
    #               Factory already logs it per query; this surfaces it in the gate.
    #
    # One extra existence query per org, in a tool that already runs four aggregate
    # scans. It deliberately does NOT go anywhere near the read path, which must stay
    # on the cheap building blocks (E1).
    def resolve_pointer_state
      space_id = @organisation.active_embedding_space_id
      return :missing if space_id.blank?
      return :resolved if ::EmbeddingSpace.exists?(id: space_id, organisation_id: @organisation.id)

      :dangling
    end

    # The credential half of the question, which the triple comparison structurally
    # cannot answer: #resolve_space returns the snapshot row's triple and never touches
    # a credential, so a space pinned (P0, embedding_spaces.ai_credential_id) to a
    # deleted, disabled or foreign-provider credential looks perfectly aligned while
    # every query embedding raises. Asked only once a space resolved at all — without
    # one there is nothing to serve, and #resolve_space already reports that.
    #
    # Errors are reported, never raised, for the same reason as #resolve_space: a sweep
    # over 200 orgs must not die on org 3.
    def resolve_credential_error(space)
      return nil if space.nil?

      ::Lalabase::Llm::Factory.active_space_credential_error(@organisation)
    end

    # Demodulized for the expected Provider::Error family (the names are unique and
    # the namespace is noise), fully qualified for anything else — there the
    # namespace IS the information (ActiveRecord::Encryption::Errors::Decryption).
    def error_label(error)
      name = error.is_a?(::Lalabase::Llm::Provider::Error) ? error.class.name.demodulize : error.class.name
      "#{name}: #{error.message}"
    end

    # The explicit organisation_id filter is defense-in-depth next to the tenant
    # scope, matching the read seam's house style. ONE relation behind every count
    # below, so census, stranded subset and orphan bucket can never disagree about
    # the corpus.
    def scope
      ContentEmbedding.where(organisation_id: @organisation.id)
                      .group(:embeddable_type, :embedding_provider, :embedding_model,
                             :embedding_dims, :indexed)
    end

    def live_rows
      scope.where(self.class.live_record_sql)
    end

    def orphan_rows
      scope.where("NOT (#{self.class.live_record_sql})")
    end

    # The CONFIGURED space — where NEW embeddings go. Needed to tell "unreachable" from
    # "waiting for the flip" (pending_flip). Resolution failures are swallowed to nil on
    # purpose: the configured space is a REFINEMENT of the verdict, never its basis, and
    # an org whose configuration cannot be resolved must still get its active-space
    # judgement (the active one has its own error reporting in #resolve_space).
    def resolve_configured_space
      ::Lalabase::Llm::Factory.embedding_space_for(@organisation, space: :configured)
    rescue StandardError
      nil
    end

    def binds_for(space)
      { provider: space[:embedding_provider], model: space[:embedding_model],
        dims: space[:embedding_dims] }
    end

    # Rows the reader cannot see AND that no flip will rescue. Empty while the space is
    # unresolved: with nothing to be stranded FROM, the question has no answer —
    # #groups still carries the full picture.
    #
    # The `NOT readable in configured` term needs no "is a switch running?" branch: when
    # configuration and serving name the SAME space, its binds equal the active ones, so
    # every row that failed the first test fails this one too and nothing moves out of
    # the bucket. The split is only visible during an actual switch.
    def stranded_groups(relation, space, configured)
      return [] if space.nil?
      return build_groups(relation.count) if configured.nil?

      build_groups(relation.where(NO_ACTIVE_SIBLING_SQL, binds_for(configured)).count)
    end

    # Rows that LIE IN the configured space while their record is unreadable in the
    # active one — content written during a staged switch, which the flip makes visible.
    # Empty when no switch is running (see the note above).
    #
    # BOTH conditions are needed, and the second one is the fix for a counting bug (review
    # F-B, 2026-08-01): the sibling test is a property of the RECORD ("does it have a
    # readable row over there"), so on its own it also drags in that record's rows from
    # THIRD spaces — an ada-002 leftover was reported as "written during the switch" and
    # was missing from stale_count at the same time. Filtering the row itself onto the
    # configured triple keeps each row in the bucket it belongs to.
    def pending_flip_groups(relation, space, configured)
      return [] if space.nil? || configured.nil?

      build_groups(relation.where(SIBLING_SQL, binds_for(configured))
                           .where(**configured).count)
    end

    # Sorted on an explicitly total key: the GROUP BY now carries a boolean, and
    # `true <=> false` is nil — a plain Array#sort over the keys would raise.
    def build_groups(counts)
      counts.sort_by { |(type, provider, model, dims, indexed), _| [type.to_s, provider.to_s, model.to_s, dims.to_i, indexed ? 0 : 1] }
            .map do |(type, provider, model, dims, indexed), row_count|
        Group.new(embeddable_type: type, embedding_provider: provider,
                  embedding_model: model, embedding_dims: dims,
                  indexed: indexed, row_count: row_count)
      end
    end
  end
end
