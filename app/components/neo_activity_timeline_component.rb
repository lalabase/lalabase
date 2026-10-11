# frozen_string_literal: true

# Project activity timeline frame. Individual rows deliberately come from the
# same components as the ticket history; this component owns only grouping,
# day separators and the extra project context passed to those rows.
class NeoActivityTimelineComponent < ViewComponent::Base
  def initialize(activities:, project: nil)
    @activities = Array(activities).compact
    @project = project
  end

  private

  attr_reader :activities, :project

  def grouped_items
    timeline_items.group_by { |item| item.created_at.to_date }
  end

  def timeline_items
    @timeline_items ||= Activities::RunCollapser.for_project(activities)
  end

  def formatted_date(date)
    I18n.l(date, format: '%d.%m.%Y')
  end

  def activity_count(items)
    items.sum { |item| item.is_a?(Activities::RunCollapser::ActivityRun) ? item.size : 1 }
  end

  def ticket_for(item)
    activity = item.is_a?(Activities::RunCollapser::ActivityRun) ? item.newest : item
    return activity.trackable if activity.trackable.is_a?(Ticket)
    return activity.secondary if activity.secondary.is_a?(Ticket)

    nil
  end
end
