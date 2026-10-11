# frozen_string_literal: true

module Dashboard
  # View-model for the cockpit's row layouts (rows_compact / rows_detailed). Produces ONE row per
  # ACTIVE org — including "all quiet" orgs, which CrossOrgActionSummary#slices omits. Pure Ruby over
  # already-loaded data: it projects CrossOrgActionSummary#slices_by_org and PersonalTaskRollup#slices,
  # adding NO queries (both services already ran their per-org passes for the page). Lives here, not
  # in a helper, so it is unit-testable without a request or a tenant.
  #
  # NoTenantSet note (A9): the action slice holds AR records eager-loaded inside each org's tenant.
  # The rows view must only read those eager-loaded associations — this object adds no new reads.
  class CockpitRows
    Row = Struct.new(:organisation, :action_slice, :todos, keyword_init: true) do
      # Has at least one unread notification or shown ticket (and did not error).
      def actions?
        action_slice.present? && !action_slice.error && action_slice.actionable_count.positive?
      end

      # The per-org aggregation FAILED (vs genuinely quiet). The rows view shows a "couldn't load"
      # note for these instead of "all quiet" — keeps the predicate out of the view (no reaching into
      # action_slice.error there) and makes it unit-testable.
      def error?
        action_slice.present? && action_slice.error
      end
    end

    def initialize(organisations:, action_summary:, rollup:)
      @organisations = organisations
      @action_summary = action_summary
      @rollup = rollup
    end

    # One Row per active org, in the given organisation order. Orgs with nothing actionable and no
    # to-dos still get a row — the rows layout shows every org (it doubles as the org switcher).
    def rows
      @rows ||= @organisations.map do |organisation|
        Row.new(
          organisation: organisation,
          action_slice: slices_by_org[organisation.id],
          todos: todos_by_org[organisation.id] || []
        )
      end
    end

    private

    def slices_by_org
      @slices_by_org ||= @action_summary.slices_by_org
    end

    def todos_by_org
      # rollup.slices is [[organisation, tasks], ...] -> { org.id => tasks }.
      @todos_by_org ||= @rollup.slices.to_h.transform_keys(&:id)
    end
  end
end
