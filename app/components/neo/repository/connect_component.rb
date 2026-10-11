# frozen_string_literal: true

module Neo
  module Repository
    # Repo-connect UI. Renders:
    #  - a list of currently-connected repositories (with a Disconnect button each)
    #  - an "add new" form (full_name + PAT input)
    #  - inline help on how to create a fine-grained PAT
    class ConnectComponent < ViewComponent::Base
      # origin: opaque round-trip marker (currently only 'documentation'). When the
      # user reached this page from the documentation flow it travels through the
      # connect form as a hidden field, so the controller can redirect back there
      # after a successful connect — and, crucially, so it SURVIVES a failed connect
      # (render :new), which a query param would not. nil = no round-trip.
      def initialize(project:, repositories:, new_repository:, current_organisation:, origin: nil)
        @project = project
        @repositories = repositories
        @new_repository = new_repository
        @current_organisation = current_organisation
        @origin = origin
      end

      def disconnect_path(repo)
        helpers.organisation_project_project_repository_path(@current_organisation, @project, repo)
      end

      def create_path
        helpers.organisation_project_project_repositories_path(@current_organisation, @project)
      end

      # Indexing run history of this repo (when/what/how long re-indexed).
      def index_runs_path(repo)
        helpers.index_runs_organisation_project_project_repository_path(@current_organisation, @project, repo)
      end

      # POST target for the manual "reindex now" trigger.
      def reindex_path(repo)
        helpers.reindex_organisation_project_project_repository_path(@current_organisation, @project, repo)
      end

      # PATCH target for rotating the repo's access token (expired-PAT recovery).
      def update_token_path(repo)
        helpers.update_token_organisation_project_project_repository_path(@current_organisation, @project, repo)
      end

      # Index states in which a run has SETTLED — only then does a manual reindex
      # button make sense. While one is pending/indexing/stale the status badge
      # already shows progress and the controller would refuse a second trigger.
      SETTLED_INDEX_STATUSES = %w[ready failed].freeze

      # Show the reindex button only to users who could connect/disconnect (same
      # write gate as the webhook secret) and only for a settled index.
      def reindexable?(repo)
        return false unless can_manage?(repo)

        index = repo.project_index
        index.present? && SETTLED_INDEX_STATUSES.include?(index.status)
      end

      def any_repositories?
        @repositories.any?
      end

      def pat_help_url
        'https://github.com/settings/personal-access-tokens/new'
      end

      # Indexing is behaviour-gated on the per-org chat beta: both indexer jobs
      # no-op without it (project_indexer_job / repo_reindex_job), and the push
      # webhook only feeds the reindex job. So the index status / reindex / run
      # history / webhook UI is only meaningful — and only rendered — when chat is
      # enabled. A chat-less org can still CONNECT a repo (for documentation sync)
      # and rotate its token; it just gets no index UI (which would read as a
      # permanent "never indexed" error).
      def indexing_ui_enabled?
        # Both halves of the indexing gate: the chat beta AND — since R4
        # (doc/ai_feature_registry_plan.md) — the :repository_indexing row in place of the
        # bare opt-in. That row is what ProjectIndexerJob routes on, and it is the only
        # entry declaring BOTH lanes, because the job builds a chat provider for the
        # layer-4 summaries and an embedding provider for the fragments. The opt-in alone
        # could not see either: an org that chats on Anthropic (which cannot embed) has
        # the opt-in and still cannot index, and the old gate offered it the full index UI
        # for a pipeline that settles as failed.
        @current_organisation.code_indexing? && repository_indexing.available?
      end

      # Memoised because indexing_ui_enabled? is asked once PER REPOSITORY inside the list
      # (plan §7.6): unlike the attribute read it replaces, resolving a feature can reach
      # AiCredential.active_for_provider — a Solid-Cache SELECT in production. The
      # organisation instance memoises the answer too; this keeps the single resolution
      # local and visible instead of resting on the model's cache.
      def repository_indexing
        return @repository_indexing if defined?(@repository_indexing)

        @repository_indexing = @current_organisation.ai_available_for?(:repository_indexing)
      end

      # The reason belongs on the page ONCE, below the list — not inside it, where the
      # same sentence would repeat for every connected repo. Withheld while the operator
      # switch is off: that is a different gate with a different remedy, and it is also
      # the state in which the org is not asking for an index at all.
      def show_indexing_unavailable_hint?
        any_repositories? && @current_organisation.code_indexing? &&
          !repository_indexing.available?
      end

      # Webhook URL + secret are management details — only users who could
      # connect/disconnect the repo (admins, chats:write, or documentation:write)
      # may see the secret.
      def can_manage?(repo)
        helpers.policy(repo).create?
      end

      # May the current user connect a NEW repo? Gates the whole add-new form.
      # ProjectRepositoryPolicy#index? only needs chats:read, so read-only visitors
      # reach this page by URL; without this gate they'd see a connect form that
      # 403s on submit. Uses the not-yet-persisted @new_repository (same policy,
      # project-derived) — no per-repo instance needed.
      def can_connect?
        helpers.policy(@new_repository).create?
      end

      # Absolute URL the user pastes into GitHub's webhook "Payload URL" field.
      def webhook_url(repo)
        helpers.webhooks_repository_url(repo)
      end
    end
  end
end
