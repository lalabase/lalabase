# frozen_string_literal: true

# Organisation-wide meetings index (Gespräche Slice 1c): "all conversations with
# person X" across project boundaries, and the DSGVO lookup tool (find every
# meeting a person took part in). A slim, index-only controller — deliberately
# NOT the project-nested Organisations::MeetingsController, which is bound to
# @project via ProjectController.
#
# Since 05.09.2026 the page also CREATES: the title box carries a "+" that opens a
# modal with a project select, and the modal's turbo-frame loads the real form from
# the project-nested MeetingsController (frame: 'modal'). This controller therefore
# only decides WHETHER to offer the button and WHICH projects it may offer — the
# write itself never happens here.
#
# Security rests entirely on MeetingPolicy::Scope (accessible_project_ids for the
# :meetings area, within the tenant — never without_tenant): the list, both
# filters and the filter OPTIONS all derive from policy_scope(Meeting), so a
# meeting or participant name from a project the user cannot read can never
# surface. verify_policy_scoped (BaseController, index-only) enforces that the
# scope is actually applied. A user with no :meetings read access anywhere is
# redirected before the action runs.
module Organisations
  class MeetingsOverviewController < Organisations::BaseController
    before_action :require_meetings_access

    def index
      @meetings = filtered_meetings
      # The claim hint (Nachtrag) is rendered lazily via the meeting_claim_matches
      # helper (shared with the project index) — nothing to set up here.
    end

    private

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

    def accessible_meeting_project_ids
      @accessible_meeting_project_ids ||= AccessCheck::ProjectAccessService.accessible_project_ids(
        current_user, @current_organisation, action: :read, area: :meetings
      )
    end

    # The list query lives in Meetings::OverviewList — the same object refreshes
    # this frame after a save from the modal (MeetingsController#create), so the
    # two paths cannot drift apart.
    def overview_list
      @overview_list ||= Meetings::OverviewList.from_params(scope: policy_scope(Meeting), params: params)
    end

    def filtered_meetings
      overview_list.fetch_results
    end

    def filters_active?
      overview_list.filters_active?
    end
    helper_method :filters_active?

    # What the modal's option URLs must carry: the filters as the LIST applies them,
    # not the raw params. Reading params there let the two disagree, and a nested
    # value (?project_id[a]=1) made the route helper raise on a page anyone can call.
    def overview_filter_params
      overview_list.active_filters
    end
    helper_method :overview_filter_params

    # Filter dropdown options, both derived from the readable meeting set so no
    # name/project from an unreadable project appears.
    def participant_filter_options
      MeetingParticipant.distinct_names_for_meetings(policy_scope(Meeting))
    end
    helper_method :participant_filter_options

    def project_filter_options
      Project.where(id: accessible_meeting_project_ids).order(:name).pluck(:name, :id)
    end
    helper_method :project_filter_options

    # The projects the "+" may offer: where this person may WRITE meetings. Read
    # access is not enough — the modal's form would be refused by the area gate in
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
