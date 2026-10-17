# frozen_string_literal: true

# Organisation-wide meetings index ("Alle Meetings", Gespräche Slice 1c): "all
# conversations with person X" across project boundaries, and the DSGVO lookup
# tool (find every meeting a person took part in). Deliberately NOT the
# project-nested Organisations::MeetingsController, which is bound to @project
# via ProjectController.
#
# Since 17.10.2026 the list is the project page's list
# (doc/meetings_uebersicht_vereinheitlichen_plan.md, PR 1): the shared filter
# bar with saved views, conditions and the search depth, sort by column head,
# pagination, all through MeetingList with no project. Two things exist only
# here: the condition "Projekt" and the column "Projekt". A row still opens the
# meeting on its project's page; the detail in a lane of its own comes with PR 3.
#
# The title box carries a "+" that opens a modal with a project select, and the
# modal's turbo-frame loads the real form from the project-nested
# MeetingsController (frame: 'modal'). This controller only decides WHETHER to
# offer the button and WHICH projects it may offer; the write never happens here.
#
# Security rests entirely on MeetingPolicy::Scope (accessible_project_ids for the
# :meetings area, within the tenant, never without_tenant): the list, every
# condition and every option of the bar derive from policy_scope(Meeting), and a
# condition only narrows it. verify_policy_scoped (BaseController, index-only)
# enforces that the scope is applied. A user with no :meetings read access
# anywhere is redirected before the action runs.
module Organisations
  class MeetingsOverviewController < Organisations::BaseController
    include ViewportSwitchable
    include AdHocFilterable
    include Pageable
    include MeetingList

    LIST_FRAME_ID = MeetingsController::OVERVIEW_LIST_FRAME_ID

    # The addresses of the page before the filter bar, still in bookmarks and
    # links from elsewhere: ?participant= and ?project_id= become the bar's
    # conditions (old name => condition).
    LEGACY_FILTER_PARAMS = { 'participant' => 'participant', 'project_id' => 'project' }.freeze

    before_action :require_meetings_access
    before_action :redirect_legacy_filters, only: :index
    before_action :set_viewport_mode, only: :index

    def index
      @meetings = filtered_meetings
      return unless turbo_frame_request?

      case request.headers['Turbo-Frame']
      when LIST_FRAME_ID
        render partial: 'organisations/meetings_overview/results', locals: { meetings: @meetings }
      when "#{LIST_FRAME_ID}_sentence"
        render partial: 'organisations/meetings_overview/list_head'
      end
      # The claim hint (Nachtrag) is rendered lazily via the meeting_claim_matches
      # helper (shared with the project index), nothing to set up here.
    end

    private

    # MeetingList: this list belongs to no project.
    def meeting_list_project
      nil
    end

    # Nav gate + direct-URL guard: without :meetings read access in ANY project
    # the page has nothing to show, so redirect instead of rendering an empty
    # shell. Mirrors the "Zeiten" menu visibility, but a single .any? check
    # does not warrant its own service (accessible_project_ids already covers
    # admin/global-role/per-project).
    def require_meetings_access
      return if accessible_meeting_project_ids.any?

      redirect_to organisation_root_path(organisation_id: @current_organisation.id),
                  alert: t('shared.errors.not_authorized')
    end

    # One redirect to the address the bar writes, so the chips show the old
    # filter and every later change carries it as a condition. A value that is
    # not a single string was no filter before either and is dropped.
    def redirect_legacy_filters
      query = request.query_parameters
      return if (LEGACY_FILTER_PARAMS.keys & query.keys).empty?

      filters = query['filter'].is_a?(Hash) ? query['filter'].dup : {}
      LEGACY_FILTER_PARAMS.each do |old, condition|
        value = query[old]
        filters[condition] ||= [value] if value.is_a?(String) && value.present?
      end
      kept = query.except(*LEGACY_FILTER_PARAMS.keys, 'filter')
      redirect_to organisation_meetings_path(@current_organisation, filters.empty? ? kept : kept.merge('filter' => filters))
    end

    def accessible_meeting_project_ids
      @accessible_meeting_project_ids ||= AccessCheck::ProjectAccessService.accessible_project_ids(
        current_user, @current_organisation, action: :read, area: :meetings
      )
    end

    # The options of the condition "Projekt": the projects whose meetings this
    # reader may read, nothing else.
    def meeting_filter_projects
      Project.where(id: accessible_meeting_project_ids).order(:name)
    end
    helper_method :meeting_filter_projects

    # No readable meeting anywhere yet: the list shows its first-time state. The
    # filter bar stands anyway (_list_head explains why).
    def meetings_overview_first_use?
      return @meetings_overview_first_use if defined?(@meetings_overview_first_use)

      @meetings_overview_first_use = !policy_scope(Meeting).exists?
    end
    helper_method :meetings_overview_first_use?

    # The projects the "+" may offer: where this person may WRITE meetings. Read
    # access is not enough: the modal's form would be refused by the area gate in
    # MeetingsController, and a button that leads to an error message is a promise
    # without cover (same rule as the Zeiten title box). The reach itself comes from
    # the single owner in AccessCheck::ProjectAccessService, not a second copy here.
    def writable_meeting_projects
      # Loaded, not left lazy: can_create_meeting? asks it and the <option> loop
      # iterates it, which on a relation is two round trips for one answer.
      @writable_meeting_projects ||= Project.where(
        id: AccessCheck::ProjectAccessService.writable_meetings_project_ids(current_user, @current_organisation)
      ).order(:name).to_a
    end
    helper_method :writable_meeting_projects

    def can_create_meeting?
      return @can_create_meeting if defined?(@can_create_meeting)

      @can_create_meeting = writable_meeting_projects.any?
    end
    helper_method :can_create_meeting?
  end
end
