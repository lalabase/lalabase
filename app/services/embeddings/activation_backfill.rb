# frozen_string_literal: true

module Embeddings
  # Runs once when an organisation ACTIVATES the AI opt-in (D2 review
  # decision): everything the pipelines deliberately skipped while AI was off
  # must catch up, or RAG chat and semantic search stay silently incomplete.
  #
  # Three halves by now:
  # 0. The vector-space POINTER (KI-Pakete P4b precondition 3). Nothing gave a newly
  #    activated org an active_embedding_space_id: the column's only writers were
  #    Actors::FlipEmbeddingModel — which only ever runs for an org that already has a
  #    staged switch to finish — and the one-off `embeddings:backfill_spaces` task.
  #    See #ensure_active_space_pointer.
  # 1. Content embeddings — delegates to EmbeddingReprocessingService, which
  #    only enqueues records whose embeddings_creation_flag is still unset.
  #    Cost is proportional to what was actually missed.
  # 2. Repo indexes — the indexer settles indexes as failed-with-marker while
  #    AI is off (JobSupport#ai_enabled_or_settle_index!), and connect-created
  #    indexes may still sit at 'pending' if their job never ran. Exactly those
  #    two states are re-enqueued; real failures (other error_message) are NOT
  #    retried here — retrying e.g. an auth failure would just fail again and
  #    hide the actionable error from the admin.
  #
  # Extracted from AiSettingsController#activate so the revive filter is unit-
  # testable without request-level after_commit timing interference.
  class ActivationBackfill
    def self.call(organisation)
      new(organisation).call
    end

    def initialize(organisation)
      @organisation = organisation
    end

    # @return [Hash] the EmbeddingReprocessingService result ({success:, total_jobs:, …}).
    #   RETURNED rather than discarded: that service reports its refusals (AI off, quota
    #   exhausted) and its own rescue in the RETURN VALUE, never by raising. Dropping it
    #   here made a catch-up that enqueued nothing indistinguishable from one that enqueued
    #   five hundred, and the caller then announced plain success either way. The repo-index
    #   revive stays a side effect: it has no failure to report that is not already logged.
    def call
      # BEFORE the embedding work, so the pointer already names the space those
      # vectors land in (writes go to the CONFIGURED triple, which is exactly what
      # EnsureSpace resolves).
      ensure_active_space_pointer
      result = EmbeddingReprocessingService.new(@organisation).call
      revive_gate_settled_repository_indexes
      result
    end

    # The decision point of the revive half, kept as a PURE class method so the
    # filter can be unit-tested with plain ProjectIndex instances — no repo
    # factories, whose connect callback enqueues jobs and muddies spy counts.
    def self.revivable_index?(index)
      return false if index.nil?
      return true if index.status == 'pending'

      index.status == 'failed' &&
        index.error_message == Lalabase::Indexer::JobSupport::AI_DISABLED_ERROR_MESSAGE
    end

    private

    # Give the org the pointer that makes a STAGED switch possible at all.
    #
    # Without one, Factory.embedding_space_for(:active) falls back to the configured
    # triple (factory.rb:263-276), so "which space serves" and "which space would be
    # written" become the same expression. That reads as healthy everywhere — the
    # switch watcher, SpaceAlignment and `embeddings:check_alignment` all inherit the
    # fallback — while the org is quietly incapable of a staged switch: a package
    # change would move reads onto the new, empty space immediately (a HARD switch,
    # search empty until the rebuild finishes) and no flip would ever end it.
    #
    # Activation is the right seam because it is the only moment where the answer is
    # UNAMBIGUOUS: nothing has been embedded yet, so there is exactly one candidate
    # space. Asked later — say from the watcher, for an org that already holds vectors
    # — "which space is this org actually on" needs a content_embeddings scan, the cost
    # E1 rules out.
    #
    # Never overwrites: an org that already points somewhere (re-activation after a
    # deactivate) keeps its space, exactly like `embeddings:backfill_spaces`.
    #
    # FAIL-SOFT on purpose. Activation is the GDPR opt-in and must not be blocked by a
    # missing or undecryptable credential — EnsureSpace resolves one and therefore
    # raises. The org then simply stays as it was before this method existed, and
    # `embeddings:check_alignment` reports it (the same rescue-and-report shape
    # SpaceAlignment#resolve_space uses for the same reason).
    def ensure_active_space_pointer
      return if @organisation.active_embedding_space_id.present?

      space = ::Embeddings::EnsureSpace.call(organisation: @organisation)
      # update_column, matching Actors::FlipEmbeddingModel: this is a pointer move, not
      # a state change of the organisation — no validations, no callbacks.
      @organisation.update_column(:active_embedding_space_id, space.id)
      Rails.logger.info("Embeddings::ActivationBackfill: organisation #{@organisation.id} " \
                        "now serves from #{space.label}")
    rescue StandardError => e
      Rails.logger.warn("Embeddings::ActivationBackfill: organisation #{@organisation.id} " \
                        "activated WITHOUT a vector-space pointer (#{e.class}: #{e.message}). " \
                        'Staged switches are unavailable until it has one — run ' \
                        "\"embeddings:backfill_spaces[#{@organisation.id}]\" once credentials resolve.")
    end

    def revive_gate_settled_repository_indexes
      # Without the operator switch the indexer job would skip anyway — don't enqueue
      # guaranteed no-ops.
      return unless @organisation.code_indexing?

      ProjectRepository.where(organisation: @organisation).includes(:project_index).find_each do |repo|
        next unless self.class.revivable_index?(repo.project_index)

        ProjectIndexerJob.perform_later(repo)
      end
    end
  end
end
