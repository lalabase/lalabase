# frozen_string_literal: true

# The org-wide meetings list (Gespräche Slice 1c): search, participant filter,
# project filter and ordering over an ALREADY policy-scoped relation.
#
# One owner, because two controllers need the very same list: MeetingsOverviewController
# renders it, and MeetingsController#create refreshes it after a save from the overview
# modal. The Pundit scope stays with the caller — this object never widens what it is
# handed, it only narrows.
#
# Entry point: fetch_results
module Meetings
  class OverviewList
    # The list renders only these columns; loading full rows would de-TOAST
    # notes/transcript/plain_text_version (up to ~1 MB each) for every meeting.
    # project_id feeds includes(:project) + the row link, id the participant chips.
    # Pinned by a spec: dropping the select has no symptom except a slow page.
    LIST_COLUMNS = %i[id project_id organisation_id title occurred_at].freeze

    # The request parameter each filter travels under. The project filter has two
    # possible names and that is the whole reason this builder exists: on the
    # overview it is `project_id`, but the save comes through the project-NESTED
    # route, where `project_id` is the route's own parameter and would collide, so
    # it travels as `overview_project_id` there. Written down once, read by both
    # controllers.
    DEFAULT_PROJECT_ID_KEY = :project_id
    NESTED_PROJECT_ID_KEY = :overview_project_id

    # Builds the list straight from a controller's params, so a new filter is added
    # in ONE place instead of in every controller that renders this list.
    def self.from_params(scope:, params:, project_id_key: DEFAULT_PROJECT_ID_KEY)
      new(scope: scope,
          search: params[:search],
          participant: params[:participant],
          project_id: params[project_id_key])
    end

    # Every filter is reduced to a scalar HERE, once, so nothing downstream has to
    # remember to do it. A request parameter can be a Hash or an Array
    # (?project_id[a]=1), and that shape has two ways to hurt: `where` reads it as a
    # condition on a table named project_id, and a route helper refuses to build an
    # address from unpermitted parameters (a 500 on the overview page). A non-scalar
    # is not a filter, so it becomes nil.
    def initialize(scope:, search: nil, participant: nil, project_id: nil)
      @scope = scope
      @search = scalar(search)
      @participant = scalar(participant)
      @project_id = scalar(project_id)
    end

    def fetch_results
      scope
        .search_by_content(search)
        .with_participant(participant) # subquery, no row dup
        .where(project_filter)
        # created_at breaks ties: occurred_at comes from a minute-resolution form
        # field, so two meetings entered back to back share it, and without a
        # second key Postgres may put the older one first — which would make the
        # modal's promise ("the new one is at the top") false at random.
        .order(occurred_at: :desc, created_at: :desc)
        .select(*LIST_COLUMNS)
        .includes(:project, :meeting_participants) # project name + chips per row, no N+1 (D10)
    end

    # Distinguishes the two empty states without an extra COUNT: with no filter
    # active an empty result means "no meetings yet", with one it means "the filter
    # matched nothing" (and the empty state offers a reset).
    def filters_active?
      active_filters.any?
    end

    # The filters as this list actually applies them, ready to be put into a URL.
    # The modal's option URLs must carry exactly these: reading raw params there
    # would let the two disagree, and a non-scalar would break the route helper.
    def active_filters
      { search: search, participant: participant, project_id: project_id }.compact_blank
    end

    private

    attr_reader :scope, :search, :participant, :project_id

    # A forged or unreadable project_id cannot leak: this only narrows the already
    # policy-scoped relation, so an id outside the readable set matches nothing.
    def project_filter
      project_id.present? ? { project_id: project_id } : {}
    end

    # A filter value is a scalar or it is not a filter. ActionController::Parameters
    # and Hash/Array answer to neither #to_str nor Numeric/Symbol, so they fall out
    # here instead of reaching a query or a route helper.
    def scalar(value)
      return nil if value.blank?
      return nil unless value.respond_to?(:to_str) || value.is_a?(Numeric) || value.is_a?(Symbol)

      value.to_s
    end
  end
end
