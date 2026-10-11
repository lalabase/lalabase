# frozen_string_literal: true

module Lalabase
  module Indexer
    # Shared support for the indexing jobs (ProjectIndexerJob + RepoReindexJob)
    # so both behave identically and the token-redaction contract lives in ONE
    # place. Mixed in via `include`.
    module JobSupport
      private

      # Records an indexing failure on the index row, logs it, and re-raises a
      # token-scrubbed exception. Two redaction calls on purpose: error_message
      # only needs the string scrubbed, but the re-raised exception additionally
      # scrubs its backtrace, which SolidQueue::FailedExecution + error trackers
      # persist verbatim. self.class.name keeps the log prefix correct per job.
      def fail_index!(index, repo, error)
        token = repo.access_token
        sanitized = Lalabase::Indexer::SecretRedaction.redact("#{error.class}: #{error.message}", token)
        Rails.logger.error "#{self.class.name}: failed for repo #{repo.id} — #{sanitized}"
        index.update!(status: 'failed', error_message: index_error_message(error, repo))
        # Notify the connector of the failure (M9-5) — covers BOTH the initial
        # index and push re-index, since both jobs funnel failures here. Best-
        # effort + must run before the re-raise below.
        Notifications::IndexOutcomeNotifier.call(repository: repo, outcome: :failed)
        raise Lalabase::Indexer::SecretRedaction.scrub_exception(error, token)
      end

      # Writes ONE indexing-run history row (success or failure), shared by both
      # jobs. Best-effort: a failure to record history must never break the actual
      # index — so it rescues and only logs. The error message is token-redacted,
      # same contract as fail_index!. A history row has many independent fields —
      # explicit keyword args are clearer than a Hash blob.
      def record_index_run(repo:, trigger:, status:, started_at:, incremental:,
                           commit_sha: nil, files_count: 0, symbols_added: 0,
                           symbols_removed: 0, error: nil, triggered_by_user_id: nil)
        message = index_error_message(error, repo) if error
        ProjectIndexRun.create!(
          organisation: repo.organisation,
          project_repository: repo,
          trigger: trigger,
          status: status,
          incremental: incremental,
          started_at: started_at,
          finished_at: Time.current,
          commit_sha: commit_sha,
          files_count: files_count,
          symbols_added: symbols_added,
          symbols_removed: symbols_removed,
          error_message: message,
          triggered_by_user_id: triggered_by_user_id
        )
      rescue StandardError => e
        Rails.logger.error "#{self.class.name}: failed to record index run — #{e.class}: #{e.message}"
      end

      # Actionable, user-facing message (German — the app default locale; stored and
      # shown as-is) when the failure cause is a token/access problem the connector
      # can actually fix. Returns nil for anything else, so the caller keeps the raw
      # technical detail. Covers both the API errors (Github::Client) and the git
      # clone/fetch auth failure (GitCloner::AuthenticationError).
      def friendly_index_error(error)
        case error
        when Lalabase::Github::Client::AuthError,
             Lalabase::Indexer::GitCloner::AuthenticationError
          I18n.t('views.organisations.indexing.errors.auth_failed')
        when Lalabase::Github::Client::InvalidScopeError
          I18n.t('views.organisations.indexing.errors.insufficient_scope')
        when Lalabase::Github::Client::NotFoundError
          I18n.t('views.organisations.indexing.errors.repo_not_found')
        end
      end

      # The string persisted to ProjectIndex#error_message / ProjectIndexRun#error_message
      # (both rendered in the UI): the actionable message when we recognise the cause,
      # else the token-redacted technical detail (truncated).
      def index_error_message(error, repo)
        friendly_index_error(error) ||
          Lalabase::Indexer::SecretRedaction
            .redact("#{error.class}: #{error.message}", repo.access_token)
            .truncate(2000)
      end

      # Memoised per perform so Layer 4/3 + Layer 1 (initial index) and the
      # incremental reindex each resolve the org's BYOK embedding provider once.
      # Safe ONLY because one perform handles exactly one repo → one org: the
      # memo ignores its argument after the first call. If a job ever loops over
      # multiple orgs in a single perform, this must key by organisation instead.
      def embedding_provider(organisation)
        # :configured — indexing WRITES, so it fills the target space (PR 6a).
        @embedding_provider ||= Lalabase::Llm::Factory.for_feature(
          :repository_indexing, organisation, lane: :embedding, space: :configured
        )
      end

      # The per-org beta gate (M10/D3) applies to BACKGROUND indexing too, not
      # just the Pundit UI. RepoReindexJob is triggered by GitHub webhooks, which
      # bypass Pundit entirely — so without this an org with the feature toggled
      # OFF would keep cloning + re-embedding its repo on every push. Both jobs
      # short-circuit on it: the policies gate access, this gates the actual work.
      # Silent skip on purpose: the switch is operator-managed, indexes wait untouched
      # until the operator flips it back.
      def code_indexing?(repo)
        repo.organisation.code_indexing?
      end

      # Marker for indexes settled by the AI opt-in gate. Shared with
      # AiSettingsController#activate, which revives exactly these indexes.
      AI_DISABLED_ERROR_MESSAGE = 'AI features are not enabled for this organisation'

      # GDPR AI opt-in gate (audit 2026-07-03) — deliberately NOT a silent skip
      # like the beta gate above: leaving the index 'pending' would deadlock it
      # (pending counts as in-progress, so the manual reindex button refuses
      # forever). Settling as 'failed' with a marker message keeps the index
      # actionable: the button works again, and activation re-enqueues exactly
      # the marker-settled indexes. Returns true when indexing may proceed.
      def ai_enabled_or_settle_index!(repo)
        return true if repo.organisation.ai_enabled?

        index = repo.project_index
        if index&.status&.in?(%w[pending indexing stale])
          index.update!(status: 'failed',
                        error_message: AI_DISABLED_ERROR_MESSAGE)
        end
        Rails.logger.debug { "Indexer: AI disabled for organisation #{repo.organisation_id} — index settled, job skipped" }
        false
      end
    end
  end
end
