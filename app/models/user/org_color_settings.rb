# frozen_string_literal: true

class User < ApplicationRecord
  # === Org recognition color / sidebar color (user split, slice 3) ===
  # Per-user, per-org recognition color, kept in
  # preferences[PREF_KEY][org_id]. Three states per (user, org) — see
  # OrgColor: absent = automatic, OrgColor::OFF = deliberately off,
  # "#rrggbb" = a concrete color. Plain PORO holding a user reference; it
  # reads and writes exclusively through user.preference_store
  # (get/set/org_key). Mutating methods return the truthiness of user.save.
  # Access goes through User#org_colors (memoized there => same lifetime as
  # the other per-instance caches).
  class OrgColorSettings
    # Storage slot inside users.preferences (JSONB). The value is HISTORICALLY
    # "sidebar_colors" (the former sidebar tint used the same slot) ->
    # existing production data stays valid; do NOT rename. Kept as a constant
    # because it is read/written in several places (one place to change, no
    # magic string).
    PREF_KEY = 'sidebar_colors'

    def initialize(user)
      @user = user
    end

    # The RAW stored setting. Can be a hex, OrgColor::OFF or nil — do NOT use
    # it directly as a CSS color (OFF would leak); that is what
    # effective_color is for.
    def setting_for(organisation)
      store.get(PREF_KEY, {})[store.org_key(organisation)]
    end

    # Canonical write access (3 states):
    #   hex           -> this color
    #   OrgColor::OFF -> deliberately off
    #   nil/:auto/""  -> back to "automatic" (remove the entry; auto
    #                    assignment kicks in again)
    def set(organisation, value)
      org_id = store.org_key(organisation)
      colors = store.get(PREF_KEY, {}).dup
      if value.blank? || value == :auto
        colors.delete(org_id)
      else
        colors[org_id] = value
      end
      store.set(PREF_KEY, colors)
    end

    # The visible org color (hex) or nil — the ONE source for all render
    # sites (<html> variable, sidebar chip/edge line, org selection
    # banderole). Applies the >=2 gate and the OFF sentinel centrally
    # (OrgColor.effective_color) so no render site copies the visibility
    # logic.
    def effective_color(organisation)
      OrgColor.effective_color(setting: setting_for(organisation),
                               org_count: org_count)
    end

    # Auto-assigns distinct palette colors to orgs WITHOUT an own decision —
    # but only from >=2 active orgs (no need for distinction below that).
    # Idempotent: OFF and already set colors stay untouched (logic in
    # OrgColor.assign_defaults). WHY persisted instead of derived on every
    # render: stable color<->org mapping (no jumping when more orgs arrive
    # later) + the user must be able to change it. Called from the membership
    # hook (2nd org) and from the backfill task.
    def ensure_defaults!
      org_ids = user.memberships.active.pluck(:organisation_id).map(&:to_s)
      return if org_ids.size < 2

      existing = store.get(PREF_KEY, {})
      updated  = OrgColor.assign_defaults(existing_by_org_id: existing, org_ids: org_ids)
      store.set(PREF_KEY, updated) unless updated == existing
    end

    # Backfill for existing users (new users/reactivations go through the
    # membership hooks). Logic deliberately here instead of in the rake task
    # -> testable without rake ceremony; the task only calls this. Returns
    # the number of users actually changed. Idempotent. The per-user query
    # (memberships.active) is a deliberate batch N+1 (one-off ops run, not a
    # request).
    def self.backfill_all!
      changed = 0
      User.find_each do |user|
        before = user.preferences[PREF_KEY]
        user.org_colors.ensure_defaults!
        changed += 1 if user.preferences[PREF_KEY] != before
      end
      changed
    end

    private

    attr_reader :user

    def store
      user.preference_store
    end

    # Number of orgs the user is ACTIVE in (= need for distinction). Inactive
    # memberships = no access, they do not count. Uniqueness (user+org)
    # guarantees: active memberships == distinct accessible orgs.
    # MEMOIZED per instance (request-scoped via the memoized User#org_colors):
    # effective_color is called for EVERY org while rendering (sidebar + org
    # selection list) -> without the memo that would be a COUNT N+1.
    # 0 is truthy in Ruby, so ||= is also correct for "no orgs".
    def org_count
      @org_count ||= user.memberships.active.count
    end
  end
end
