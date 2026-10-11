# frozen_string_literal: true

class NeoActivityComponent < ViewComponent::Base
  include ActionView::Helpers::DateHelper
  include ProjectActivityRow

  # T4: quiet side note, no icon circle any more. Since the designer round
  # 05.09.2026 the line speaks field-first ("Priorität Niedrig → Normal",
  # TimelineHelper#timeline_change_line): display values instead of raw keys,
  # no ticket title (it stands in the head), and the actor only when the
  # person switches - the list computes that and passes show_actor.
  def initialize(activity:, ticket: nil, current_user: nil, show_actor: false, project: nil)
    @activity = activity
    @ticket = ticket
    @current_user = current_user
    @show_actor = show_actor
    @project = project
  end

  def cache_key_with_version
    [
      'neo_activity',
      'v5',
      @activity.cache_key_with_version
    ].join('/')
  end

  private

  attr_reader :activity, :current_user

  def activity_line
    helpers.timeline_change_line(activity, project_ticket || ticket)
  end

  def ticket
    @ticket || (activity.trackable if activity.trackable.is_a?(Ticket))
  end

  def actor_suffix
    return unless @show_actor

    helpers.viewer_display_name(activity.actor)
  end

  # Same seam as the post row - the day header owns the date (TimelineHelper).
  # A change row carries the exact clock time, not an age: mono is for values
  # (user mockup 05.09.2026).
  def row_time
    helpers.timeline_row_clock(activity)
  end

  # The disclosure holds exactly what the line could not show: several fields
  # at once, one pair too long for the line, or the list of a bulk run that
  # did not fit after its count (a TimelineHelper::Note). The helper decides
  # both from the same material (TimelineHelper#timeline_change_details), so
  # nothing is in the line AND below it - until 10.09.2026 a long summary
  # stood in both.
  def change_details
    @change_details ||= helpers.timeline_change_details(activity, project_ticket || ticket)
  end

  def show_details?
    change_details.any?
  end

  def base_classes
    'activity-card'
  end

  # One field that left the line: "Unterschied ansehen". Several fields in one
  # save, or the list of a bulk run: "Details anzeigen".
  def details_label
    single_pair = change_details.one? && change_details.first.is_a?(TimelineHelper::Change)
    return t('components.activity_timeline.template.show_diff') if single_pair

    t('views.organisations.tickets.timeline.show_details')
  end

  def representative_activity = activity
end
