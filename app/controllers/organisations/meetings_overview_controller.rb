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
# here: the condition "Projekt" and the column "Projekt". Since PR 3 a row opens
# the meeting in the lane beside the list, and ?meeting_id= opens it on a full
# visit. The detail and every write in it stay project-nested
# (MeetingsController, list_context=organisation); this controller only renders
# the selected meeting on a full visit.
#
# The title box carries a "+" that opens a project select in the lane, as the
# project page's "+" opens its form there (PR 4): ?new=meeting on this page's
# own address, for a full visit and for the lane frame alike, so there is no
# meeting route without a project. The frame below the select loads the real
# form from the project-nested MeetingsController (frame: 'content'). This
# controller only decides WHETHER to offer the select and WHICH projects it
# may offer; the write never happens here. Until PR 4 the select stood in a
# modal.
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
    # The frame below the project select in the lane: the chosen project's form
    # loads into it, and a refused save answers into it, so the select keeps
    # its project (meetings_overview/_new_meeting_lane).
    NEW_FORM_FRAME_ID = 'meeting_new_form'

    # The addresses of the page before the filter bar, still in bookmarks and
    # links from elsewhere: ?participant= and ?project_id= become the bar's
    # conditions (old name => condition).
    LEGACY_FILTER_PARAMS = { 'participant' => 'participant', 'project_id' => 'project' }.freeze

    before_action :require_meetings_access
    before_action :redirect_legacy_filters, only: :index
    before_action :set_viewport_mode, only: :index

    def index
      return render_lane_frame if lane_frame_request?

      @meetings = filtered_meetings
      if turbo_frame_request?
        render_list_frame
        return
      end

      @selected_meeting = find_selected_meeting
      @new_meeting_lane = @selected_meeting.nil? && new_meeting_requested?
      MeetingTicketSuggestionRun.recover_for_meeting!(@selected_meeting)
      # The claim hint (Nachtrag) is rendered lazily via the meeting_claim_matches
      # helper (shared with the project index), nothing to set up here.
    end

    private

    # The bar's two frames: the list, and the sentence of its chips.
    def render_list_frame
      case request.headers['Turbo-Frame']
      when LIST_FRAME_ID
        render partial: 'organisations/meetings_overview/results', locals: { meetings: @meetings }
      when "#{LIST_FRAME_ID}_sentence"
        render partial: 'organisations/meetings_overview/list_head'
      end
    end

    # The lane asks this address for its content: the "+" (lane-link) for the
    # project select, and a redirect for whatever it leads back to. A lane
    # action MeetingsController refuses or cannot finish redirects to this page
    # (Pundit to the Referer, a vanished meeting to the list), and fetch keeps
    # the Turbo-Frame header on the redirected request.
    def lane_frame_request?
      turbo_frame_request? && request.headers['Turbo-Frame'] == MeetingsController::DETAIL_FRAME_ID
    end

    # The lane alone, as a full visit of the same address shows it: the meeting
    # of meeting_id, else the project select of ?new=meeting, else the empty
    # lane. The scope is skipped only for a request that names no meeting, so
    # verify_policy_scoped still bites where one is read.
    #
    # Every refusal answers INSIDE the frame (as TimeSessionGroupsController#entries
    # does), never through the shared one: that redirects back to this page, the
    # redirected request keeps the header and lands here again, and a right taken
    # away while the page stays open ended in "too many redirects". For the same
    # reason the meeting is asked with policy(...).show?, not authorize.
    def render_lane_frame
      partial, locals, status = lane_frame_content(lane_frame_meeting)
      skip_policy_scope unless selected_meeting_id

      render html: helpers.turbo_frame_tag(MeetingsController::DETAIL_FRAME_ID) {
        helpers.render(partial: partial, locals: locals)
      }, layout: false, status: status
    end

    def lane_frame_content(meeting)
      if meeting
        MeetingTicketSuggestionRun.recover_for_meeting!(meeting)
        ['organisations/meetings/display_meeting', { selected_meeting: meeting }, :ok]
      elsif params[:new] != 'meeting'
        ['organisations/meetings/display_meeting', { selected_meeting: nil }, :ok]
      elsif new_meeting_requested?
        ['organisations/meetings_overview/new_meeting_lane', { projects: writable_meeting_projects }, :ok]
      else
        ['organisations/meetings_overview/new_meeting_denied', {}, :forbidden]
      end
    end

    def lane_frame_meeting
      meeting = scoped_selected_meeting
      meeting if meeting && policy(meeting).show?
    end

    # ?new=meeting, from someone who may write meetings somewhere. Otherwise the
    # page is the list without a lane, and layout-toggle takes new out of the
    # address (meeting_unresolved_lane_params).
    def new_meeting_requested?
      params[:new] == 'meeting' && can_create_meeting?
    end

    # The meeting a full visit opens in the lane: through policy_scope(Meeting)
    # only, so an id of an unreadable project or another organisation is no
    # meeting at all, and nothing of it is rendered, not even its title. The
    # full row, not the list's narrow select (the detail renders notes and
    # transcript). @project stays unset: the lane names meeting.project itself,
    # and the list here belongs to no project (MeetingList).
    def find_selected_meeting
      meeting = scoped_selected_meeting
      authorize(meeting, :show?) if meeting
      meeting
    end

    def scoped_selected_meeting
      policy_scope(Meeting).find_by(id: selected_meeting_id) if selected_meeting_id
    end

    def selected_meeting_id
      meeting_id = params[:meeting_id]
      meeting_id if meeting_id.is_a?(String) && meeting_id.present?
    end

    # MeetingList: this list belongs to no project.
    def meeting_list_project
      nil
    end

    # Nav gate + direct-URL guard: without :meetings read access in ANY project
    # the page has nothing to show, so redirect instead of rendering an empty
    # shell. Mirrors the "Zeiten" menu visibility, but a single .any? check
    # does not warrant its own service (accessible_project_ids already covers
    # admin/global-role/per-project).
    #
    # A frame of this page (the lane, the list, the sentence of the bar) asks
    # when the last right went while the page stayed open. The start page has
    # none of these frames, and Turbo threw on it ("Content missing"). Instead
    # it is told to visit the same address in full (turbo-visit-control
    # reload), and that visit takes the redirect below. The hint goes out with
    # 200: Turbo reloads only for a successful answer and renders any other one
    # as the page itself, here an empty one.
    def require_meetings_access
      return if accessible_meeting_project_ids.any?
      return render_full_visit if turbo_frame_request?

      redirect_to organisation_root_path(organisation_id: @current_organisation.id),
                  alert: t('shared.errors.not_authorized')
    end

    def render_full_visit
      render html: helpers.tag.meta(name: 'turbo-visit-control', content: 'reload'), layout: false
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

    # The projects the "+" may offer: where this person may WRITE meetings. Read
    # access is not enough: the select's form would be refused by the area gate in
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
