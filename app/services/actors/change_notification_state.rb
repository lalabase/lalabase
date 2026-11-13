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
# The siblings are the ones the person may see in the organisation of the ROW
# (Notifications::SubjectBundle, the rule the bulk bar's actor shares). The
# caller has found the row through its own gate and authorized it.
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

    # The row and its bundle, locked before any member changes
    # (Notifications::SubjectBundle, shared with the bulk bar's actor). The
    # cascade stays within this snapshot.
    def lock_bundle
      visible = Notifications::SubjectBundle.visible(user: current_user, organisation: @notification.organisation)
      locked = Notifications::SubjectBundle.lock(visible: visible, chosen: visible.where(id: @notification.id))
      @siblings = locked.channel_in_app
      # Reload through the locked set too: access may have changed since the
      # caller authorized the row, and an unlocked row must never be written.
      raise ActorError, 'notification is no longer accessible' unless locked.exists?(id: @notification.id)

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
  end
end
