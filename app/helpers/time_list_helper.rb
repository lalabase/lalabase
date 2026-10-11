# frozen_string_literal: true

# The ONE address of the time list, for views, components and the code that
# builds links with no view at all (Lalabase::RouteContext, the citation links).
# Nothing here reads a request or a current user; only the route helpers.
#
# The project's own times page is gone and a project is a filter on this list
# (doc/zeiten_eine_liste_plan.md). Nine hand-built links used to know that
# address, two of them for the same purpose with different parameters.
module TimeListHelper
  # The neutral drill-down params (TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS)
  # stay the caller's job: a filter pill must not neutralise, a total must.
  # `project` is a Project or its id: the citation links carry ids only.
  def time_list_path(organisation, project: nil, **filters)
    filters[:project_id_filter] = project.respond_to?(:id) ? project.id : project if project
    organisation_time_sessions_path(organisation, **filters)
  end

  # Where a subject's booked time lives in that list, by ID for both subject
  # types since S6. Neutralised, because the number next to such a link stands
  # for a total. The hours chip, the time column of the ticket table and the
  # assignment popover all link through here.
  #
  # A meeting used to travel as `search: subject.title`, which is not a filter
  # but a coincidence that usually holds: two meetings with the same title both
  # answered, a renamed meeting stopped answering its own link, and a booking
  # that merely MENTIONS the title in its description answered too. The number
  # beside the link is computed from the meeting id, so the link has to be.
  def subject_time_list_path(subject)
    filter = subject.is_a?(Meeting) ? { meeting_id: subject.id } : { ticket_id: subject.id }
    # Ids, not records: this is built once per row of the ticket table.
    time_list_path(subject.organisation_id, project: subject.project_id, **filter,
                                            **TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS)
  end
end
