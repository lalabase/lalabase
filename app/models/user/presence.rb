# frozen_string_literal: true

class User < ApplicationRecord
  # === Presence / "last seen" (user split) ===
  # Lightweight activity heartbeat. ApplicationController#touch_last_seen calls
  # #mark_seen! on every authenticated request; the write is coalesced to at
  # most one UPDATE per SEEN_THROTTLE and goes through update_all so it bypasses
  # callbacks, validations AND the updated_at bump. That last part is
  # load-bearing: a per-request heartbeat must never fire the
  # Trackable -> Activity -> Outbox -> Fanout side-effect chain
  # (docs/architektur/seiteneffekt_ketten.md) or dirty the record's updated_at.
  #
  # Semantics: "last present in the app" (any authenticated request, incl.
  # read-only navigation), NOT "last performed a tracked write". API/token
  # usage is intentionally out of scope here — that is tracked separately via
  # PersonalAccessToken#last_used_at.
  module Presence
    extend ActiveSupport::Concern

    # A user counts as "online" when seen within this window. Deliberately
    # LARGER than the session_timeout controller's 5-minute activity-ping
    # throttle (session_timeout_controller.js): an idle-but-present tab only
    # pings /session/touch every 5 min, so a tighter window would flicker the
    # presence dot offline between pings.
    ONLINE_WINDOW = 6.minutes

    # Minimum gap between two last_seen_at writes for the same user. Collapses
    # the per-request heartbeat down to at most one UPDATE per interval.
    SEEN_THROTTLE = 2.minutes

    # Cheap in-memory staleness check on the already-loaded record. Lets the
    # caller skip issuing the UPDATE entirely on the vast majority of requests.
    def stale_last_seen?
      last_seen_at.nil? || last_seen_at < SEEN_THROTTLE.ago
    end

    # Coalesced presence heartbeat. The WHERE re-checks staleness at the DB, so
    # concurrent requests across processes still collapse to a single write.
    # update_all => no callbacks, no validations, no updated_at bump, no
    # Activity/Notification fanout. Returns the number of rows written (0 or 1).
    def mark_seen!
      User.where(id: id)
          .where('last_seen_at IS NULL OR last_seen_at < ?', SEEN_THROTTLE.ago)
          .update_all(last_seen_at: Time.current)
    end

    # One-shot claim on the very first visit: writes last_seen_at only while it is
    # still NULL and answers whether THIS call was the one that wrote it. The
    # signup handoff link (Signups::Handoff) uses it as its single-use gate, so
    # two clicks arriving together cannot both open a session. Deliberately not
    # mark_seen!, which writes again once its throttle window has passed and
    # would therefore call an old link unused.
    def claim_first_visit!
      User.where(id: id, last_seen_at: nil).update_all(last_seen_at: Time.current) == 1
    end

    def online?
      last_seen_at.present? && last_seen_at > ONLINE_WINDOW.ago
    end
  end
end
