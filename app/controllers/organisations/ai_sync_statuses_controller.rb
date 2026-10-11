# frozen_string_literal: true

# The AI area's "Indexierung" page (doc/ki_bereich_navigation_plan.md §3.5).
#
# Two readers of the same columns on purpose, at two levels of detail: the summary at
# the top answers "is anything wrong and what do I press" from Embeddings::IndexHealth
# (one query, org-wide, the SAME source as the hub card so the two can never disagree),
# and AiSyncStatusService keeps feeding the per-project table below it as the detail.
# A summary derived from @sync_statistics would be the second derivation the plan
# explicitly rules out.
class Organisations::AiSyncStatusesController < Organisations::BaseController
  before_action :authorize_ai_sync_access!

  def show
    # with_space: the summary NAMES the vector space it counted in (§3.5 Fortschreibung).
    @index_health = ::Embeddings::IndexHealth.call(organisation: @current_organisation, with_space: true)
    # Why a backlog is moving is a question only this can answer: during a staged switch
    # the page would otherwise report "ausstehend" without the reason, and the admin
    # would reach for the one button that does not help (P4a/P4d, §3.5).
    @switch_progress = ::Embeddings::SwitchProgress.call(organisation: @current_organisation)
    # Whether anything is SERVING that backlog. Without it a pending count is not an
    # answer: "12 ausstehend" reads as progress whether a worker picked them up a minute
    # ago or the queue has gone unattended for months. Asked here and not on the hub
    # (§3.3 query budget) — this page is where the admin comes to act on the number.
    @indexing_pipeline = ::Embeddings::IndexingPipeline.call
    @sync_statistics = AiSyncStatusService.call(organisation: @current_organisation)
  end

  def reprocess_embeddings
    authorize @current_organisation, :reprocess_embeddings?, policy_class: AiSyncStatusPolicy

    result = EmbeddingReprocessingService.new(@current_organisation).call

    if result[:success]
      flash[:notice] = t('flash.ai_sync_statuses.started', count: result[:total_jobs])
    else
      flash[:alert] = t('flash.ai_sync_statuses.start_error', error: result[:error])
    end

    redirect_to organisation_ai_sync_status_path(@current_organisation)
  end

  private

  def authorize_ai_sync_access!
    authorize @current_organisation, :show?, policy_class: AiSyncStatusPolicy
  end
end
