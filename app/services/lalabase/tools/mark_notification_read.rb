# frozen_string_literal: true

module Lalabase
  module Tools
    # Marks one inbox row as read for the token owner, addressed by the id
    # list_notifications returned. Token-scoped like the listing, mutating (D3:
    # a read-only PAT cannot), record-mode (D7): the row is looked up through
    # the same InboxQuery as the listing, so a row outside the token's reach or
    # addressed to somebody else reads as "not found", and
    # NotificationPolicy#mark_read? is authorized under the row's own tenant,
    # because the policy compares organisations and a token-scoped call has no
    # ambient tenant. A read row stays read; an archived row is refused, as is
    # the project_id filter it does not read. Inbox workflow S3.
    class MarkNotificationRead < Base
      def self.scope_mode
        :token
      end

      def self.requires_actor?
        true
      end

      def self.mutating?
        true
      end

      def self.authorization_mode
        :record
      end

      def self.tool_name
        'mark_notification_read'
      end

      def self.description
        'Marks one of your inbox notifications as read, by the id list_notifications ' \
          'returned. A row that is already read stays read. Returns id, state and read_at.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            notification_id: { type: 'string', description: 'UUID of the notification (from list_notifications).' }
          },
          required: ['notification_id']
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'token context missing') unless token_wide?(context)

        args = symbolized(args)
        # Not advertised (project_filter? false); a client that sends it anyway is
        # told so instead of having it ignored.
        return Result.invalid_input('project_id does not apply to this tool') if args[:project_id].present?

        id = args[:notification_id].to_s.strip
        return Result.invalid_input('notification_id is required') if id.empty?
        return Result.invalid_input('invalid notification_id format') unless id.match?(UUID_FORMAT)

        notification = ActsAsTenant.without_tenant do
          Notifications::InboxQuery.relation(user: context.actor, reach: context.reach,
                                             status: 'all', include_archived: true).find_by(id: id)
        end
        return Result.new(content: "No notification found for #{id}.", citations: [], kind: :empty) if notification.nil?
        # mark_as_read! is a silent no-op on an archived row; the tool says so
        # rather than answering state "archived" to a request it did not fulfil.
        return Result.refused('notification is archived; it cannot be marked as read', reason: :archived) if notification.state_archived?

        ActsAsTenant.with_tenant(notification.organisation) do
          authorize!(context, notification, :mark_read?)
          notification.mark_as_read!
        end
        json_result({ id: notification.id, state: notification.state, read_at: notification.read_at&.iso8601 })
      end
    end
  end
end
