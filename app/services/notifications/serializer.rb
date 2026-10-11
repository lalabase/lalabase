# frozen_string_literal: true

# JSON rows of inbox notifications, shared by GET /api/v1/notifications and the
# MCP tool list_notifications (D4). Expects rows loaded by InboxQuery, which
# preloads actor, organisation, project and notifiable, so a row normally never
# touches the database: the endpoint used to lazy-load the project per row, an
# N+1 the request spec now catches (Prosopite).
#
# Two guards sit in .rows, the entry both surfaces use, because neither surface
# has a tenant or a locale of its own (ActionController::API without switch_locale;
# the ToolCall's token mode runs without a tenant):
#   * each row is built under ITS organisation as tenant. A notifiable's `title`
#     is a method, not always a column: Document#title reads current_version, a
#     tenanted association, and require_tenant would raise NoTenantSet for the
#     whole page because of that one row.
#   * the sentence in `message` is rendered in the VIEWER's language. I18n.locale
#     is thread state a preceding web request leaves behind; without the guard
#     the sentence would come in whatever language the last request on this
#     Puma thread asked for. Inside a token request Api::TokenAuthenticatable
#     already wraps the whole action in the owner's locale (deliberately the
#     same rule twice: that wrap covers every text of the request, this one
#     keeps the serializer right for callers outside a request).
#
# Two keys exist for the MCP client: `message`, the sentence the in-app inbox
# shows (NotificationPresenter), and `ticket`, the id + number + title +
# project_id when the row is about a ticket: the exact address get_ticket
# takes next.
#
# Entry point: rows
module Notifications
  class Serializer
    # @param viewer [User] whose inbox this is; decides the language of `message`
    def self.rows(notifications, viewer:)
      I18n.with_locale(locale_for(viewer)) do
        notifications.map { |notification| row(notification) }
      end
    end

    def self.row(notification)
      ActsAsTenant.with_tenant(notification.organisation) { new.row(notification) }
    end

    def self.locale_for(viewer)
      viewer&.language_preference.presence || I18n.default_locale
    end

    def row(notification)
      {
        id: notification.id,
        event_type: notification.event_type,
        state: notification.state,
        priority: notification.priority,
        read: notification.read_at.present?,
        read_at: notification.read_at&.iso8601,
        group_count: notification.group_count,
        message: NotificationPresenter.new(notification).message,
        actor: actor(notification),
        organisation: { id: notification.organisation_id, name: notification.organisation&.name },
        project: project(notification),
        ticket: ticket(notification),
        notifiable: notifiable(notification),
        payload: notification.payload,
        first_event_at: notification.first_event_at.iso8601,
        last_event_at: notification.last_event_at.iso8601,
        created_at: notification.created_at.iso8601
      }
    end

    private

    def actor(notification)
      return nil unless notification.actor_id

      { id: notification.actor_id, name: notification.actor&.display_name }
    end

    def project(notification)
      return nil unless notification.project_id

      { id: notification.project_id, name: notification.project&.name }
    end

    def ticket(notification)
      subject = notification.notifiable
      return nil unless subject.is_a?(Ticket)

      { id: subject.id, number: subject.number, title: subject.title, project_id: subject.project_id }
    end

    # A defunct reference (the notifiable was deleted) keeps type + id and answers
    # a nil title: the preload simply finds nothing, no exception to rescue.
    def notifiable(notification)
      return nil unless notification.notifiable_id

      subject = notification.notifiable
      {
        type: notification.notifiable_type,
        id: notification.notifiable_id,
        title: subject.respond_to?(:title) ? subject.title : nil
      }
    end
  end
end
