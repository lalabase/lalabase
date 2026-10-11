# frozen_string_literal: true

class EmbeddingProcessingService
  # Raised when the opt-out / destroy-mid-run fragment+sidecar purge ITSELF fails
  # (deadlock, statement_timeout): the outer rescue re-raises this instead of
  # swallowing it, so the job retries rather than falsely completing with the PII
  # this run wrote left un-purged (review #354 #4 — write-path fail-closed).
  class PurgeFailedError < StandardError; end

  attr_reader :record, :fragment_association

  def initialize(record, fragment_association = :fragments)
    @record = record
    # By default, an attempt is made to guess the matching association if not passed explicitly
    @fragment_association = fragment_association || default_fragment_association
  end

  def process
    # ⚠️ This used to `return` and leave the record UNTOUCHED, which put it on the pending
    # list for the rest of its life: Embeddings::PendingEmbeddings selects on the flag,
    # the flag was never written, and every catch-up run picked the record up, did
    # nothing, and left it pending. Embeddings::IndexHealth then reported it as
    # outstanding work on a page whose one button could not help it.
    #
    # Measured in production 2026-08-31: six DocumentVersions in two live organisations,
    # dated between 08/2025 and 06/2026, all with no attached file and no extractable
    # text. Nothing was broken about them. The COUNTER was wrong.
    #
    # "Nothing to index" is a finished state, not a pending one, and it is finished
    # regardless of the AI opt-in — the gate governs a transfer, and there is nothing to
    # transfer. If text arrives later the record is saved, its actor enqueues a fresh
    # job, and this run's verdict is simply replaced.
    unless record.respond_to?(:plain_text_version) && record.plain_text_version.present?
      settle_as_nothing_to_index('no extractable text')
      return
    end

    # Runtime opt-in re-check (review PR #247): the enqueue-time gate alone is not
    # enough — a job enqueued while a record was opted IN may run only AFTER a later
    # opt-OUT (queue latency, retries). Without this guard such a job would re-create
    # fragments the opt-out just purged (PII resurrection for meetings). Skip without
    # any writes; models without the opt-in column (Ticket & co.) are unaffected.
    if record.respond_to?(:create_embeddings) && !record.create_embeddings
      Rails.logger.debug do
        "EmbeddingProcessingService: skipping #{record.class.name}##{record.id} — embeddings opt-in is off"
      end
      return
    end

    begin
      # STEP 1 — extraction. Local text processing, no network call, no provider
      # resolution, and therefore NOT behind the AI opt-in (S3 of
      # doc/fragment_einbettung_entkopplung_plan.md). The fragment is what the FULL-TEXT
      # reader needs, and that reader has nothing to do with AI: search_full_text_german
      # is a pg_search_scope against plain_text_content with no join to
      # content_embeddings. Writing it after the embedding call is what turned an AI
      # outage into a full-text outage — measured 2026-08-30, 69 production posts held
      # text and no fragment at all, 43 of them lost to a transient HTTP 429.
      version_token = write_fragments
      if version_token.nil?
        # Text present, but the splitter produced no chunk from it. Same verdict as the
        # blank-text branch above and settled through the same method — the two used to
        # disagree, one marking done only for an AI-on organisation and the other not
        # writing anything at all, which is two answers to one question.
        #
        # The opt-out re-check runs FIRST and is not an ornament on an empty run: before
        # the split this path fell through to it, and an opt-out landing mid-run has
        # earlier fragments of this record to purge whether or not THIS run wrote any.
        # Returning past it would have quietly narrowed the #247 promise.
        return if purge_if_opted_out_or_gone?

        settle_as_nothing_to_index('nothing to split')
        return
      end

      # STEP 2 — the transfer, and ONLY the transfer is gated. This is the GDPR opt-in
      # (audit 2026-07-03 item 1.2) doing exactly its job: no tenant content reaches an
      # LLM provider without org-level activation. It no longer decides whether the
      # content is searchable at all.
      embed_fragments(version_token) if record.organisation&.ai_enabled?

      # Post-run opt-in re-check (review PR #247), now covering BOTH steps — see the
      # method for why, and why it is a method at all since the split.
      return if purge_if_opted_out_or_gone?

      # "Done" keeps meaning EMBEDDED, never merely extracted (plan risk 3). An AI-off
      # organisation extracts and stays pending, so the day it opts in, the catch-up
      # still finds every record — Embeddings::PendingEmbeddings selects on this flag.
      mark_embeddings_as_successful if fully_embedded?(version_token)
    rescue Lalabase::Llm::QuotaExceededError
      # Quota paused (S3, test 29): skip quietly like the AI-off case above — a
      # paused quota is a PENDING state, not a defect, so it must NOT set
      # embedding_creation_error. The record stays un-embedded and is picked up by
      # a quota-aware catch-up once budget returns. Its FRAGMENTS survive, so the
      # content stays full-text searchable throughout the pause.
      Rails.logger.debug do
        "EmbeddingProcessingService: pausing #{record.class.name}##{record.id} — AI quota exhausted"
      end
    rescue PurgeFailedError
      # Fail CLOSED (review #354 #4): a failed opt-out/destroy purge must NOT land in
      # handle_embedding_error below (which swallows and marks the run "done"). Listed
      # BEFORE the StandardError catch-all so it propagates and the job retries.
      raise
    rescue StandardError => e
      handle_embedding_error(e)
    end
  end

  private

  # ONE verdict for "there is nothing here to index", reached from two places: no text at
  # all, and text that yields no chunk. Both are finished states, and both were silent
  # before — the record simply stayed pending.
  #
  # Deliberately NOT gated on ai_enabled?: the opt-in governs a transfer to a provider,
  # and this branch has nothing to transfer. Gating it would recreate the permanent
  # pending count for exactly the organisations that can never resolve it.
  #
  # Records without the flag column (a bare Struct in a spec, say) are left alone rather
  # than raising — #mark_embeddings_as_successful raises for them by design, and that is
  # a real defect elsewhere, not something this branch should trip over.
  def settle_as_nothing_to_index(reason)
    # The guard comes BEFORE the log line, and the order is not cosmetic: a record with no
    # flag column is one this method cannot settle, and announcing a verdict it will not
    # reach is both wrong and expensive — the message interpolates #id, which such a
    # record need not answer either.
    return unless record.respond_to?(:embeddings_creation_flag)

    Rails.logger.debug do
      "EmbeddingProcessingService: #{record.class.name}##{record.id} has #{reason} — settling as done."
    end
    mark_embeddings_as_successful
  end

  # The #247 post-run re-check, and since the split there are TWO callers: the normal
  # path and the empty-extract path. One owner rather than two copies, because the two
  # would be a rule enforced by hand in two places (CLAUDE.md), and this particular rule
  # is a PII promise.
  #
  # An opt-out purge may have run while this job was mid-flight, and STEP 1 writes
  # fragments even for an AI-off organisation, so the race is no longer confined to the
  # embedding path. Re-reading the flag AFTER our writes closes it: whichever side acts
  # last sees the other's state, so no fragment of an opted-out record survives.
  #
  # The rescue is scoped to the #reload, the only legitimate RecordNotFound source here —
  # a broader catch would misread a foreign error as "record gone".
  #
  # @return [Boolean] true when it purged and the caller must stop.
  def purge_if_opted_out_or_gone?
    if record.respond_to?(:create_embeddings) && !record.reload.create_embeddings
      # Opt-out purge: fragments AND their sidecar rows together (embedding v2 PR 2),
      # else exactly the content_embeddings rows THIS run just wrote survive the fragment
      # purge — a direct break of the #247 "no retrievable trace" guarantee.
      purge_fragments_with_sidecar
      return true
    end

    false
  rescue ActiveRecord::RecordNotFound
    # Destroy-mid-run race (embedding v2 PR 3, carry-over from review #353): the record
    # was destroyed while this run was working. Its destroy-time purges (before_destroy
    # prepend + dependent delete_all) only saw rows existing at that instant — the
    # fragments THIS run wrote afterwards survive with a dead fragmentable. They are NOT
    # sidecar orphans (their Fragment row lives), so the orphan GC's sidecar sweep never
    # matches them; purge fragments + sidecar synchronously to close the PII window here
    # instead of leaning on the daily fragment sweep.
    purge_fragments_with_sidecar
    true
  end

  # Removes ALL fragments of this record plus their sidecar rows in one txn —
  # shared by the post-run opt-out re-check AND the destroy-mid-run rescue. "All"
  # (not just this run's version_token) is correct in both cases: opted out or
  # destroyed, no fragment of this fragmentable may survive. Sidecar first (the
  # subselect needs the fragment rows — purge_for contract).
  def purge_fragments_with_sidecar
    scope = record.send(fragment_association)
    ActiveRecord::Base.transaction do
      ContentEmbedding.purge_for(embeddable_type: 'Fragment', embeddable_ids: scope.select(:id))
      scope.delete_all
    end
  rescue StandardError => e
    # Tag any purge failure so the outer rescue re-raises it (fail-closed, #354 #4)
    # instead of swallowing it as a generic embedding error. The original error is
    # preserved as #cause (Ruby sets it automatically when raising inside a rescue).
    raise PurgeFailedError, "fragment/sidecar purge failed: #{e.class}: #{e.message}"
  end

  def delete_old_fragments(new_version_token)
    # Basic validations
    return unless record.organisation_id.present? && new_version_token.present?
    return unless record.id.present?
    return unless fragment_association.present?

    begin
      ActiveRecord::Base.transaction do
        # 1. Lock the relevant fragments
        all_fragments = record.send(fragment_association)
                              .where.not(organisation_id: nil)
                              .where(organisation_id: record.organisation_id)
                              .where(fragmentable_id: record.id)
                              .where(fragmentable_type: record.class.name)
                              .where.not(version_token: nil)
                              .where.not(version_token: '')
                              .lock # Adds FOR UPDATE and locks the rows

        # 2. In-memory safety checks
        version_tokens = all_fragments.map(&:version_token).uniq
        return if version_tokens.empty? || !version_tokens.include?(new_version_token)

        new_fragments_count = all_fragments.count { |f| f.version_token == new_version_token }
        return if new_fragments_count == 0

        # 3. Delete all fragments with old version tokens
        old_tokens = version_tokens - [new_version_token]
        return if old_tokens.empty?

        fragments_to_delete = all_fragments.select { |f| old_tokens.include?(f.version_token) }

        Rails.logger.info "Deleting #{fragments_to_delete.count} old fragments for record #{record.id} (organisation: #{record.organisation_id})"

        fragments_to_delete.each(&:destroy!)
      end
    rescue StandardError => e
      Rails.logger.error "Error deleting old fragments: #{e.message}"
      raise
    end
  end

  def create_version_token
    # Explanation of version_token:
    # We need an identifier (version_token) for the new set of fragments.
    # If the update succeeds, all fragments that have a different token than this
    # token can be considered invalid.
    # These old fragments can then be deleted.
    loop do
      token = SecureRandom.uuid
      # Check whether the token already exists
      association = record.send(fragment_association)
      return token unless association.exists?(version_token: token)
    end
  end

  # Default method to dynamically determine the fragment association
  def default_fragment_association
    raise "No valid fragment association found for #{record.class.name}. Please provide one." unless record.respond_to?(:fragments)

    :fragments
  end

  def extract_text_fragments
    text_service = TextProcessingService.new(record.plain_text_version)
    text_service.split_text_into_fragments
  end

  # Returns [embedding, total_tokens] via the metering-aware provider method so the
  # run can sum tokens for ONE aggregated usage row.
  def generate_embedding(text)
    result = embed_provider.embed_with_usage(text: text)
    [result[:embedding], result[:total_tokens].to_i]
  end

  # One AiUsage row for the whole run (document_indexing, token-metered credits).
  # BYOK/non-quota is logged but not billed (resolved inside UsageTracking).
  def record_run_usage(total_tokens, fragment_count)
    Lalabase::Llm::UsageTracking.record_embedding(
      organisation: record.organisation, provider: embed_provider,
      total_tokens: total_tokens, action: Lalabase::Llm::ActionRegistry::DOCUMENT_INDEXING,
      subject: record, fragment_count: fragment_count
    )
  end

  # Resolved once per run (not per fragment) off the org's embedding config.
  def embed_provider
    # :configured — new content is embedded into the space the org is CONFIGURED for,
    # which during a staged switch is the TARGET space being built (PR 6a). It becomes
    # searchable at the flip; that gap is accepted (series plan §11.5).
    @embed_provider ||= Lalabase::Llm::Factory.for_feature(:content_indexing, record.organisation, space: :configured)
  end

  # STEP 1's only writer: the fragment, and nothing else. No provider is resolved here,
  # so this runs for an AI-off organisation exactly as it runs for an AI-on one.
  #
  # The sidecar row that used to share this transaction moved to #attach_embedding. Its
  # stated reason was "a fragment without a vector is invisible to every reader since
  # PR 4b", and that is false for the full-text reader — checked across all five readers
  # in §3 of the plan. The atomicity was protecting nothing and cost the full-text index.
  def create_fragment(fragment_text, version_token)
    record.send(fragment_association).create!(
      plain_text_content: fragment_text,
      version_token: version_token
    )
  end

  # STEP 2's only writer. Stamps the provider/model provenance so a later embedding
  # switch knows which vector space this row belongs to (parity with code_symbols & co.).
  # The fragment already exists, so a failure here leaves it in place, vectorless and
  # still searchable, which is the entire point of the split.
  def attach_embedding(fragment, embedding)
    triple = Lalabase::Indexer::EmbeddingColumns.from(embed_provider)
    # find_or_initialize, not create!, and the reason is a case the review did not
    # foresee: #unembedded_fragments now (correctly) reports a DE-INDEXED row as needing
    # embedding, but that row occupies the same (type, id, triple) slot as the insert.
    # A bare create! collided with idx_content_embeddings_unique_space and, with the
    # rescue below, silently did nothing — the retired row stayed retired and the record
    # was marked done over a vector no reader can see. Re-indexing it is the repair a
    # reindex would perform anyway.
    row = ContentEmbedding.find_or_initialize_by(
      embeddable_type: 'Fragment', embeddable_id: fragment.id, **triple
    )
    row.assign_attributes(
      organisation_id: record.organisation_id,
      embedding: embedding,
      source_hash: ContentEmbedding.source_hash_for(fragment.plain_text_content),
      indexed: true, embedded_at: Time.current
    )
    row.save!
  rescue ActiveRecord::RecordNotUnique
    # The remaining race: another run inserted between the read above and this save.
    # idx_content_embeddings_unique_space is unique over (type, id, provider, model,
    # dims) and ContentEmbedding validates none of it, so a duplicate arrives raw.
    #
    # This became REACHABLE with the reuse branch, and the comment this method replaced
    # said why it had not been before: "the fragment is fresh (new UUID), so its triple
    # row cannot pre-exist". Reuse means two concurrent runs share the fragment ids, and
    # concurrent runs are ordinary — Actors::SaveNote enqueues a job on every save, even
    # a title-only one, and EmbeddingProcessingJob declares no concurrency limit. The
    # window is the whole embed loop, i.e. seconds of network calls.
    #
    # Swallowed rather than raised: the row the other run wrote is the row this one was
    # about to write, same fragment, same space. Letting it through would land in
    # #handle_embedding_error, which writes a Postgres error string into
    # embedding_creation_error and flips the flag to false — the permanent red "Es sind
    # Fehler aufgetreten" that the note on #mark_embeddings_as_successful describes, over
    # a run that in fact succeeded.
    Rails.logger.debug do
      "EmbeddingProcessingService: fragment #{fragment.id} was embedded concurrently — keeping the existing row."
    end
  end

  # Extraction plus the version swap, together and in that order (plan risk 2): the swap
  # has to travel with extraction, or a failed embedding leaves the new fragments next to
  # the old ones and the same text is found twice.
  #
  # REUSE when the text has not moved. Without it the swap would be a regression: a run
  # whose embedding fails would discard the previous set AND its vectors, so a transient
  # 429 would cost the record its semantic ranking even though nothing about the content
  # changed. Comparing the sorted texts also makes a retry cheap — #embed_fragments then
  # only picks up what has no vector yet, instead of re-paying for the whole record.
  #
  # @return [String, nil] the version token now current, or nil when there is nothing to index.
  def write_fragments
    texts = extract_text_fragments
    return nil if texts.empty?

    existing = current_fragments
    tokens = existing.map(&:version_token).uniq
    # ONE token, or no reuse. `existing.first.version_token` names a single fragment, and
    # everything downstream (#fragments_of, #embed_fragments, #fully_embedded?) then works
    # on that token's subset alone — a set split across two tokens whose UNION happens to
    # match the new text would leave the other token's fragments holding stale text in the
    # full-text index, unreachable by this run. Rare, because delete_old_fragments is
    # transactional, and one line to rule out.
    return tokens.first if tokens.size == 1 && existing.map(&:plain_text_content).sort == texts.sort

    new_version_token = create_version_token
    texts.each { |fragment_text| create_fragment(fragment_text, new_version_token) }
    delete_old_fragments(new_version_token)
    new_version_token
  end

  # Embeds exactly the fragments of this version that have no vector yet. On a first run
  # that is all of them; on a retry after a rate limit it is only the remainder.
  def embed_fragments(version_token)
    pending = unembedded_fragments(version_token)
    return if pending.empty?

    total_tokens = 0
    pending.each do |fragment|
      embedding, tokens = generate_embedding(fragment.plain_text_content)
      total_tokens += tokens
      attach_embedding(fragment, embedding)
    end
    # ONE aggregated metering row per run (decision 1A): summed tokens over the fragments
    # this run actually embedded, subject = the indexed record. Never raises.
    record_run_usage(total_tokens, pending.size)
  end

  # Ordered because the CALLER picks a row out of it, not because the comparison needs it
  # — that one sorts both sides itself. #write_fragments reads the version token off this
  # set, and an unordered relation carries no ORDER BY, so PostgreSQL may return the rows
  # in any order it likes and a different run could pick a different row.
  def current_fragments
    record.send(fragment_association).order(:created_at, :id).to_a
  end

  def fragments_of(version_token)
    record.send(fragment_association).where(version_token: version_token)
  end

  # "Which fragments of this version cannot be READ in the space we are writing into."
  #
  # ⚠️ NOT "which have no sidecar row". That weaker question was the first draft and it is
  # a second, quieter definition of the rule Embeddings::NearestNeighbors already owns:
  # the reader filters on the full triple AND `indexed` (its INDEX_PREDICATE_SQL), so a
  # row in a RETIRED space, or one whose `indexed` was cleared, satisfies "has a row"
  # while being invisible to every search. Combined with the reuse branch above that was
  # a one-way door: unchanged text after a model switch would re-embed nothing,
  # #fully_embedded? would answer true, the flag would go to true, and
  # Embeddings::PendingEmbeddings would never hand the record out again.
  #
  # So the anti-join is BORROWED, not rewritten — Embeddings::OrganisationReindexer
  # already carries it (missing_readable_row_sql), and it is the same predicate the flip
  # validation and `rake embeddings:status` ask. Fragment#with_sidecar_embedding and the
  # note above missing_in_space both warn about exactly this second definition.
  def unembedded_fragments(version_token)
    triple = Lalabase::Indexer::EmbeddingColumns.from(embed_provider)
    fragments_of(version_token)
      .where(Embeddings::OrganisationReindexer.missing_readable_row_sql(Fragment),
             *triple.values_at(:embedding_provider, :embedding_model, :embedding_dims))
      .order(:created_at, :id).to_a
  end

  # The condition for calling a run "done". False for an AI-off organisation (nothing was
  # embedded) and false after a partial failure, which is what keeps such a record on
  # Embeddings::PendingEmbeddings until it really is embedded.
  def fully_embedded?(version_token)
    return false unless record.organisation&.ai_enabled?

    unembedded_fragments(version_token).empty?
  end

  # ⚠️ Clearing the error is part of succeeding, not decoration. Without it a record that
  # failed once stayed "failed" forever: #handle_embedding_error writes
  # embedding_creation_error, nothing ever wrote it back to nil, and every reader of
  # "how much failed" counts the COLUMN, not the flag. The consequence became visible the
  # day the AI area hung an action on that figure (KI-Bereich S4): the Indexierung page
  # showed a permanent red "Es sind Fehler aufgetreten" with a "Neu verarbeiten" button —
  # and the button enqueued nothing, because Embeddings::PendingEmbeddings selects on the
  # FLAG, which the successful retry had already set to true. An alarm the admin cannot
  # clear, next to an action that cannot help.
  #
  # Fixed at the source rather than by narrowing the readers: "failed" would otherwise
  # need a second definition (error present AND flag not true) in every counter, which is
  # exactly the duplicated rule this area has been removing.
  def mark_embeddings_as_successful
    raise "The model #{record.class.name} does not have an embeddings_creation_flag attribute." unless record.respond_to?(:embeddings_creation_flag)

    attributes = { embeddings_creation_flag: true }
    attributes[:embedding_creation_error] = nil if record.respond_to?(:embedding_creation_error)
    record.update(**attributes)
  end

  def handle_embedding_error(error)
    if record.respond_to?(:embedding_creation_error) && record.respond_to?(:embeddings_creation_flag)
      record.update_columns(
        embeddings_creation_flag: false,
        embedding_creation_error: error.message
      )
    end
    Rails.logger.error "Error creating embeddings for #{record.class.name} with ID #{record.id}: #{error.message}"
  end
end
