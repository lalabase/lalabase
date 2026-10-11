# frozen_string_literal: true

class User < ApplicationRecord
  # === Ticket notification settings (user split, slice 4) ===
  # Simple on/off toggles, kept in preferences['ticket_notifications']
  # (JSONB), that define what "watching a ticket" means. Deliberately NOT
  # org-scoped: the toggles are global per user, so there is no org_key
  # handling here (unlike sidebar pins / org colors). Plain PORO holding a
  # user reference; writes go through user.preference_store.set! because the
  # legacy writer persisted with save! — callers rely on a raise for an
  # invalid user, see #update. Access goes through User#notification_settings
  # (memoized there => same lifetime as the other per-instance caches).
  #
  # User keeps a delegation facade for ticket_notification_enabled_for? and
  # ticket_auto_follow_created? on purpose: those run in the notification
  # delivery hot path (Notifications::FanoutService inside Solid Queue jobs)
  # and an after_create_commit callback (Ticket#auto_subscribe_creator) —
  # their call sites and the existing user-level spec stubs stay stable.
  class NotificationSettings
    # Storage slot inside users.preferences (JSONB).
    PREF_KEY = 'ticket_notifications'

    def initialize(user)
      @user = user
    end

    # All predicates default to true (via != false) so users without
    # explicit settings get all notifications.
    def ticket_notify_on_status_change?
      setting('on_status_change') != false
    end

    def ticket_notify_on_priority_change?
      setting('on_priority_change') != false
    end

    def ticket_notify_on_comment?
      setting('on_comment') != false
    end

    def ticket_auto_follow_created?
      setting('auto_follow_created') != false
    end

    # Maps a notification event type to its controlling toggle. Beware:
    # 'ticket_blocker' hangs off the PRIORITY toggle, not the comment one.
    def ticket_notification_enabled_for?(event_type)
      case event_type
      when 'ticket_status_changed' then ticket_notify_on_status_change?
      when 'ticket_blocker' then ticket_notify_on_priority_change?
      when 'ticket_commented' then ticket_notify_on_comment?
      else true # assignments, mentions, system messages: always
      end
    end

    # Shallow merge into the slot only: sibling keys inside the slot and
    # foreign preference slots survive. Persists via save! (raises on an
    # invalid user) — bit-identical to the legacy writer on User.
    def update(settings)
      current = user.preferences[PREF_KEY] || {}
      store.set!(PREF_KEY, current.merge(settings))
    end

    private

    attr_reader :user

    def store
      user.preference_store
    end

    # Raw toggle value from the slot (nil when unset).
    def setting(key)
      user.preferences.dig(PREF_KEY, key)
    end
  end
end
