# frozen_string_literal: true

module Api
  module V1
    # Returns notifications of the authenticated user, as far as the token reaches
    # (the organisations in scope and, within them, the linked projects). Rows and
    # their JSON come from Notifications::InboxQuery + Serializer, the same objects
    # the MCP tool list_notifications answers with (D4).
    class NotificationsController < BaseController
      # Deliberate opt-out from the Pundit tripwire: authorization here is the
      # token reach (PersonalAccessToken#reach) + ownership (recipient = current
      # user), both applied inside InboxQuery on every query; a Pundit layer would
      # sit on top without additional guarantee. New actions in this controller
      # MUST read through InboxQuery (.call, .relation or load_user_notification).
      skip_after_action :verify_authorized
      skip_after_action :verify_policy_scoped

      idempotent :mark_as_read, :archive, :mark_all_as_read

      rescue_from Notifications::InboxQuery::InvalidArgument, with: :bad_request
      # Declared after InvalidArgument (its parent) so it wins: a project or an
      # organisation outside the reach is a 404 here, like every other out-of-scope project.
      rescue_from Notifications::InboxQuery::NotReachable, with: :not_found

      # GET /api/v1/notifications?status=unread|read|all&since=<ISO 8601, activity after>
      #   &organisation_id=<uuid>&project_id=<uuid>&page=&per_page=
      # In the query string a `+` in the offset of `since` must be sent as %2B
      # (an unencoded + arrives as a space and is refused); `Z` needs no encoding.
      def index
        page = Notifications::InboxQuery.call(
          user: current_user, reach: current_token.reach,
          status: params[:status], since: params[:since], project_id: params[:project_id],
          organisation_id: params[:organisation_id],
          page: params[:page], per_page: params[:per_page]
        )

        render json: {
          data: Notifications::Serializer.rows(page.rows, viewer: current_user),
          meta: { page: page.page, per_page: page.per_page, total: page.total, unread_total: page.unread_total,
                  since: page.since&.iso8601, by_organisation: page.by_organisation }
        }
      end

      # POST /api/v1/notifications/:id/mark_as_read
      def mark_as_read
        notification = load_user_notification(params[:id])
        notification.mark_as_read!
        render json: { data: { id: notification.id, state: notification.state, read_at: notification.read_at&.iso8601 } }
      end

      # POST /api/v1/notifications/:id/archive
      def archive
        notification = load_user_notification(params[:id])
        notification.archive!
        render json: { data: { id: notification.id, state: notification.state } }
      end

      # POST /api/v1/notifications/mark_all_as_read
      def mark_all_as_read
        affected = ActsAsTenant.without_tenant do
          ids = Notifications::InboxQuery.relation(user: current_user, reach: current_token.reach, status: 'unread')
                                         .pluck(:id)
          # Bulk update via bulk_transition! (skips callbacks, refreshes the org switcher signal).
          # `.unread` keeps the state check INSIDE the UPDATE: a row archived (or
          # read) between the pluck and the write is left alone instead of being
          # flipped to read with its archived_at still set, which would put it
          # back into the inbox.
          Notification.where(id: ids).unread.bulk_transition!(state: :read, read_at: Time.current)
          ids
        end

        render json: { data: { marked_read_count: affected.size, marked_read_ids: affected } }
      end

      private

      # A row outside the token's reach is a 404, exactly like a missing one.
      def load_user_notification(id)
        ActsAsTenant.without_tenant do
          Notifications::InboxQuery.relation(user: current_user, reach: current_token.reach,
                                             status: 'all', include_archived: true).find(id)
        end
      end
    end
  end
end
