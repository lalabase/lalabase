# frozen_string_literal: true

# Connects a Project to one or more GitHub repositories (project-aware chat).
#
# Phase 1 uses a Personal Access Token paste flow: the user creates a fine-grained
# PAT with `Contents: Read` on github.com and pastes it into the form. We validate
# via two GitHub API calls before persisting an encrypted copy.
#
# GitLab and full OAuth come in later milestones — schema (project_repositories.provider)
# is already prepared but only 'github' is wired in M4.
module Organisations
  class ProjectRepositoriesController < Organisations::BaseController
    # How many of the most recent indexing runs the history view shows.
    RECENT_RUNS_LIMIT = 50

    # Index states during which a run is already in flight — a manual reindex is
    # refused so we never enqueue a second, overlapping job.
    IN_PROGRESS_INDEX_STATUSES = %w[pending indexing stale].freeze

    # Known round-trip origins (see #sanitized_origin). An ENUM, not a free return_to
    # path: the connect page is reached from the documentation flow, which wants the
    # user sent BACK there after connecting. A closed allowlist rules out any
    # open-redirect surface — an unknown value is simply ignored. The origin VALUE
    # lives in RepositoriesHelper so the controller and the CTA/back-link views share
    # one source.
    KNOWN_ORIGINS = [RepositoriesHelper::ORIGIN_DOCUMENTATION].freeze

    before_action :set_project
    before_action :set_repository, only: %i[destroy index_runs reindex update_token]
    before_action :set_origin, only: %i[index new create]

    def index
      @repositories = policy_scope(ProjectRepository).where(project: @project)
                                                     .order(:created_at)
      # Backfill webhook secrets for repos connected before the secret column
      # existed (idempotent no-op once set). Done here, not in the view, so the
      # only DB write on this GET is explicit and the secret is guaranteed
      # present when the connect component renders it.
      @repositories.each(&:ensure_webhook_secret!)
    end

    def new
      @repository = ProjectRepository.new(project: @project, organisation: @current_organisation,
                                          provider: 'github')
      authorize @repository, :create?
    end

    def create
      @repository = ProjectRepository.new(repository_params.merge(
                                            project: @project, organisation: @current_organisation,
                                            provider: 'github', connected_by_user: current_user,
                                            connected_at: Time.current
                                          ))
      authorize @repository, :create?

      metadata = validate_via_github!(@repository)
      @repository.assign_attributes(metadata) if metadata

      if metadata && @repository.save
        redirect_to after_connect_path,
                    notice: t('flash.project_repositories.create.success', name: @repository.full_name)
      else
        # @origin (set by set_origin from the hidden field) must ride along into the
        # re-render so a second attempt still knows the round-trip. See ConnectComponent.
        render :new, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @repository, :destroy?
      full_name = @repository.full_name
      @repository.destroy!
      redirect_to organisation_project_project_repositories_path(@current_organisation, @project),
                  notice: t('flash.project_repositories.destroy.success', name: full_name)
    end

    # Indexing run history of a repo (when/what/how long re-indexed).
    def index_runs
      authorize @repository, :show?
      @runs = @repository.project_index_runs.recent.limit(RECENT_RUNS_LIMIT)
    end

    # Manually trigger an incremental re-index (same path the push webhook uses;
    # the job resolves the branch head itself since there is no push payload).
    def reindex
      authorize @repository, :reindex?

      # Behaviour gate (NOT authorisation): the repo policy is decoupled from this
      # switch so documentation-only managers can connect/rotate a repo — but INDEXING
      # stays gated on it (both indexer jobs no-op without it). The reindex button is
      # hidden for an organisation without it; refuse a direct POST too, rather than
      # enqueue a guaranteed no-op job and falsely report "reindex started".
      unless @current_organisation.code_indexing?
        return redirect_to repositories_path,
                           alert: t('flash.project_repositories.reindex.feature_disabled')
      end

      # Same rule for the AI half — and since R4 that half is the :repository_indexing
      # ROW, not the bare opt-in, because that is what the reindex BUTTON now asks
      # (Neo::Repository::ConnectComponent#indexing_ui_enabled?). Mirroring only
      # ai_enabled? would leave the button hidden while a direct POST or a stale tab
      # still answered "reindex started" for a run that settles as failed — the very
      # false success this pair of guards exists to prevent. One row, one answer, on
      # both sides of the click.
      indexing = @current_organisation.ai_available_for?(:repository_indexing)
      unless indexing.available?
        # The opt-in keeps its ADMIN wording: everyone who reaches this action holds a
        # write permission and can act on it, unlike the member-facing surfaces the
        # registry's own sentence is written for. Every other reason has exactly one
        # text, and it comes from the registry (R3).
        alert = if indexing.reason == :ai_disabled
                  t('shared.ai.disabled_admin_hint')
                else
                  Lalabase::Llm::FeatureRegistry.unavailable_hint(indexing, @current_organisation)
                end
        return redirect_to repositories_path, alert: alert
      end

      index = @repository.project_index
      # Refuse while a run is already in flight, so a double-click can't spawn a
      # second overlapping job. A settled (ready/failed) or never-indexed repo
      # is fair game.
      if index&.status&.in?(IN_PROGRESS_INDEX_STATUSES)
        return redirect_to repositories_path,
                           notice: t('flash.project_repositories.reindex.already_running',
                                     name: @repository.full_name)
      end

      RepoReindexJob.perform_later(@repository, trigger: 'manual', triggered_by_user_id: current_user.id)
      redirect_to repositories_path,
                  notice: t('flash.project_repositories.reindex.started', name: @repository.full_name)
    end

    # Rotate a connected repo's access token (e.g. after the fine-grained PAT
    # expired) WITHOUT disconnecting — so the existing index survives. Validates the
    # new token against GitHub first, exactly like connect; only persists on success.
    def update_token
      authorize @repository, :update?

      @repository.access_token = update_token_params[:access_token].to_s
      metadata = validate_via_github!(@repository)

      if metadata && @repository.save
        redirect_to repositories_path,
                    notice: t('flash.project_repositories.update_token.success', name: @repository.full_name)
      else
        redirect_to repositories_path,
                    alert: @repository.errors.full_messages.to_sentence.presence ||
                           t('flash.project_repositories.update_token.error', name: @repository.full_name)
      end
    end

    private

    def repositories_path
      organisation_project_project_repositories_path(@current_organisation, @project)
    end

    # Reads the round-trip marker from params on GET (query) and POST (hidden
    # field), collapsing anything unknown to nil. One place, so #new and its
    # re-render (render :new after a failed connect) agree on the value.
    def set_origin
      @origin = sanitized_origin
    end

    def sanitized_origin
      params[:origin] if KNOWN_ORIGINS.include?(params[:origin])
    end

    # Where to land after a successful connect: back into the documentation
    # set-creation flow when we came from there, otherwise the repo page as before.
    def after_connect_path
      if @origin == RepositoriesHelper::ORIGIN_DOCUMENTATION
        new_organisation_project_documentation_set_path(@current_organisation, @project)
      else
        repositories_path
      end
    end

    def set_project
      @project = @current_organisation.projects.find(params[:project_id])
      # Coarse project gate for the repo page (also closes the existence/name leak in
      # #index, which has no own authorize). Deliberately gated through the REPO
      # policy, NOT ProjectPolicy#show?: the repo page's audience is exactly "who may
      # read this project's repos" = chats:read OR documentation:write. ProjectPolicy#show?
      # is both too WIDE (it admits e.g. tickets-only readers, who then see an empty
      # page the scope shows nothing in) and — the bug this fixes — too NARROW for a
      # GLOBAL documentation:write manager: its has_global_read_permission? checks only
      # literal read_access_* actions and ignores write-implies-read, locking that
      # manager out of the very page the decoupled policy grants them. Authorizing the
      # Project against ProjectRepositoryPolicy#show? keeps this gate consistent with
      # both the per-action authorize calls and the policy_scope. Denial stays a Pundit
      # redirect (no 404).
      authorize @project, :show?, policy_class: ProjectRepositoryPolicy
    end

    def set_repository
      @repository = @project.project_repositories.find(params[:id])
    end

    def repository_params
      params.require(:project_repository).permit(:full_name, :access_token)
    end

    # Token rotation only touches the secret — full_name/repo identity is fixed.
    def update_token_params
      params.require(:project_repository).permit(:access_token)
    end

    # Calls the GitHub API to (a) verify the token works and (b) read the repo's
    # canonical metadata (id, default_branch). On failure, populates @repository.errors
    # so render :new shows them — no crash, no exception escapes.
    #
    # Returns the metadata hash on success, nil on failure.
    def validate_via_github!(repository)
      client = Lalabase::Github::Client.new(token: repository.access_token.to_s)
      client.validate_token!
      metadata = client.fetch_repo_metadata!(repository.full_name.to_s.strip)
      {
        provider_repo_id: metadata[:provider_repo_id],
        default_branch: metadata[:default_branch],
        full_name: metadata[:full_name]
      }
    rescue Lalabase::Github::Client::AuthError
      # Added on :base (not :access_token) so the connect form shows the actionable
      # sentence without an "Access token" attribute prefix.
      repository.errors.add(:base, t('views.organisations.project_repositories.connect_errors.auth'))
      nil
    rescue Lalabase::Github::Client::NotFoundError
      # GitHub returns 404 both for a wrong name AND for a private repo the token
      # cannot see — the message must cover both so the user checks the PAT's repo
      # access, not just the spelling.
      repository.errors.add(:base, t('views.organisations.project_repositories.connect_errors.not_found'))
      nil
    rescue Lalabase::Github::Client::InvalidScopeError
      repository.errors.add(:base, t('views.organisations.project_repositories.connect_errors.insufficient_scope'))
      nil
    rescue Lalabase::Github::Client::RateLimitError => e
      repository.errors.add(:base, :rate_limited, message: e.message)
      nil
    rescue Lalabase::Github::Client::Error => e
      repository.errors.add(:base, :github_error, message: e.message)
      nil
    end
  end
end
