# frozen_string_literal: true

# app/services/actors/change_notification_state.rb
#
# One action on one inbox row: read, unread, archive, unarchive. The ONE write
# behind the row menu and the lane head of the inbox of an organisation
# (Organisations::NotificationsController) and behind the row menu of the inbox
# above the organisations (AllInboxesController).
#
# Bundling: one ticket is one inbox row, so read, archive and unarchive take
# every in-app notification the person holds about the same subject in the
# row's organisation along. "Unread" flips only this one back.
#
# The siblings are the ones the person may see (Notification.accessible_for)
# in the organisation of the ROW, named here and not read from the ambient
# tenant: the inbox above the organisations has none of its own. The caller
# has found the row through its own gate and authorized it.
module Actors
  class ChangeNotificationState < BaseActor
    CHANGES = %w[read unread archive unarchive].freeze

    def initialize(notification:, change:, current_user:)
      super()
      @notification = notification
      @change = change.to_s
      @current_user = current_user
    end

    def record
      @notification
    end

    def perform
      raise ActorError.new("unknown change #{@change}", code: :invalid_input) unless CHANGES.include?(@change)

      lock_bundle
      send(:"perform_#{@change}")
    end

    private

    attr_reader :current_user, :siblings

    # Lock the whole bundle before changing any member, in the same order for
    # every caller. Otherwise two actions on different members each hold their
    # own row and wait for the other's in the cascade. Keep the cascade within
    # this snapshot; a notification arriving later belongs to the next action.
    def lock_bundle
      scope = visible_notifications
      @siblings = scope.channel_in_app
                       .where(notifiable_type: @notification.notifiable_type, notifiable_id: @notification.notifiable_id)
      ids = @siblings.or(scope.where(id: @notification.id)).order(:id).lock.pluck(:id)
      @siblings = @siblings.where(id: ids)
      # Reload through the locked set too: access may have changed since the
      # caller authorized the row, and an unlocked row must never be written.
      raise ActorError, 'notification is no longer accessible' unless ids.include?(@notification.id)

      @notification.reload
    end

    def perform_read
      @notification.mark_as_read!
      siblings.unread.bulk_transition!(state: 'read', read_at: Time.current)
    end

    # An archived row comes back unread too: the way out of the archive that
    # asks for attention again.
    def perform_unread
      if @notification.state_archived?
        @notification.restore_from_archived!
      else
        @notification.mark_as_unread!
      end
    end

    def perform_archive
      @notification.archive!
      siblings.where.not(state: Notification.states[:archived])
              .bulk_transition!(state: 'archived', archived_at: Time.current)
    end

    # Back as read: a row that was archived unread has no read_at yet and gets
    # one, the others keep theirs.
    def perform_unarchive
      read_at = @notification.read_at || Time.current
      @notification.update!(state: :read, archived_at: nil, read_at: read_at) if @notification.state_archived?
      archived = siblings.where(state: Notification.states[:archived])
      archived.where(read_at: nil).bulk_transition!(state: 'read', archived_at: nil, read_at: Time.current)
      archived.bulk_transition!(state: 'read', archived_at: nil)
    end

    # The same access rule for the lock and for the cascade, in the row's org.
    def visible_notifications
      organisation = @notification.organisation
      current_user.notifications
                  .where(organisation_id: organisation.id)
                  .accessible_for(current_user, organisation)
    end
  end
end
