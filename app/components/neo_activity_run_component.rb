# frozen_string_literal: true

# One collapsed click cascade in the ticket timeline (designer round
# 05.09.2026): adjacent same-field, same-person activity steps become ONE
# line carrying the net result and the time span, with the single steps in a
# disclosure. The grouping itself lives in TicketTimelineService
# (AGGREGATE_FIELD_FOR_ACTION); the line grammar in TimelineHelper - shared
# with NeoActivityComponent so single rows and steps cannot drift apart.
class NeoActivityRunComponent < ViewComponent::Base
  include ProjectActivityRow

  def initialize(activity_run:, ticket: nil, current_user: nil, show_actor: false, project: nil)
    super()
    @activity_run = activity_run
    @ticket = ticket
    @current_user = current_user
    @show_actor = show_actor
    @project = project
  end

  private

  attr_reader :activity_run, :ticket, :current_user

  def net_line
    helpers.timeline_run_line(activity_run, project_ticket || ticket)
  end

  def actor_suffix
    return unless @show_actor

    helpers.viewer_display_name(activity_run.actor)
  end

  def time_range
    helpers.timeline_row_clock_range(activity_run)
  end

  def steps_label
    t('views.organisations.tickets.timeline.steps', count: activity_run.size)
  end

  # Net pairs the line could not show (a long title), first old value to last
  # new one. They stand above the steps (TimelineHelper#timeline_run_details).
  def net_details
    @net_details ||= helpers.timeline_run_details(activity_run, project_ticket || ticket)
  end

  # Already ordered like the timeline around it - the service flips the
  # array for a newest-first list.
  def steps
    activity_run.activities
  end

  def representative_activity = activity_run.newest
end
