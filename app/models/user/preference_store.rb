# frozen_string_literal: true

class User < ApplicationRecord
  # === Preferences store (user split, slice 1) ===
  # Encapsulates the user preferences kept in the JSONB column
  # users.preferences. Plain PORO holding a user reference: it reads
  # user.preferences and always writes via merge + full reassignment — never
  # in-place mutation, otherwise JSONB dirty tracking does not reliably kick
  # in. Writer methods return the truthiness of user.save (controllers branch
  # on it). Access goes through User#preference_store (memoized there => same
  # lifetime as the other per-instance caches; deliberately does not survive
  # reload).
  class PreferenceStore
    def initialize(user)
      @user = user
    end

    # Fetches a single preference with an optional default
    def get(key, default = nil)
      preferences[key.to_s] || default
    end

    # Sets a single preference
    def set(key, value)
      user.preferences = preferences.merge(key.to_s => value)
      user.save
    end

    # Like #set, but persists with save! (raises on an invalid user). For
    # callers that must not silently swallow a failed save — the legacy
    # ticket notification writer had raise semantics, kept bit-identical in
    # User::NotificationSettings#update.
    def set!(key, value)
      user.preferences = preferences.merge(key.to_s => value)
      user.save!
    end

    # Updates preferences with deep merge for nested structures
    def update(prefs)
      user.preferences = preferences.deep_merge(prefs.to_h.deep_stringify_keys)
      user.save
    end

    # Normalizes an organisation reference (object or id) to the string key
    # used inside org-scoped JSONB preference slots (sidebar pins, org colors).
    def org_key(organisation)
      organisation.is_a?(Organisation) ? organisation.id.to_s : organisation.to_s
    end

    # Onboarding banner dismissal (Kettenglied 0, doc/onboarding_plan.md D4).
    # Scoped per user + organisation — a second organisation shows the banner
    # again. Stored as { "<org_id>" => true }.
    def onboarding_banner_dismissed?(organisation)
      get('onboarding_banner_dismissed', {})[org_key(organisation)] == true
    end

    def dismiss_onboarding_banner!(organisation)
      dismissed = get('onboarding_banner_dismissed', {}).merge(org_key(organisation) => true)
      set!('onboarding_banner_dismissed', dismissed)
    end

    # Items-per-page preference with default
    def items_per_page_preference
      get('items_per_page', 20).to_i
    end

    # Check if user is using global date format for all areas
    def using_global_date_format_for_all?
      areas = preferences.dig('date_display', 'areas') || {}
      # Check if all areas are set to 'inherit'
      %w[posts ticket_header ticket_list_large ticket_list_compact activity_logs].all? do |area|
        areas[area] == 'inherit'
      end
    end

    # Sets the items-per-page preference
    def set_items_per_page(value)
      set('items_per_page', value.to_i)
    end

    # === Timeline Display Preferences ===

    # Post direction preference - controls timeline order
    # Returns 'chronological' (default) or 'reverse'
    def post_direction_preference
      get('post_direction', 'chronological')
    end

    # Check if user prefers reverse timeline order (newest first)
    def prefers_reverse_timeline?
      post_direction_preference == 'reverse'
    end

    # === Ticket Description Display ===

    # Allowed values for the ticket description collapse preference.
    # 'unset' is the initial, unanswered state (collapse + show the one-time
    # info box); 'auto' = collapse known tickets silently; 'always_full' =
    # never collapse. Kept as a constant so the controller whitelist and the
    # reader stay in sync.
    DESCRIPTION_COLLAPSE_VALUES = %w[unset auto always_full].freeze

    # Controls whether the description on already-known tickets is collapsed.
    # Returns 'unset' (default) until the user has answered once.
    def description_collapse_preference
      get('description_collapse', 'unset')
    end

    # Collapse the description on known tickets? True for both the unanswered
    # default and the explicit 'auto' choice; only 'always_full' opts out.
    def collapse_known_ticket_descriptions?
      description_collapse_preference != 'always_full'
    end

    # Has the user answered the one-time collapse question (info box / setting)?
    # While false, the JIT info box keeps appearing on collapsing tickets.
    def description_collapse_answered?
      description_collapse_preference != 'unset'
    end

    # === Meeting participant detection mode (Gespräche Slice 5) ===

    # Allowed values for the detection mode. 'offline' (default) = only the
    # client-side parser runs automatically, the LLM is a per-use button;
    # 'ai' = pasting a transcript additionally triggers the LLM detection.
    # Kept as a constant so the controller whitelist and the reader stay in
    # sync (same pattern as DESCRIPTION_COLLAPSE_VALUES).
    MEETING_DETECTION_MODES = %w[offline ai].freeze
    MEETING_DETECTION_DEFAULT = 'offline'

    # Detection mode with read-side whitelist hardening: an unknown/stale
    # stored value reads as the offline default — fail-closed towards
    # "nothing leaves the browser" (data sovereignty, plan decision 12). The
    # org-level AI gate always outranks this setting at runtime.
    def meeting_detection_mode_preference
      value = get('meeting_detection_mode')
      MEETING_DETECTION_MODES.include?(value) ? value : MEETING_DETECTION_DEFAULT
    end

    # === Overview widget period (my_week_stats / my_week_chart) ===

    # Per-widget selectable reporting period for the personal overview widgets.
    # Stored nested as { 'overview_widget_periods' => { widget_key => period } }
    # so each widget keeps its own choice. Unknown/blank -> the canonical
    # default (whitelist hardening for values coming off params).
    def overview_widget_period(widget_key)
      stored = preferences.dig('overview_widget_periods', widget_key.to_s)
      Overview::TimePeriod.normalize(stored)
    end

    # Persists the period for one widget. deep_merge keeps the other widget's
    # choice intact. Returns the truthiness of user.save (controller branches).
    def set_overview_widget_period(widget_key, period)
      normalized = Overview::TimePeriod.normalize(period)
      update('overview_widget_periods' => { widget_key.to_s => normalized })
    end

    # === Date Display Preferences ===

    # Get the global date format preference
    def date_display_format
      preferences.dig('date_display', 'global_format') || 'relative'
    end

    # Get custom date format string
    def custom_date_format
      preferences.dig('date_display', 'custom_format') || '%d.%m.%Y %H:%M'
    end

    # Get format for a specific area
    def date_format_for_area(area)
      area_format = preferences.dig('date_display', 'areas', area.to_s)

      # If area is set to inherit or not set, use global format
      if area_format.nil? || area_format == 'inherit'
        date_display_format
      else
        area_format
      end
    end

    # Get the strftime format string for a specific area
    def date_strftime_format(area = nil)
      format = area ? date_format_for_area(area) : date_display_format

      # No else branch: the relative format has no strftime format, a case
      # without a match yields nil (the legacy code had an explicit `else nil`).
      case format
      when 'german'
        '%d.%m.%Y %H:%M'
      when 'international'
        '%Y-%m-%d %H:%M'
      when 'custom'
        # Check if area has specific custom format
        if area.present?
          area_custom_format = preferences.dig('date_display', 'areas_custom', area.to_s)
          area_custom_format.presence || custom_date_format
        else
          custom_date_format
        end
      end
    end

    # === Cockpit (organisations#select) personalisation ===
    # User-global settings for the cross-org cockpit. The select page runs WITHOUT a tenant, so these
    # live here (users.preferences), not in the tenant-bound overview_configuration. The JSONB has no
    # model validation, so BOTH sides normalise: the controller drops unknown values on write, and
    # these getters fall back to the default on read (defense in depth — a crafted PATCH or a value
    # left over from an older build still reads as the canonical default; same idea as
    # overview_widget_period).
    COCKPIT_IMPORTANCE_LEVELS = %w[notifications important all].freeze
    COCKPIT_LAYOUTS = %w[stacked rows_compact rows_detailed].freeze
    COCKPIT_DEFAULT_IMPORTANCE = 'important'
    COCKPIT_DEFAULT_LAYOUT = 'stacked'

    # Show the cross-org action summary? Defaults to true (unset = not answered = show).
    def cockpit_show_actions?
      cockpit_flag('cockpit_show_actions')
    end

    # Show the personal to-do roll-up? Defaults to true.
    def cockpit_show_todos?
      cockpit_flag('cockpit_show_todos')
    end

    # Importance level for the action summary; unknown/blank -> the default ('important').
    def cockpit_importance
      value = get('cockpit_importance')
      COCKPIT_IMPORTANCE_LEVELS.include?(value) ? value : COCKPIT_DEFAULT_IMPORTANCE
    end

    # Cockpit layout; unknown/blank -> the default ('stacked').
    def cockpit_layout
      value = get('cockpit_layout')
      COCKPIT_LAYOUTS.include?(value) ? value : COCKPIT_DEFAULT_LAYOUT
    end

    # === Name display (doc/user_display_name_avatar_plan.md, S1) ===
    # VIEWER preference: how OTHER users' names are SPELLED for this user,
    # app-wide. Since 05.09.2026 (Slack model, user decision) the picture is
    # no longer a mode: the avatar chip shows ALWAYS at identity spots
    # (Neo::Users::AvatarComponent), and this setting only picks the spelling.
    # The historic stored value 'circle' therefore reads as the default via
    # the whitelist below - no data migration needed. Same hardening pattern
    # as MEETING_DETECTION_MODES: the controller drops unknown values on
    # write, this reader falls back on read.
    NAME_DISPLAY_MODES = %w[full first_last_initial initial_last].freeze
    NAME_DISPLAY_DEFAULT = 'full'

    # Name display mode; unknown/blank/legacy 'circle' -> 'full'.
    def name_display_mode
      value = get('name_display')
      NAME_DISPLAY_MODES.include?(value) ? value : NAME_DISPLAY_DEFAULT
    end

    private

    attr_reader :user

    def preferences
      user.preferences
    end

    # Reads a stored boolean cockpit flag. NB: we cannot use #get here — `get(k) = preferences[k] ||
    # default` would turn a stored `false` into the default (false is falsy in Ruby). So read the key
    # directly: absent -> default true; present -> cast the stored value (true/false or "1"/"0").
    def cockpit_flag(key)
      stored = preferences[key]
      # absent -> default true; present -> cast ("0"/false -> false, "1"/true -> true).
      stored.nil? || ActiveModel::Type::Boolean.new.cast(stored)
    end
  end
end
