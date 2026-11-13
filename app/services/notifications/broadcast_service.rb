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

  # The placeholder of the banner in organisations/notifications/index.
  BANNER_ID = 'new_notifications_banner'

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

  # The banner above the list of an organisation's inbox
  # (notifications/_new_notifications_banner, shared with the inbox above the
  # organisations). It REPLACES the empty, hidden placeholder: an update put the
  # text into it and left it hidden, so until 2026-11-13 it was never seen.
  # Rendered here, in the recipient's language: the broadcast job has none.
  def broadcast_new_notifications_banner
    html = I18n.with_locale(recipient_locale) do
      ApplicationController.render(partial: 'notifications/new_notifications_banner',
                                   locals: { id: BANNER_ID })
    end
    Turbo::StreamsChannel.broadcast_replace_later_to(notifications_stream, target: BANNER_ID, html: html)
  end

  def recipient_locale
    @notification.recipient.language_preference.presence || I18n.default_locale
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
