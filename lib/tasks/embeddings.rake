# frozen_string_literal: true

# Shared org resolution for the embeddings tasks: ONE org via find (aborts LOUDLY on
# a typo'd id, matching the reindex/status siblings — never a silent where(id:) no-op)
# or every org via find_each (batched). Also holds the ONE rendering of the
# space-alignment verdict shared by :status and :check_alignment.
module EmbeddingsRakeHelpers
  module_function

  def each_target_org(organisation_id, &block)
    if organisation_id
      block.call(Organisation.find(organisation_id))
    else
      Organisation.find_each(&block)
    end
  end

  # ONE rendering of an Embeddings::SpaceAlignment::Result for BOTH consumers —
  # :status prints it as an informational section, :check_alignment as the gate's
  # output. A second copy would let the informational and the blocking text drift.
  #
  # @return [Array<String>] unindented lines; the caller adds its own indentation
  def alignment_lines(result)
    lines =
      case result.status
      when :unresolved then unresolved_lines(result)
      when :aligned then aligned_lines(result)
      else misaligned_lines(result)
      end
    lines + credential_note(result) + pointer_note(result) + orphan_note(result)
  end

  # An org whose serving space comes from the FALLBACK rather than from its pointer
  # (KI-Pakete P4b precondition 3). Prints NEXT TO the verdict and never changes it —
  # same shape and same reason as credential_note: nothing about the triples is wrong,
  # and the org answers queries perfectly well today.
  #
  # A WARNING rather than a gate failure, deliberately. The damage is latent: it appears
  # only when the org changes package, and then as a HARD switch (reads jump to the new
  # empty space, no flip ever ends it) instead of the staged one. Failing a deploy over a
  # state that is currently harmless would spend the gate's credibility on the wrong
  # thing — and this gate is what an operator reads before EVERY deploy.
  #
  # The two states name different repairs, which is the whole reason they stay separate.
  #
  # BOTH print as WARNING, including the data fault. The prefix is not decoration here:
  # the exit code has ONE authority, Result#severity, and neither state feeds it — so an
  # ERROR-prefixed line that lets the gate pass green would contradict the meaning
  # credential_note gives the word three lines down. The severity difference lives in the
  # wording instead, where it cannot lie about what the gate did.
  #
  # Two silences, and both are the same argument this note is built on — a gate that
  # speaks about harmless states stops being read:
  #
  #   * AI OFF. organisations.ai_enabled defaults to FALSE, so every org that never
  #     switched AI on has no pointer, correctly: it owns no spaces, and
  #     ActivationBackfill never runs for it. Warning about it would fire on the whole
  #     non-AI fleet at every deploy. credential_note makes the same distinction one
  #     method down.
  #   * SPACE UNRESOLVED. The repair below goes through EnsureSpace →
  #     embedding_credentials_for and would die on exactly the credential that made the
  #     space unresolvable — the wall switch_repair_line already refuses to send an
  #     operator into. That org is reported as BROKEN on its own line anyway.
  def pointer_note(result)
    return [] if result.pointer_resolved? || !result.ai_enabled || !result.resolved?

    org = result.organisation.id
    case result.pointer_state
    when :missing
      ["WARNING: organisation #{org} has NO active_embedding_space_id — serving falls back to " \
       'the configured triple. That works today, but a package change would switch reads HARD ' \
       "instead of staged. Repair: rake \"embeddings:backfill_spaces[#{org}]\"."]
    when :dangling
      ["WARNING: organisation #{org} points at embedding space " \
       "#{result.organisation.active_embedding_space_id}, which is not one of ITS spaces — " \
       'serving silently falls back to the configured triple. This is a DATA FAULT, not a ' \
       'missing backfill (deleting a space nullifies the column instead): find out what wrote ' \
       'a foreign id before repointing.']
    else
      []
    end
  end

  # The gate's blind spot until the P0 credential pin got a check: an ALIGNED space
  # whose credential no longer resolves. Nothing about the triples is wrong, so this
  # prints NEXT TO a green space label rather than instead of it — and it names the two
  # repairs, because the operator cannot tell from the symptom which one applies.
  def credential_note(result)
    return [] if result.credential_error.nil?

    ["#{result.ai_enabled ? 'ERROR' : 'WARNING'}: the serving space resolves, but its credential " \
     "does NOT — #{result.credential_error}. Every query embedding raises until either the " \
     'credential is re-enabled or the space is repointed (embedding_spaces.ai_credential_id ' \
     "for org #{result.organisation.id}); a reindex repairs nothing here."]
  end

  def aligned_lines(result)
    ["Read-path space: #{result.space_label}", aligned_verdict(result),
     *pending_flip_note(result), *stale_note(result)]
  end

  # Content that sits in the CONFIGURED space while serving still answers from another
  # one. Outside the VERDICT (counting it as stranded would turn the gate red for a whole
  # build window while the printed reindex does nothing), but no longer silent: the
  # severity is :warning, and both repairs are named.
  #
  # Naming both is the point (review F-A, 2026-08-01). The same data appears in two
  # opposite situations — a switch on its way to the configured space, and a ROLL-BACK
  # that deliberately left it behind. Printing only "run the flip" was actively wrong in
  # the second: it is the command that undoes the roll-back, offered to an operator who
  # just came out of an incident and reads "ALIGNED".
  def pending_flip_note(result)
    return [] if result.pending_flip_count.zero?

    org = result.organisation.id
    ["WARNING: #{result.pending_flip_count} row(s) live in the CONFIGURED space " \
     "(#{configured_label(result)}), which is NOT the one serving search — they are " \
     'currently unreachable. Configuration and serving diverge; which repair is right ' \
     'depends on WHY:',
     switch_repair_line(result, org),
     '  after a roll-back  → put the CONFIGURATION back on the active space, otherwise ' \
     'new content keeps landing in the space you left',
     "  Both states look identical in the data — `rake \"embeddings:status[#{org}]\"` shows " \
     'the spaces, the decision is yours.']
  end

  # Only the SWITCH repair depends on ai_enabled, and that asymmetry is the reason this
  # is its own method: embeddings:build_target goes through
  # Embeddings::OrganisationReindexer, whose provider comes from
  # Factory.for_embeddings — that raises AiDisabledError while AI is off, the same wall
  # #misaligned_fix already refuses to send an operator into. The ROLL-BACK repair is a
  # pure configuration change on the organisation and stays runnable either way, so it
  # needs no qualifier.
  def switch_repair_line(result, org)
    finish = "rake \"embeddings:build_target[#{org}]\" then rake \"embeddings:flip[#{org}]\""
    return "  switch in progress → finish it: #{finish}" if result.ai_enabled

    "  switch in progress → enable AI for this organisation FIRST, then #{finish} — " \
      'build_target raises AiDisabledError while AI is off'
  end

  def configured_label(result)
    space = result.configured_space
    return 'not resolvable' if space.nil?

    "#{space[:embedding_provider]}/#{space[:embedding_model]}/#{space[:embedding_dims]}"
  end

  def aligned_verdict(result)
    return 'Verdict: ALIGNED — no sidecar rows to compare' if result.total_count.zero?

    verdict = 'Verdict: ALIGNED — every embedded record has a readable row in that space ' \
              "(#{result.aligned_count} of #{result.total_count} sidecar row(s) with a live record)"
    # A bare "ALIGNED" would be read as "nothing to do" while content sits unreachable in
    # the configured space (review F-A). The qualifier travels WITH the verdict line,
    # because that is the one line a 200-org sweep gets read on.
    return verdict if result.pending_flip_count.zero?

    "#{verdict} — but see the WARNING below: configuration and serving diverge."
  end

  # Leftovers from an earlier space whose record DOES have a readable row: invisible
  # to the reader, so they never fail the gate — but they are the normal aftermath
  # of a model switch, and naming them keeps the count difference from looking like
  # a bug. PR 6a de-indexes them (retirement).
  #
  # DELETING them is the PR-6b retention GC's job ONLY where an embedding_spaces row
  # holds their triple. Rows from a switch that predates spaces have no such row and
  # are reclaimed by NOTHING — the GC logs them as UNREGISTERED. Saying "deleted by the
  # GC" without that qualifier (as this line did until 6b) sets up an operator to wait
  # for a cleanup that never comes.
  def stale_note(result)
    return [] if result.stale_count.zero?

    ["Note: #{result.stale_count} stale row(s) from an earlier space remain (harmless; de-indexed by the retirement). The retention GC deletes them only if an embedding_spaces row still holds their triple — otherwise they persist and the GC logs them as UNREGISTERED."]
  end

  # Rows whose record is GONE (callback-free delete_all before the daily orphan GC
  # ran). Named separately and deliberately outside the verdict: a reindex cannot
  # reach them — it walks LIVE records — so counting them as stranded would leave
  # the gate red with the printed fix a no-op.
  def orphan_note(result)
    return [] if result.orphan_count.zero?

    ["Note: #{result.orphan_count} orphan row(s) whose record no longer exists (outside the verdict — " \
     'no reindex can reach them). The daily GC reclaims them; on demand: ' \
     "rake \"embeddings:gc[#{result.organisation.id}]\" (DRY_RUN=1 only counts)."]
  end

  def misaligned_lines(result)
    ["Read-path space: #{result.space_label}",
     misaligned_verdict(result),
     misaligned_fix(result),
     'Stranded rows live in:',
     *group_lines(result.stranded_groups),
     *pending_flip_note(result),
     *stale_note(result)]
  end

  # The severity marker sits IN the verdict line on purpose: whoever scans a 200-org
  # sweep reads that line and nothing else.
  def misaligned_verdict(result)
    marker = result.ai_enabled ? '' : ' (WARNING — not repairable while AI is off)'
    "Verdict: MISALIGNED#{marker} — #{result.stranded_count} of #{result.total_count} sidecar row(s) " \
      'are STRANDED: their record has NO readable row in the active space (right triple AND indexed), ' \
      'so retrieval silently finds nothing for it.'
  end

  # The fix depends on ai_enabled — and so does whether this fails the check at all:
  # Embeddings::OrganisationReindexer resolves its provider through
  # Factory.for_embeddings, which raises AiDisabledError while AI is off. Printing a
  # bare "reindex" there would send the operator into a wall.
  def misaligned_fix(result)
    # A configuration that does not resolve makes the reindex DIE, not merely misfire:
    # Embeddings::OrganisationReindexer builds its provider through
    # Factory.for_embeddings(space: :configured). Naming the reindex first would hand the
    # operator a command that crashes (review R-D).
    return unresolved_configuration_fix if result.ai_enabled && result.configured_space.nil?
    return switch_fix(result) if result.ai_enabled && result.switch_in_progress?
    return "Fix: rake \"embeddings:reindex[#{result.organisation.id}]\"" if result.ai_enabled

    'Fix: enable AI for this organisation FIRST, then ' \
      "rake \"embeddings:reindex[#{result.organisation.id}]\" — a reindex raises AiDisabledError while AI " \
      'is off, so this is a WARNING and does not fail the check.'
  end

  def unresolved_configuration_fix
    'Fix: the CONFIGURED embedding space cannot be resolved — a reindex would die on the ' \
      'same resolution. Repair the organisation embedding configuration (provider, model, ' \
      'endpoint, credential) FIRST, then reindex.'
  end

  # During a running switch a plain reindex is the WRONG advice: it builds the
  # CONFIGURED space, which is not the one being served, so the stranded rows stay
  # stranded and the run reports "reindexed 0" against a red gate — the exact silent
  # failure this gate exists to catch. Finish the switch instead.
  def switch_fix(result)
    "Fix: a switch to #{configured_label(result)} is in progress — finish it: " \
      "rake \"embeddings:build_target[#{result.organisation.id}]\" then " \
      "rake \"embeddings:flip[#{result.organisation.id}]\". " \
      'A plain reindex would build the configured space these rows are already missing from.'
  end

  # No resolvable vector space. NOT "the normal state of an AI-off org", the reading
  # that hid this for a while: Factory.embedding_space_for never looks at ai_enabled,
  # it resolves a CREDENTIAL — with an active system credential the space resolves for
  # every org, AI on or off. Getting here means no credential at all, or a
  # misconfiguration (which is never benign).
  def unresolved_lines(result)
    lines = ["Read-path space: NOT RESOLVABLE (#{result.error})", unresolved_verdict(result)]
    return lines if result.total_count.zero?

    lines + group_lines(result.groups)
  end

  def unresolved_verdict(result)
    return misconfigured_verdict unless result.soft_error?
    return broken_verdict if result.ai_enabled
    return 'Verdict: OK — AI is off, no embedding credential, no sidecar rows: nothing at risk.' if
      result.total_count.zero?

    'Verdict: UNVERIFIABLE — AI is off and no embedding credential resolves, so nothing reads these rows ' \
      "today. WARNING: #{result.total_count} sidecar row(s) rest in a space nobody currently reads — " \
      'enabling AI without a following reindex makes retrieval come back empty.'
  end

  def misconfigured_verdict
    'Verdict: MISCONFIGURED — the embedding provider cannot be resolved at all. A configuration fault, ' \
      'not a switched-off AI (a provider that cannot embed, an unknown provider name, an undecryptable ' \
      'credential): fix the organisation\'s embedding configuration.'
  end

  def broken_verdict
    'Verdict: BROKEN — AI is ENABLED but no embedding credential resolves: Embeddings::NearestNeighbors ' \
      'raises on EVERY query and PromptBuildingService answers WITHOUT context (log warning only). ' \
      'Configure an embedding credential.'
  end

  # The one-line reason behind the summary at the end of :check_alignment — the
  # detail is printed per org above; this keeps the abort message greppable.
  def blocking_reason(result)
    return 'no-read-space' unless result.resolved?

    reasons = ["stranded=#{result.stranded_count}"]
    reasons << 'credential-unresolvable' unless result.credential_error.nil?
    reasons.join(' ')
  end

  def group_lines(groups)
    groups.map { |group| "  #{group.embeddable_type} #{group.space_label}: #{group.row_count}" }
  end

  # Reindex mode as a display suffix. force wins over delta because they are mutually
  # exclusive at the reindexer (force is the superset).
  def mode_label(force:, delta:)
    return ' [force]' if force
    return ' [delta]' if delta

    ''
  end

  # Sweep 3's contribution to the GC line (PR 6b). ONE rendering for :gc and :status,
  # so the on-demand run and the status probe cannot report retention differently.
  # skipped_orgs appears only when positive: orgs whose configured space did not
  # resolve are skipped fail-safe, and silence about them would make a fleet-wide
  # resolution failure look like "nothing to collect" (review F5).
  def retention_summary(result)
    summary = "spaces=#{result.retention_spaces} space_rows=#{result.retention_embeddings}"
    summary += " skipped_orgs=#{result.retention_skipped}" if result.retention_skipped.positive?
    summary
  end

  # Anti-join gap between the org's corpus and ONE space, as a printable summary.
  # Empty string = complete. Same source as the flip validation, so "ready to flip"
  # here and the actor's refusal can never disagree.
  def missing_summary(organisation, space)
    ActsAsTenant.with_tenant(organisation) do
      Embeddings::OrganisationReindexer
        .missing_in_space(organisation: organisation, space: space.triple)
        .reject { |_model, count| count.zero? }
        .map { |model, count| "#{model}=#{count}" }
        .join(' ')
    end
  end

  # The serving pointer + how far the configured space is from being flippable.
  # Answers the two questions a staged switch actually raises: what serves right now,
  # and how far along is the build.
  def space_lines(organisation)
    active = ActsAsTenant.with_tenant(organisation) do
      organisation.active_embedding_space_id && EmbeddingSpace.find_by(id: organisation.active_embedding_space_id)
    end
    lines = ["Active space: #{active ? "#{active.label} (id #{active.id})" : 'NONE — serving falls back to the configured space'}"]
    lines + configured_space_lines(organisation, active)
  end

  def configured_space_lines(organisation, active)
    configured = ::Lalabase::Llm::Factory.embedding_space_for(organisation, space: :configured)
    label = "#{configured[:embedding_provider]}/#{configured[:embedding_model]}/#{configured[:embedding_dims]}"
    return ["Configured space: #{label} (= active)"] if active && active.triple == configured

    row = ActsAsTenant.with_tenant(organisation) { EmbeddingSpace.find_by(organisation_id: organisation.id, **configured) }
    gap = row ? missing_summary(organisation, row) : nil
    ["Configured space: #{label} — DIFFERENT from the active one (staged switch in progress)",
     build_progress_line(row, gap)]
  rescue StandardError => e
    ["Configured space: NOT RESOLVABLE (#{e.class}: #{e.message})"]
  end

  def build_progress_line(row, gap)
    return '  No embedding_spaces row yet — run embeddings:build_target to start the build.' if row.nil?
    return '  Target space COMPLETE — ready for embeddings:flip.' if gap.blank?

    "  Target space still missing: #{gap}"
  end
end

namespace :embeddings do
  desc 'Re-embed all stored vectors for an organisation into its CONFIGURED space. ' \
       'Add ,force to re-embed EVERY row (heals pre-backfill source_hash drift) or ' \
       ',delta to additionally catch records whose source text has drifted.'
  task :reindex, %i[organisation_id mode] => :environment do |_task, args|
    organisation_id = args.fetch(:organisation_id) do
      abort 'Usage: rake "embeddings:reindex[ORGANISATION_ID]" (append ,force or ,delta)'
    end
    mode = args[:mode].to_s
    # Kept tolerant of the historical ",force" spelling AND boolean-ish values, so the
    # documented PR-5 procedure keeps working verbatim.
    force = mode == 'force' || ActiveModel::Type::Boolean.new.cast(mode).present?
    delta = mode == 'delta'

    organisation = Organisation.find(organisation_id)
    label = EmbeddingsRakeHelpers.mode_label(force: force, delta: delta)
    puts "Re-indexing embeddings for organisation #{organisation.id} (#{organisation.name})#{label}…"

    # metered: false on every rake path — an operator running a task is not the
    # customer choosing a package, and only the latter is the paid act (E6).
    results = Embeddings::OrganisationReindexer.call(organisation: organisation, metered: false,
                                                     force: force, delta: delta)
    results.each do |model, result|
      drift = result.stale_reembedded.nil? ? '' : ", drift-reembedded #{result.stale_reembedded}"
      puts "  #{model}: reindexed #{result.reindexed}, skipped #{result.skipped}, total #{result.total}#{drift}"
    end
    puts 'Done.'
  end

  desc 'Build the org\'s CONFIGURED vector space in the background WITHOUT flipping ' \
       'serving to it (embedding v2 PR 6a). Idempotent and restartable.'
  task :build_target, [:organisation_id] => :environment do |_task, args|
    organisation_id = args.fetch(:organisation_id) do
      abort 'Usage: rake "embeddings:build_target[ORGANISATION_ID]"'
    end
    organisation = Organisation.find(organisation_id)

    space = Embeddings::EnsureSpace.call(organisation: organisation)
    puts "Building target space #{space.label} for organisation #{organisation.id} (#{organisation.name})…"
    puts '  Serving stays on the ACTIVE space until you run embeddings:flip.'

    Embeddings::OrganisationReindexer.call(organisation: organisation, metered: false).each do |model, result|
      puts "  #{model}: embedded #{result.reindexed}, skipped #{result.skipped}, total #{result.total}"
    end

    missing = EmbeddingsRakeHelpers.missing_summary(organisation, space)
    puts missing.empty? ? '  Target space COMPLETE — ready to flip.' : "  Still missing: #{missing}"
    puts 'Done.'
  end

  desc 'One-off: give existing organisations an embedding_spaces row for the space they ' \
       'are effectively on, and point them at it. Idempotent; never overwrites a pointer.'
  task :backfill_spaces, [:organisation_id] => :environment do |_task, args|
    EmbeddingsRakeHelpers.each_target_org(args[:organisation_id]) do |organisation|
      if organisation.active_embedding_space_id.present?
        puts "org #{organisation.id}: pointer already set — skipped."
        next
      end

      begin
        space = Embeddings::EnsureSpace.call(organisation: organisation)
      rescue StandardError => e
        # A whole-fleet sweep must not die on org 3 of 200 — an org without any
        # resolvable embedding credential simply has no space to record.
        puts "org #{organisation.id}: SKIPPED — space not resolvable (#{e.class}: #{e.message})"
        next
      end

      organisation.update_column(:active_embedding_space_id, space.id)
      puts "org #{organisation.id} (#{organisation.name}): active space = #{space.label}"
      # HONEST about what this does NOT do: it freezes the CURRENT state. For an org
      # whose stored rows sit in a different space than the read path resolves, the
      # pointer now names the space its rows are NOT in — the backfill neither notices
      # nor repairs that. The remedy is unchanged: enable AI, then reindex.
      gap = EmbeddingsRakeHelpers.missing_summary(organisation, space)
      puts "  WARNING: records without a readable row in that space: #{gap} — reindex needed." if gap.present?
    end
    puts 'Done.'
  end

  desc 'Flip serving to the org\'s CONFIGURED vector space. Refuses while the target ' \
       'space is incomplete (anti-join, not a count).'
  task :flip, [:organisation_id] => :environment do |_task, args|
    organisation_id = args.fetch(:organisation_id) do
      abort 'Usage: rake "embeddings:flip[ORGANISATION_ID]"'
    end
    organisation = Organisation.find(organisation_id)
    target = Embeddings::EnsureSpace.call(organisation: organisation)

    result = Actors::FlipEmbeddingModel.call(organisation: organisation, target_space: target,
                                             current_user: nil)
    abort "FLIP REFUSED: #{result.errors.join(' ')}" unless result.success?

    puts "Flipped organisation #{organisation.id} (#{organisation.name}) to #{target.label}."
    puts '  Retirement of the previous space is running in the background (indexed → false).'
    puts "  Verify: rake \"embeddings:check_alignment[#{organisation.id}]\""
  end

  desc 'Roll back to a previously held vector space: reactivate its rows, delta-reindex ' \
       'the drift, then flip back. SPACE_ID from `embeddings:status`.'
  task :rollback, %i[organisation_id space_id] => :environment do |_task, args|
    organisation_id = args.fetch(:organisation_id) do
      abort 'Usage: rake "embeddings:rollback[ORGANISATION_ID,SPACE_ID]"'
    end
    space_id = args.fetch(:space_id) { abort 'Usage: rake "embeddings:rollback[ORGANISATION_ID,SPACE_ID]"' }
    organisation = Organisation.find(organisation_id)

    ActsAsTenant.with_tenant(organisation) do
      space = EmbeddingSpace.find_by(id: space_id, organisation_id: organisation.id)
      abort "No such vector space for this organisation: #{space_id}" if space.nil?

      # ORDER IS THE POINT (sheet §4.5): reactivate BEFORE the flip. Flipping onto a
      # retired space first would serve zero rows org-wide until reactivation finished —
      # in exactly the situation a roll-back exists for.
      puts "Rolling organisation #{organisation.id} (#{organisation.name}) back to #{space.label}."
      puts "  1/3 Reactivating: #{Embeddings::SpaceIndexFlag.call(space: space, indexed: true)} " \
           'row(s) back in the ANN index.'

      # target_space: pins BOTH the provider (built from this space's own credential
      # snapshot — B2, no re-entry of old BYOK credentials) and the triple the rows are
      # stamped with. delta: catches records created or edited since this space was
      # last active; unchanged records cost nothing.
      puts '  2/3 Delta-reindexing drift since this space was last active…'
      Embeddings::OrganisationReindexer
        .call(organisation: organisation, metered: false, delta: true, target_space: space)
        .each do |model, result|
          puts "      #{model}: re-embedded #{result.reindexed} " \
               "(of which drift #{result.stale_reembedded}), total #{result.total}"
        end

      result = Actors::FlipEmbeddingModel.call(organisation: organisation, target_space: space,
                                               current_user: nil)
      # The three steps are NOT one transaction, and step 2 takes as long as the corpus
      # needs: on an active organisation, content created DURING it lands only in the
      # configured space and makes the target incomplete again. Refusing here leaves the
      # old space reactivated but not serving — index weight, no correctness problem.
      # Both earlier steps are idempotent, so the repair is simply running this again;
      # say so instead of leaving the operator with a half-finished procedure.
      unless result.success?
        abort "ROLLBACK REFUSED: #{result.errors.join(' ')}\n" \
              "  The old space stays REACTIVATED (in the index, not serving) — no data is at risk.\n" \
              "  Re-run this same command: reactivation and delta reindex are idempotent and will\n" \
              '  catch up on whatever was created in the meantime.'
      end

      puts "  3/3 Flipped back to #{space.label}."
      puts "  Verify: rake \"embeddings:check_alignment[#{organisation.id}]\""
      puts '  NOTE: the org CONFIGURATION still points at the space you rolled away from — ' \
           'new content keeps landing there until you change it back.'
    end
  end

  desc 'Roll the system embedding default (ada-002 → text-embedding-3-small) across all ' \
       'system-default orgs and re-embed their corpora (BYOK/divergent orgs untouched)'
  task migrate_default_model: :environment do
    puts 'Migrating system-default organisations to text-embedding-3-small…'

    summary = Embeddings::DefaultModelMigrator.new.call

    summary.results.each do |org_result|
      model_change = org_result.normalised ? 'ada-002 → nil (follow default)' : 'model unchanged'
      reindex_note =
        if org_result.reindex
          org_result.reindex.map { |model, res| "#{model}=#{res.reindexed}/#{res.total}" }.join(' ')
        else
          'reindex skipped'
        end
      puts "  org #{org_result.organisation_id}: #{model_change}; reindexed #{reindex_note}"
    end

    puts "Done. Migrated #{summary.migrated} org(s); skipped #{summary.skipped} (BYOK/divergent)."
  end

  desc 'Reclaim orphaned embedding rows (owner gone) AND vector spaces beyond the org ' \
       'retention limit. No id = ONE global sweep; [org_id] = org-scoped. DRY_RUN=1 only counts.'
  task :gc, [:organisation_id] => :environment do |_task, args|
    dry_run = ENV['DRY_RUN'] == '1'
    label = dry_run ? 'would reclaim' : 'reclaimed'

    # DRY_RUN governs BOTH sweeps here (OrphanGc defaults retention_dry_run to dry_run).
    # The two ENV switches exist for the unattended nightly job, where arming orphan
    # reclamation must not silently arm the deletion of whole spaces; a human typing
    # this command has already said which one they mean.
    if args[:organisation_id]
      organisation = Organisation.find(args[:organisation_id]) # loud abort on a typo'd id
      result = Embeddings::OrphanGc.call(organisation: organisation, dry_run: dry_run)
      puts "org #{organisation.id}: #{label} embeddings=#{result.orphan_embeddings} " \
           "fragments=#{result.orphan_fragments} #{EmbeddingsRakeHelpers.retention_summary(result)}"
    else
      # ONE global sweep (organisation: nil → without_tenant), no per-org iteration.
      result = Embeddings::OrphanGc.call(dry_run: dry_run)
      puts "global: #{label} embeddings=#{result.orphan_embeddings} fragments=#{result.orphan_fragments} " \
           "#{EmbeddingsRakeHelpers.retention_summary(result)} (errors=#{result.errors})"
    end
    puts '  Per-org detail + any UNREGISTERED space warnings are in the log.'
    puts 'Done.'
  end

  desc 'Embedding status for an organisation: sidecar triples, indexed counts, serving ' \
       'pointer vs. configuration, read-path alignment, orphan/retention estimate'
  task :status, [:organisation_id] => :environment do |_task, args|
    organisation_id = args.fetch(:organisation_id) do
      abort 'Usage: rake "embeddings:status[ORGANISATION_ID]"'
    end
    organisation = Organisation.find(organisation_id)
    puts "Embedding status for organisation #{organisation.id} (#{organisation.name}):"

    ActsAsTenant.with_tenant(organisation) do
      puts '  Sidecar rows per (type, provider, model, dims):'
      counts = ContentEmbedding.group(:embeddable_type, :embedding_provider, :embedding_model, :embedding_dims).count
      indexed = ContentEmbedding.where(indexed: true)
                                .group(:embeddable_type, :embedding_provider, :embedding_model, :embedding_dims).count
      counts.sort.each do |(type, provider, model, dims), total|
        puts "    #{type} #{provider}/#{model}/#{dims}: #{total} (indexed #{indexed.fetch([type, provider, model, dims], 0)})"
      end
    end

    # Serving pointer + build progress (PR 6a): the two questions a staged switch
    # raises. Printed BEFORE the alignment verdict, because "config ≠ active" is the
    # normal state during a build and explains what the verdict below shows.
    puts '  Vector spaces (serving pointer vs. configuration):'
    EmbeddingsRakeHelpers.space_lines(organisation).each { |line| puts "    #{line}" }

    # The verdict on the listing above: which of those triples does the READ path
    # (Embeddings::NearestNeighbors) actually query? Without this the human had to
    # do the comparison in their head — and on 2026-07-30 nobody did.
    puts '  Read-path alignment (stamped triples vs. the space the reader resolves):'
    EmbeddingsRakeHelpers.alignment_lines(Embeddings::SpaceAlignment.call(organisation: organisation))
                         .each { |line| puts "    #{line}" }

    # No "backfill gap" block since PR 7: it asked whether an INLINE vector had a
    # matching sidecar row, and there are no inline vectors left to ask about. The
    # remaining completeness question — does a record have a READABLE row in the
    # space it is supposed to be in — is what the alignment verdict above answers.

    puts '  Orphan + retention estimate (dry-run GC):'
    result = Embeddings::OrphanGc.call(organisation: organisation, dry_run: true)
    puts "    orphan embeddings=#{result.orphan_embeddings} orphan fragments=#{result.orphan_fragments}"
    puts "    retention (beyond limit #{organisation.embedding_retention_limit}): " \
         "#{EmbeddingsRakeHelpers.retention_summary(result)}"
    puts 'Done.'
  end

  desc 'Gate: do the stored sidecar triples still match the vector space the READ path ' \
       'resolves? (one org, or all orgs when no id is given). Exits NON-ZERO on misalignment.'
  task :check_alignment, [:organisation_id] => :environment do |_task, args|
    blocking = []
    warnings = []
    pointer_gaps = []

    EmbeddingsRakeHelpers.each_target_org(args[:organisation_id]) do |organisation|
      result = Embeddings::SpaceAlignment.call(organisation: organisation)
      puts "organisation #{organisation.id} (#{organisation.name}):"
      EmbeddingsRakeHelpers.alignment_lines(result).each { |line| puts "  #{line}" }

      # ONE authority for the exit code: Result#severity. The matrix behind it
      # (stranded rows + ai_enabled + the kind of resolution failure) lives on the
      # object, so this task cannot drift from what :status prints.
      case result.severity
      when :error then blocking << "#{organisation.id}=#{EmbeddingsRakeHelpers.blocking_reason(result)}"
      when :warning then warnings << organisation.id
      end

      # Collected SEPARATELY, on purpose. The pointer gap deliberately feeds neither
      # severity (it must not move the exit code), and folding it into `warnings` would
      # mislabel it: that roster's own closing line names its two causes by hand, and a
      # third kind hiding behind them would send operators to the wrong repair.
      #
      # Asked via the note rather than by re-testing the condition: the roster and the
      # per-org line must never disagree about who is affected, and the surest way to
      # keep two checks in step is to have only one. Building the strings twice costs
      # nothing here.
      pointer_gaps << organisation.id if EmbeddingsRakeHelpers.pointer_note(result).any?
    end

    # Two kinds of non-fatal finding, and lumping them together would send operators to
    # the wrong fix: an org that CANNOT be repaired as it stands (AI off — failing on it
    # would leave the gate permanently red while the printed fix is unrunnable), and an
    # org whose configuration and serving diverge (review F-A — legitimate mid-switch,
    # but also the aftermath of a roll-back, and the repairs are opposite).
    if warnings.any?
      puts "WARNING: #{warnings.size} organisation(s) with a non-blocking finding — per-org detail above: " \
           "#{warnings.join(' ')}"
      puts '  (AI switched off → enable AI, then reindex · configuration ≠ serving → see the ' \
           'per-org WARNING line for the two possible repairs)'
    end

    # Its own roster line, for the same reason it has its own collector: without one, a
    # sweep whose ONLY finding is a missing pointer ends on "No blocking misalignment
    # detected" and the per-org WARNING has scrolled away 200 orgs ago. Every other
    # non-blocking finding in this task gets a summary; this one was the exception.
    if pointer_gaps.any?
      puts "WARNING: #{pointer_gaps.size} AI-enabled organisation(s) serving from the FALLBACK " \
           "instead of a vector-space pointer: #{pointer_gaps.join(' ')}"
      puts '  (works today; a package change would switch their reads HARD instead of staged — ' \
           'see the per-org WARNING for which repair applies)'
    end

    if blocking.any?
      abort "BLOCKED — #{blocking.size} organisation(s) with unreachable embeddings (org=reason): " \
            "#{blocking.join(' ')} (per-org verdict + fix above, then re-run this check)"
    end

    puts 'Done. No blocking misalignment detected.'
  end
end
