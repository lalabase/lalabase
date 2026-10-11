# frozen_string_literal: true

module Organisations
  # Manage a project's documentation sets (connect a repo folder, rename,
  # disconnect) and trigger a manual sync. All writes go through actors and
  # require :documentation write access; the read-only history (logbook) view
  # only needs read access.
  class DocumentationSetsController < Organisations::BaseController
    include ProjectController

    # Same reasoning as DocumentationController: the generic per-controller area
    # check does not map to the :documentation area; every action authorizes
    # explicitly instead.
    skip_before_action :authorize_project_access!
    before_action :set_documentation_set, only: %i[edit update destroy sync history]
    # The form needs the connectable repos both on first render and when it is
    # re-rendered after a validation failure.
    before_action :load_repositories, only: %i[new create edit update]

    def new
      @documentation_set = @project.documentation_sets.build
      authorize @documentation_set
    end

    def create
      # This bare build exists only so Pundit has a record to authorize; the
      # actor builds and owns the record that is actually saved.
      @documentation_set = @project.documentation_sets.build
      authorize @documentation_set

      result = Actors::SaveDocumentationSet.call(project: @project, params: set_params, current_user: current_user)

      if result.success?
        redirect_to documentation_path(set_id: result.resource.id),
                    notice: t('flash.documentation_sets.create.success')
      else
        @documentation_set = result.resource
        flash.now[:alert] = result.errors.to_sentence
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @documentation_set
    end

    def update
      authorize @documentation_set

      result = Actors::SaveDocumentationSet.call(
        project: @project, id: @documentation_set.id, params: set_params, current_user: current_user
      )

      if result.success?
        redirect_to documentation_path(set_id: @documentation_set.id),
                    notice: t('flash.documentation_sets.update.success')
      else
        @documentation_set = result.resource
        flash.now[:alert] = result.errors.to_sentence
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @documentation_set
      @documentation_set.destroy!
      redirect_to documentation_path, notice: t('flash.documentation_sets.destroy.success')
    end

    # Page-size decisions for the logbook view. COMMITS_SHOWN is deliberately
    # its own constant (not GitLogReader::MAX_COMMITS): the reader bounds ONE
    # sync's fetch, but the table grows append-only across syncs — this bounds
    # what one page shows. SYNC_RUNS_SHOWN: enough to spot a failure pattern,
    # short enough to stay glanceable.
    COMMITS_SHOWN = 100
    SYNC_RUNS_SHOWN = 20

    # Logbook (Slice 2): the set's git change history + recent sync runs.
    def history
      authorize @documentation_set, :show?

      @commits = @documentation_set.documentation_commits.recent.limit(COMMITS_SHOWN)
      @sync_runs = @documentation_set.documentation_sync_runs.recent.limit(SYNC_RUNS_SHOWN)
    end

    def sync
      authorize @documentation_set, :sync?

      result = Actors::TriggerDocumentationSync.call(documentation_set: @documentation_set, current_user: current_user)

      if result.success?
        redirect_to documentation_path(set_id: @documentation_set.id),
                    notice: t('flash.documentation_sets.sync.started')
      else
        redirect_to documentation_path(set_id: @documentation_set.id),
                    alert: result.errors.to_sentence
      end
    end

    private

    def documentation_path(**params)
      organisation_project_documentation_index_path(@current_organisation, @project, **params)
    end

    def set_documentation_set
      # Tenant + project scope the lookup; the per-action `authorize` is the real
      # gate (it understands role-based and admin access, which a scope cannot).
      @documentation_set = @project.documentation_sets.find(params[:id])
    end

    def load_repositories
      @repositories = @project.project_repositories
    end

    def set_params
      params.require(:documentation_set).permit(:name, :path_prefix, :project_repository_id)
    end
  end
end
