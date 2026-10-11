# frozen_string_literal: true

class NeoTimeSessionComponent < ViewComponent::Base
  include ActionView::Helpers::DateHelper

  # variant :quiet (T4) renders the one-line margin note for the ticket
  # timeline; :default keeps the card for the assistant report panel.
  def initialize(time_session:, current_user: nil, show_actions: true, project: nil, ticket: nil, variant: :default)
    @time_session = time_session
    @current_user = current_user
    @show_actions = show_actions
    @project = project
    @ticket = ticket
    @variant = variant
  end

  def cache_key_with_version
    [
      'neo_time_session',
      'v4',
      @variant,
      @time_session.cache_key_with_version,
      @current_user&.id,
      @show_actions ? 'actions' : 'noactions'
    ].join('/')
  end

  private

  attr_reader :time_session, :current_user, :project, :ticket

  def formatted_duration
    if time_session.respond_to?(:duration_string)
      time_session.duration_string
    else
      hours = time_session.duration_hours
      minutes = time_session.duration_minutes || 0

      if hours > 0 && minutes > 0
        "#{hours}:#{minutes.to_s.rjust(2, '0')}h"
      elsif hours > 0
        "#{hours}:00h"
      else
        "#{minutes}min"
      end
    end
  end

  def author_name
    author = time_session.respond_to?(:creator) ? time_session.creator : time_session.user
    helpers.viewer_display_name(author)
  end

  # "1:33", "0:15" - hours without a leading zero, like the header total. The
  # clock icon in the kind column already says what this number is, so it
  # carries no unit and no word. One spelling for compared durations:
  # TimeSessionsHelper#time_clock_label owns the formula.
  def compact_duration
    helpers.time_clock_label(time_session.duration)
  end

  def formatted_date
    if time_session.respond_to?(:occurred_on)
      I18n.l(time_session.occurred_on.to_date, format: :long)
    else
      time_session.created_at.strftime('%d. %B %Y, %H:%M')
    end
  end

  def description_present?
    time_session.description.present?
  end

  def description_text
    time_session.description
  end

  def can_edit?
    return false unless current_user && @show_actions

    # Check if TimeSession is billed first
    return false if time_session.respond_to?(:billed?) && time_session.billed?

    # Use Pundit policy if available - delegate policy check to view context
    # Since ViewComponents don't have access to policy helpers by default
    true # For now, let the template handle the policy check
  end

  def dom_id_for_time_session
    ActionView::RecordIdentifier.dom_id(time_session)
  end

  def time_session_data_attributes
    {
      time_session_id: time_session.id,
      context: ticket.present? ? 'ticket' : 'index_page',
      ticket_id: ticket&.id || time_session.ticket_id,
      project_id: project&.id || time_session.project_id
    }
  end

  def quiet?
    @variant == :quiet
  end

  # The quiet row's one pencil: opens the capture popover at the hours sum in
  # edit mode. Shown only when the popover itself would let this reader rework
  # the row (subject_popover_row_editable? — open time, creator or admin).
  def popover_subject
    ticket || time_session.ticket
  end

  def popover_pencil?
    return false unless can_edit? && popover_subject && current_user

    helpers.subject_popover_row_editable?(time_session)
  end

  def popover_edit_href
    helpers.subject_popover_path_for(popover_subject, edit: time_session.id)
  end

  def popover_frame_dom_id
    "subject_time_popover_#{popover_subject.id}"
  end

  # The quiet timeline row asks the timeline seam (TimelineHelper), which
  # returns nothing for a day-only record. The card branch below keeps
  # formatted_date: the assistant report panel is not a day-grouped list, so
  # there is no header above it to carry the date.
  def row_time
    helpers.timeline_row_clock(time_session)
  end

  def base_classes
    return 'time-session-card' if quiet?

    # Hybrid: card border matches the card color — cobalt-300 (slightly darker).
    # Cobalt-50 as a semantic marker "time tracking".
    [
      'time-session-card bg-cobalt-50 py-6 px-5 lg:px-8 mb-4 rounded-lg',
      'border border-cobalt-300 shadow-sm relative group'
    ].join(' ')
  end

  def time_session_id
    time_session.id
  end
end
