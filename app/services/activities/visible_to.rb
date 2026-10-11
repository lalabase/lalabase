# frozen_string_literal: true

# The activity rows one person may see, across one project or the whole
# organisation (assistant plan §9a Befund 1, §13-11).
#
# Entry point: call
#
# Activities have NO project_id: the row points at a trackable, and the project
# has to be derived from it. That is why the existing project feed builds an
# eight-way UNION by hand. Here the same knowledge lives in one place and is
# driven by Activities::AreaRegistry, so the gate and the feed cannot drift.
#
# Two families, because only two trackable types actually carry project-bound
# events (measured, not assumed):
#
#   Ticket rows   -> the ticket's project (subquery over tickets)
#   Project rows  -> trackable_id IS the project id
#
# Fail-closed on every axis: an unmapped key yields no clause, an area with no
# reachable projects yields no clause, and no clauses at all yields Activity.none
# rather than an unfiltered relation.
module Activities
  class VisibleTo
    # `reach` answers `project_ids(area:)` -- the same interface
    # Lalabase::Tools::Scope offers, so the assistant hands its scope straight in
    # and only the single-project page needs a two-line adapter.
    #
    # A caller that needs the ROWS only stays here. One that also needs to say how
    # far the answer reached builds the object (`.new(...)`) and asks
    # #reached_project_ids afterwards.
    def self.call(organisation:, reach:, since: nil, limit: nil)
      new(organisation: organisation, reach: reach, since: since, limit: limit).call
    end

    def initialize(organisation:, reach:, since: nil, limit: nil)
      @organisation = organisation
      @reach = reach
      @since = since
      @limit = limit
    end

    def call
      clauses = area_clauses
      return Activity.none if clauses.empty?

      relation = base.merge(clauses.reduce(:or))
      relation = relation.limit(@limit) if @limit
      relation
    end

    # Every project this feed can produce a row from: everywhere the reader may
    # read ANY area. Two jobs, and they coincide for one reason -- every area a
    # mapped key points at is one of these, so their union IS this set:
    #   * the gate of a PROJECT_LEVEL row (see #project_ids_for), and
    #   * the honest denominator for a caller's L7 coverage sentence.
    #
    # ⚠️ The second job is why this is public. A caller must NOT take its
    # coverage from a single area: the feed spans them all, and
    # `coverage(area: :tickets)` reported the reach of ONE area for an answer
    # drawn from eight. Measured: a reader with notes-only rights got an answer
    # out of three projects under the sentence "Durchsucht: 0 von 3 Projekten"
    # -- a sentence that means "your rights stopped here" (Tools::Scope), said
    # in the wrong direction.
    #
    # Reachable through `.new(...)` rather than through `.call`, which returns
    # the relation: the caller that needs both asks the same object twice, and
    # the second question is free because #call already asked this one as the
    # PROJECT_LEVEL gate.
    def reached_project_ids
      @reached_project_ids ||= ProjectPermission.access_areas
                                                .flat_map { |area| @reach.project_ids(area: area) }
                                                .uniq
    end

    private

    def base
      relation = Activity.feed.where(organisation_id: @organisation.id).recent
      relation = relation.where(created_at: @since..) if @since
      relation
    end

    # One clause per area, not one per key: six areas beat twenty keys, and the
    # ids behind each area are looked up once.
    def area_clauses
      AreaRegistry.keys_by_area.filter_map do |area, keys|
        ids = project_ids_for(area)
        next if ids.empty?

        clause_for(keys, ids)
      end
    end

    def clause_for(keys, project_ids)
      ticket_keys, project_keys = keys.partition { |key| key.start_with?('ticket.') }

      parts = []
      parts << ticket_clause(ticket_keys, project_ids) if ticket_keys.any?
      parts << project_clause(project_keys, project_ids) if project_keys.any?
      parts.reduce(:or)
    end

    # The only join in here, and it stays a subquery: `trackable` is polymorphic,
    # so there is no association to join through, and a subquery keeps the OR
    # chain structurally compatible (ActiveRecord refuses `.or` across relations
    # with different joins).
    def ticket_clause(keys, project_ids)
      Activity.where(trackable_type: 'Ticket', key: keys,
                     trackable_id: Ticket.where(project_id: project_ids).select(:id))
    end

    def project_clause(keys, project_ids)
      Activity.where(trackable_type: 'Project', key: keys, trackable_id: project_ids)
    end

    # PROJECT_LEVEL means "may see the project at all", which is what having read
    # on ANY area amounts to. Asked of the areas that exist rather than of a
    # `:project` area -- there is none, and accessible_project_ids raises on a
    # name it does not know.
    def project_ids_for(area)
      return reached_project_ids if area == AreaRegistry::PROJECT_LEVEL

      @reach.project_ids(area: area)
    end
  end
end
