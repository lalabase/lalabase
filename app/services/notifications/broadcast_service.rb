# frozen_string_literal: true

# Service for broadcasting notification updates via Turbo Streams.
#
# PURPOSE:
# Separates broadcasting logic from the model and makes side effects explicit.
# Enables better testability and clearer responsibilities.
#
# USAGE:
# # After notification creation:
# Notifications::BroadcastService.new(notification).broadcast_creation
#
# # After notification update:
# Notifications::BroadcastService.new(notification).broadcast_update

require 'action_view/record_identifier'

class Notifications::BroadcastService
  include ActionView::RecordIdentifier

  def initialize(notification, precomputed_unread_count: nil)
    @notification = notification
    @precomputed_unread_count = precomputed_unread_count
  end

  def broadcast_creation
    return unless @notification.channel_in_app?

    # Show banner if the user has the notification page open
    broadcast_new_notifications_banner

    # Update the unread count (sidebar frame + count-data frame)
    broadcast_badge_update
  end

  def broadcast_update
    return unless @notification.channel_in_app?

    # Replace the notification in the list
    @notification.broadcast_replace_later_to(
      notifications_stream,
      target: @notification,
      partial: 'notifications/notification_card',
      locals: { notification: @notification }
    )

    # Update badge counter
    broadcast_badge_update
  end

  private

  # Scoped to the notification's organisation: see Notifications::Streams.
  def badge_stream
    Notifications::Streams.badge(@notification.recipient_id, @notification.organisation_id)
  end

  def notifications_stream
    Notifications::Streams.notifications(@notification.recipient_id, @notification.organisation_id)
  end

  def broadcast_new_notifications_banner
    Turbo::StreamsChannel.broadcast_update_later_to(
      notifications_stream,
      target: 'new_notifications_banner',
      html: <<~HTML
        <div class="mb-4 p-3 bg-lime-100 border-2 border-black rounded-lg flex items-center justify-between shadow-[2px_2px_0_0_#000000]">
          <span class="text-sm font-medium text-lime-900">Neue Benachrichtigungen verfügbar</span>
          <a href="javascript:window.location.reload()" class="text-sm font-bold text-lime-900 underline hover:text-lime-700">
            Aktualisieren
          </a>
        </div>
      HTML
    )
  end

  def broadcast_badge_update
    # Must return the same filtered count as the HTTP render path
    # (User#unread_notifications_count), otherwise the Turbo broadcast overwrites
    # the correct banner/badge value with the org-wide unfiltered number
    # (notifications from projects without access).
    unread_count = @precomputed_unread_count ||
                   @notification.recipient.unread_notifications_count(@notification.organisation)

    # One partial owns the count streams, shared with the inbox turbo_stream
    # templates: notifications/_unread_count_streams.turbo_stream.erb. (The
    # header badge #notification_badge used to get a stream too; its dropdown
    # is mounted only in the test environment, so that stream had no target.)
    Turbo::StreamsChannel.broadcast_render_later_to(
      badge_stream,
      partial: 'notifications/unread_count_streams',
      locals: { unread_count: unread_count }
    )
  end
end
