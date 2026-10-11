# frozen_string_literal: true

module Organisations
  # Read-only browsing of a project's synced documentation: pick a set, walk the
  # page tree, render a page. Mirrors KnowledgeController's viewport switching.
  class DocumentationController < Organisations::BaseController
    include ViewportSwitchable
    include ProjectController

    # Below this term length the search frame stays empty (no "no results" noise
    # while typing the first character). Matches the frame-search JS min length
    # and the in-app help search.
    MIN_SEARCH_TERM_LENGTH = 2

    # The generic per-controller area check does not map cleanly here; gate on
    # the :documentation area explicitly instead.
    skip_before_action :authorize_project_access!
    before_action :require_documentation_read, only: %i[index search]
    before_action :set_viewport_mode, only: [:index]

    # :search is read-only like :index — it scopes results via policy_scope, not a
    # single-record authorize, so it satisfies the same Pundit contract as :index
    # (BaseController wires verify_authorized for every non-index action).
    skip_after_action :verify_authorized, only: :search
    after_action :verify_policy_scoped, only: :search

    def index
      @sets = policy_scope(DocumentationSet.where(project: @project).ordered).to_a
      @documentation_set = select_active_set
      @can_manage = DocumentationSetPolicy.new(current_user, @project).create?
      # Two SEPARATE contracts, deliberately not merged: @can_manage gates
      # documentation-SET actions (DocumentationSetPolicy#create?), while
      # @can_connect_repo gates the REPOSITORY (ProjectRepositoryPolicy#create?).
      # Before Phase 2 they diverge; even after, they are different rules — the
      # empty-state CTA and the persistent header link use the repo one.
      @can_connect_repo = ProjectRepositoryPolicy.new(current_user, @project).create?
      # Drives whether the "no set" empty state points at repo-connect (no repo
      # yet → that is the real first step) or set-creation. Single existence query.
      @project_has_repository = @project.project_repositories.exists?

      return unless @documentation_set

      load_pages(@documentation_set)
      # Rebuild the result list from ?q= too (not just on :search), so a page opened
      # FROM a result keeps the field + suggestions filled — they survive the click
      # instead of vanishing (mirrors /hilfe).
      load_search_results(@documentation_set)
    end

    # /documentation/search — live Turbo-frame result list for the sidebar search.
    # Read-gated and scoped to a policy-visible set; result links carry q= so the
    # opened page pre-fills the field and the client highlights the hit live.
    def search
      @documentation_set = select_active_set_for_search
      @query = params[:q].to_s.strip
      load_search_results(@documentation_set)
      # Turbo only extracts the frame — skip the app shell on every debounced
      # keystroke; direct visits keep the layout for debuggability.
      render layout: false if turbo_frame_request?
    end

    private

    # Query result list for the sidebar search, shared by :search (live frame) and
    # :index (rebuild on a q-carrying visit). Below the minimum term length the list
    # stays empty (no "no results" noise while typing the first character).
    # Assumes @query is already set (load_pages sets it on :index; :search sets it).
    def load_search_results(set)
      @searched = @query.to_s.length >= MIN_SEARCH_TERM_LENGTH
      @results = if @searched && set
                   set.documentation_pages.present_pages.search_text(@query).ordered.to_a
                 else
                   []
                 end
    end

    # Set the search runs against, restricted to what the user may see. Falls back
    # to the first visible set for a blank/stale set_id (same tolerance as index).
    def select_active_set_for_search
      sets = policy_scope(DocumentationSet.where(project: @project).ordered)
      return sets.first if params[:set_id].blank?

      sets.find { |set| set.id == params[:set_id] } || sets.first
    end

    # Gate the whole area on :documentation read; redirect to the project page
    # with a flash (mirrors KnowledgeController) rather than a bare 403.
    def require_documentation_read
      return if DocumentationPolicy.new(current_user, @project).index?

      flash[:alert] = t('flash.shared.not_authorized')
      redirect_to organisation_project_path(@current_organisation, @project)
    end

    def load_pages(set)
      # @query is NOT used to filter the tree anymore — the sidebar search shows a
      # separate live result list (mirrors /hilfe), so the tree always stays whole.
      # It is still read here to pre-fill the search field on an opened result
      # (?q=…), which the client uses to highlight the body live.
      @query = params[:q].to_s.strip
      @pages = set.documentation_pages.present_pages.ordered.to_a
      @selected_page = select_page(@pages)
      @changed_paths = changed_page_paths(set)
      @navigation = Documentation::Navigation.new(
        @pages, current_page_path: @selected_page&.path, changed_paths: @changed_paths
      ).nodes
      # The tree is unfiltered now, so the only empty case is a set with no pages.
      @empty_variant = :no_pages
      # Newest run explains the failure banner (DT4); loaded here so the view
      # stays query-free.
      @failed_run = set.documentation_sync_runs.recent.first if set.failed?
      track_visit(set)
    end

    # Unknown ids/paths in the URL fall back to the first set/page on purpose:
    # deep links go stale legitimately (page renamed in the repo, set deleted,
    # old bookmark) and should degrade to something useful, never to a 404.
    def select_active_set
      return @sets.first if params[:set_id].blank?

      @sets.find { |set| set.id == params[:set_id] } || @sets.first
    end

    def select_page(pages)
      return pages.first if params[:page].blank?

      pages.find { |page| page.path == params[:page] } || pages.first
    end

    # Paths whose content changed since this user last opened the set (DT5).
    # Computed BEFORE the visit marker is refreshed below.
    def changed_page_paths(set)
      view = set.documentation_set_views.find_by(user: current_user)
      return [] if view.nil?

      set.documentation_pages
         .present_pages
         .where('documentation_pages.updated_at > ?', view.last_viewed_at)
         .pluck(:path)
    end

    def track_visit(set)
      DocumentationSetView.record_visit!(
        documentation_set: set, user: current_user, organisation: @current_organisation
      )
    end
  end
end
