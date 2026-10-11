# frozen_string_literal: true

# Compact list-row representation of a Notification, used in the Inbox
# master list (see doc/inbox_feature_spec.md chapter 4.1).
#
# DELIBERATELY NOT a clone of NeoNotificationCardComponent — the card component
# renders a full-width card look (briefing lane, dropdown). The
# inbox master needs a compact list look (~60px height). The
# data source is shared (Notification model + Notifications::Constants),
# only the display markup differs.
class NeoInboxMasterItemComponent < ViewComponent::Base
  include Notifications::Constants

  def initialize(notification:, selected: false, group_count: 1, group_unread: nil, query_context: nil)
    @notification = notification
    @selected = selected
    # Bundle counts (grouped view): how many notifications belong to the
    # same ticket, of which unread. group_unread: nil → single mode
    # (chronological), unread state then comes from the individual notification.
    @group_count = group_count
    @group_unread = group_unread
    # Optional: explicit query params for link_url. Needed on turbo_stream
    # re-renders, because request.query_parameters there mirrors the action
    # URL (e.g. ?items=20 instead of the master filter).
    @query_context = query_context
  end

  def render?
    @notification.present?
  end

  private

  attr_reader :notification, :selected, :group_count

  def activity_line
    @activity_line ||= Inbox::ActivityLine.new(notification)
  end

  # Bundle badge "N updates" only makes sense from 2 notifications for the ticket.
  def show_group_badge?
    group_count.to_i > 1
  end

  # In bundled mode the row counts as unread as soon as ANY
  # of its notifications is unread (group_unread). In single mode
  # (group_unread nil) the state of the individual notification counts.
  def unread?
    return false if archived?

    if @group_unread.nil?
      !notification.state_read?
    else
      @group_unread.to_i.positive?
    end
  end

  def archived?
    notification.respond_to?(:state_archived?) && notification.state_archived?
  end

  def actor_name
    activity_line.actor_name
  end

  def time_ago
    activity_line.time_ago
  end

  def event_label
    activity_line.label
  end

  def notifiable_title
    notifiable = notification.notifiable
    return nil unless notifiable

    notifiable.try(:title).presence ||
      notifiable.try(:name).presence ||
      notifiable.try(:subject).presence
  end

  def project_name
    notification.project&.name
  end

  # If the notifiable is a ticket → open the inbox pane (same URL, just
  # with ?notification=:id, click loads the pane via Turbo frame).
  # Otherwise → deep link as before (full view).
  def link_url
    if notification.notifiable.is_a?(Ticket)
      base = @query_context.presence || helpers.request.query_parameters
      current = base.to_h.with_indifferent_access.except(:notification, :items)
      current[:notification] = notification.id
      "#{helpers.organisation_notifications_path(helpers.current_organisation)}?#{current.to_query}"
    else
      helpers.notification_deeplink_path(notification, source: 'inbox')
    end
  end

  # On mobile (no pane visible) the Stimulus controller navigates
  # to the full view instead — for that it needs the direct ticket URL.
  def fullview_url
    helpers.notification_deeplink_path(notification, source: 'inbox')
  end

  # On desktop (lg+): load the pane. On mobile (< lg): full view (the pane
  # is not visible). Tailwind cannot toggle this directly, so on desktop we
  # provide data-turbo-frame, and Stimulus overrides it on mobile in a
  # follow-up commit if needed. V1: a frame click falls back to
  # _top when the frame does not exist (mobile).
  #
  # turbo-action="advance" provides URL sync: after the frame loads the
  # browser URL is pushed to the link's href → back, reload, share
  # work. See doc/inbox_feature_spec.md chapter 4.8.
  def link_data
    if notification.notifiable.is_a?(Ticket)
      # NO turbo_action: 'advance' — that promotes the frame load to a
      # drive visit, which right after loading overwrites the freshly filled pane
      # with the placeholder (visible flicker). URL sync is instead done
      # by the Stimulus controller via history.pushState.
      {
        turbo_frame: 'ticket_pane',
        controller: 'inbox-master-item',
        action: 'click->inbox-master-item#handleClick',
        inbox_master_item_fullview_url_value: fullview_url
      }
    else
      { turbo_frame: '_top' }
    end
  end

  def row_classes
    base = 'block px-4 py-3 border-b border-cream-200 transition-colors relative'
    # Selected: value step + ink stroke (Part G/G4: ink = "here/focal", lime stays reserved for actions).
    return "#{base} bg-cream-200 border-l-4 border-l-ink" if selected

    # Hover = +1 step darker than the resting surface of the row (Part G/G3 "value step instead of hue",
    # no new hue → nav/list recedes).
    state, hover =
      if archived?
        # Archived: most strongly muted (warm), italic + left accent as anchor.
        ['bg-cream-100 border-l-4 border-l-cream-400 opacity-70 italic', 'hover:bg-cream-200']
      elsif unread?
        # Unread: surface tone (cream-50) → brightest/"freshest" row; marked via the red unread dot + bold.
        ['bg-transparent', 'hover:bg-cream-100']
      else
        # Read: slightly muted/receding (Gmail convention "read = grayer"), warm.
        ['bg-cream-100', 'hover:bg-cream-200']
      end
    [base, state, hover].join(' ')
  end

  def primary_text_class
    return 'text-cream-500' if archived?

    unread? ? 'text-cream-900' : 'text-cream-600'
  end

  def secondary_text_class
    return 'text-cream-400' if archived?

    unread? ? 'text-cream-700' : 'text-cream-500'
  end
end
